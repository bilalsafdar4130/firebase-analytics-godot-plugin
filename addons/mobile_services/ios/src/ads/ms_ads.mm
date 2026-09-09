/**************************************************************************/
/*  ms_ads.mm                                                             */
/**************************************************************************/

#import "ms_ads.h"

#import <UIKit/UIKit.h>

@import GoogleMobileAds;

MobileServicesAds *MobileServicesAds::instance = nullptr;

/**
 * Holds one placement's ad object and the delegate wiring for it.
 *
 * Objective-C rather than C++ because every AdMob callback is a delegate
 * protocol, and a delegate has to be an ObjC object with a lifetime the SDK does
 * not own — a C++ shim would have to keep one alive anyway.
 */
@interface MSAdSlot : NSObject <GADFullScreenContentDelegate, GADBannerViewDelegate>
@property(nonatomic, copy) NSString *placement;
@property(nonatomic, copy) NSString *format;
@property(nonatomic, copy) NSString *unitID;
@property(nonatomic, strong) id fullScreenAd;
@property(nonatomic, strong) GADBannerView *bannerView;
@property(nonatomic, strong) UIView *bannerContainer;
@end

static NSMutableDictionary<NSString *, MSAdSlot *> *ms_slots() {
	static NSMutableDictionary<NSString *, MSAdSlot *> *slots = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		slots = [NSMutableDictionary dictionary];
	});
	return slots;
}

/** The controller AdMob presents full-screen ads from. Godot puts its own
 * controller at the window root, which is the one to use. */
static UIViewController *ms_root_controller() {
	UIWindow *window = nil;
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if ([scene isKindOfClass:[UIWindowScene class]]) {
			for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
				if (candidate.isKeyWindow) {
					window = candidate;
					break;
				}
			}
		}
		if (window != nil) {
			break;
		}
	}
	if (window == nil) {
		window = [UIApplication sharedApplication].delegate.window;
	}
	return window.rootViewController;
}

@implementation MSAdSlot

- (void)ad:(nonnull id<GADFullScreenPresentingAd>)ad
		didFailToPresentFullScreenContentWithError:(nonnull NSError *)error {
	MobileServicesAds *plugin = MobileServicesAds::get_singleton();
	if (plugin) {
		plugin->report_show_failed(ms_str(self.placement), ms_str(self.format),
				(int)error.code, ms_str(error.localizedDescription));
	}
}

- (void)adDidRecordImpression:(nonnull id<GADFullScreenPresentingAd>)ad {
	MobileServicesAds *plugin = MobileServicesAds::get_singleton();
	if (plugin) {
		plugin->report_shown(ms_str(self.placement), ms_str(self.format));
	}
}

- (void)adDidRecordClick:(nonnull id<GADFullScreenPresentingAd>)ad {
	MobileServicesAds *plugin = MobileServicesAds::get_singleton();
	if (plugin) {
		plugin->report_clicked(ms_str(self.placement), ms_str(self.format));
	}
}

- (void)adDidDismissFullScreenContent:(nonnull id<GADFullScreenPresentingAd>)ad {
	MobileServicesAds *plugin = MobileServicesAds::get_singleton();
	if (plugin) {
		plugin->report_closed(ms_str(self.placement), ms_str(self.format));
	}
}

- (void)bannerViewDidReceiveAd:(nonnull GADBannerView *)bannerView {
	MobileServicesAds *plugin = MobileServicesAds::get_singleton();
	if (plugin) {
		plugin->report_loaded(ms_str(self.placement), @"banner".UTF8String);
	}
}

- (void)bannerView:(nonnull GADBannerView *)bannerView
		didFailToReceiveAdWithError:(nonnull NSError *)error {
	MobileServicesAds *plugin = MobileServicesAds::get_singleton();
	if (plugin) {
		plugin->report_load_failed(ms_str(self.placement), String("banner"),
				(int)error.code, ms_str(error.localizedDescription));
	}
}

/** AdMob's per-impression revenue, in the shape Firebase's ad-revenue reports
 * expect. See the Android provider for what `precision` means and why it
 * travels with the figure. */
- (void)reportRevenue:(GADAdValue *)value network:(NSString *)network {
	MobileServicesAds *plugin = MobileServicesAds::get_singleton();
	if (!plugin || value == nil) {
		return;
	}
	NSDictionary *info = @{
		@"format" : self.format ?: @"",
		@"network" : network ?: @"admob",
		@"revenue" : @([value.value doubleValue]),
		@"currency" : value.currencyCode ?: @"USD",
		@"precision" : @((int)value.precision),
	};
	plugin->report_revenue(ms_str(self.placement), ms_json_from_dictionary(info));
}

@end

MobileServicesAds *MobileServicesAds::get_singleton() {
	return instance;
}

void MobileServicesAds::_bind_methods() {
	ClassDB::bind_method(D_METHOD("initializeAds", "provider", "config"), &MobileServicesAds::initialize_ads);
	ClassDB::bind_method(D_METHOD("isReady"), &MobileServicesAds::is_ready);
	ClassDB::bind_method(D_METHOD("getProvider"), &MobileServicesAds::get_provider);
	ClassDB::bind_method(D_METHOD("lastError"), &MobileServicesAds::last_error_message);
	ClassDB::bind_method(D_METHOD("loadAd", "placement", "format", "unit_id"), &MobileServicesAds::load_ad);
	ClassDB::bind_method(D_METHOD("showAd", "placement"), &MobileServicesAds::show_ad);
	ClassDB::bind_method(D_METHOD("isAdLoaded", "placement"), &MobileServicesAds::is_ad_loaded);
	ClassDB::bind_method(D_METHOD("showBanner", "placement", "unit_id", "position"), &MobileServicesAds::show_banner);
	ClassDB::bind_method(D_METHOD("hideBanner", "placement"), &MobileServicesAds::hide_banner);
	ClassDB::bind_method(D_METHOD("destroyAd", "placement"), &MobileServicesAds::destroy_ad);
	ClassDB::bind_method(D_METHOD("setMuted", "muted"), &MobileServicesAds::set_muted);
	ClassDB::bind_method(D_METHOD("setPrivacy", "has_consent", "under_age", "do_not_sell"),
			&MobileServicesAds::set_privacy);

	ADD_SIGNAL(MethodInfo("ads_initialized", PropertyInfo(Variant::STRING, "provider")));
	ADD_SIGNAL(MethodInfo("ads_initialization_failed", PropertyInfo(Variant::STRING, "message")));
	ADD_SIGNAL(MethodInfo("ad_loaded", PropertyInfo(Variant::STRING, "placement"),
			PropertyInfo(Variant::STRING, "format")));
	ADD_SIGNAL(MethodInfo("ad_load_failed", PropertyInfo(Variant::STRING, "placement"),
			PropertyInfo(Variant::STRING, "format"), PropertyInfo(Variant::INT, "code"),
			PropertyInfo(Variant::STRING, "message")));
	ADD_SIGNAL(MethodInfo("ad_shown", PropertyInfo(Variant::STRING, "placement"),
			PropertyInfo(Variant::STRING, "format")));
	ADD_SIGNAL(MethodInfo("ad_show_failed", PropertyInfo(Variant::STRING, "placement"),
			PropertyInfo(Variant::STRING, "format"), PropertyInfo(Variant::INT, "code"),
			PropertyInfo(Variant::STRING, "message")));
	ADD_SIGNAL(MethodInfo("ad_clicked", PropertyInfo(Variant::STRING, "placement"),
			PropertyInfo(Variant::STRING, "format")));
	ADD_SIGNAL(MethodInfo("ad_closed", PropertyInfo(Variant::STRING, "placement"),
			PropertyInfo(Variant::STRING, "format")));
	ADD_SIGNAL(MethodInfo("ad_reward_earned", PropertyInfo(Variant::STRING, "placement"),
			PropertyInfo(Variant::STRING, "type"), PropertyInfo(Variant::INT, "amount")));
	ADD_SIGNAL(MethodInfo("ad_revenue_paid", PropertyInfo(Variant::STRING, "placement"),
			PropertyInfo(Variant::STRING, "info")));
}

void MobileServicesAds::initialize_ads(const String &p_provider, const String &p_config_json) {
	@autoreleasepool {
		if (started) {
			MS_EMIT("ads_initialized", provider_name);
			return;
		}
		if (p_provider != String("admob")) {
			report_initialization_failed(
					"the iOS build of this SDK supports AdMob only; ads/provider is " + p_provider +
					". See docs/ios.md.");
			return;
		}
		NSDictionary *config = ms_dictionary_from_json(p_config_json);
		provider_name = "admob";
		GADMobileAds *ads = [GADMobileAds sharedInstance];
		NSArray *devices = config[@"test_device_ids"];
		if ([devices isKindOfClass:[NSArray class]] && devices.count > 0) {
			ads.requestConfiguration.testDeviceIdentifiers = devices;
		}
		NSString *rating = config[@"max_ad_content_rating"];
		if ([rating isKindOfClass:[NSString class]] && rating.length > 0) {
			ads.requestConfiguration.maxAdContentRating = rating;
		}
		if ([config[@"tag_for_child_directed_treatment"] boolValue]) {
			[ads.requestConfiguration setTagForChildDirectedTreatment:@YES];
		}
		if ([config[@"tag_for_under_age_of_consent"] boolValue]) {
			[ads.requestConfiguration setTagForUnderAgeOfConsent:@YES];
		}
		ads.applicationMuted = [config[@"muted"] boolValue];
		[ads startWithCompletionHandler:^(GADInitializationStatus *status) {
			MobileServicesAds *plugin = MobileServicesAds::get_singleton();
			if (plugin) {
				plugin->report_initialized();
			}
		}];
	}
}

static MSAdSlot *ms_slot(NSString *placement, NSString *format, NSString *unitID) {
	MSAdSlot *slot = ms_slots()[placement];
	if (slot == nil) {
		slot = [[MSAdSlot alloc] init];
		slot.placement = placement;
		ms_slots()[placement] = slot;
	}
	slot.format = format;
	slot.unitID = unitID;
	return slot;
}

void MobileServicesAds::load_ad(const String &p_placement, const String &p_format, const String &p_unit_id) {
	@autoreleasepool {
		NSString *placement = ms_ns(p_placement);
		NSString *format = ms_ns(p_format);
		MSAdSlot *slot = ms_slot(placement, format, ms_ns(p_unit_id));
		if (slot.fullScreenAd != nil) {
			return;
		}
		GADRequest *request = [GADRequest request];
		void (^failed)(NSError *) = ^(NSError *error) {
			MobileServicesAds *plugin = MobileServicesAds::get_singleton();
			if (plugin) {
				plugin->report_load_failed(ms_str(placement), ms_str(format),
						(int)error.code, ms_str(error.localizedDescription));
			}
		};
		void (^loaded)(void) = ^{
			MobileServicesAds *plugin = MobileServicesAds::get_singleton();
			if (plugin) {
				plugin->report_loaded(ms_str(placement), ms_str(format));
			}
		};

		if ([format isEqualToString:@"interstitial"]) {
			[GADInterstitialAd loadWithAdUnitID:slot.unitID
										request:request
							  completionHandler:^(GADInterstitialAd *ad, NSError *error) {
								  if (error != nil) { failed(error); return; }
								  ad.fullScreenContentDelegate = slot;
								  ad.paidEventHandler = ^(GADAdValue *value) {
									  [slot reportRevenue:value
												  network:ad.responseInfo.loadedAdNetworkResponseInfo
																  .adSourceName];
								  };
								  slot.fullScreenAd = ad;
								  loaded();
							  }];
		} else if ([format isEqualToString:@"rewarded"]) {
			[GADRewardedAd loadWithAdUnitID:slot.unitID
									request:request
						  completionHandler:^(GADRewardedAd *ad, NSError *error) {
							  if (error != nil) { failed(error); return; }
							  ad.fullScreenContentDelegate = slot;
							  ad.paidEventHandler = ^(GADAdValue *value) {
								  [slot reportRevenue:value
											  network:ad.responseInfo.loadedAdNetworkResponseInfo
															  .adSourceName];
							  };
							  slot.fullScreenAd = ad;
							  loaded();
						  }];
		} else if ([format isEqualToString:@"rewarded_interstitial"]) {
			[GADRewardedInterstitialAd loadWithAdUnitID:slot.unitID
												request:request
									  completionHandler:^(GADRewardedInterstitialAd *ad, NSError *error) {
										  if (error != nil) { failed(error); return; }
										  ad.fullScreenContentDelegate = slot;
										  slot.fullScreenAd = ad;
										  loaded();
									  }];
		} else if ([format isEqualToString:@"app_open"]) {
			[GADAppOpenAd loadWithAdUnitID:slot.unitID
								   request:request
						 completionHandler:^(GADAppOpenAd *ad, NSError *error) {
							 if (error != nil) { failed(error); return; }
							 ad.fullScreenContentDelegate = slot;
							 slot.fullScreenAd = ad;
							 loaded();
						 }];
		}
		// Banners load when they are shown; see show_banner.
	}
}

bool MobileServicesAds::show_ad(const String &p_placement) {
	@autoreleasepool {
		MSAdSlot *slot = ms_slots()[ms_ns(p_placement)];
		if (slot == nil || slot.fullScreenAd == nil) {
			return false;
		}
		UIViewController *controller = ms_root_controller();
		if (controller == nil) {
			return false;
		}
		id ad = slot.fullScreenAd;
		// Cleared before showing: AdMob's ad objects are single-use on iOS too,
		// and a second present does nothing at all — no callback, no error.
		slot.fullScreenAd = nil;
		NSString *placement = slot.placement;

		if ([ad isKindOfClass:[GADRewardedAd class]]) {
			GADRewardedAd *rewarded = (GADRewardedAd *)ad;
			[rewarded presentFromRootViewController:controller
								   userDidEarnRewardHandler:^{
									   MobileServicesAds *plugin = MobileServicesAds::get_singleton();
									   if (plugin) {
										   plugin->report_rewarded(ms_str(placement),
												   ms_str(rewarded.adReward.type),
												   [rewarded.adReward.amount intValue]);
									   }
								   }];
			return true;
		}
		if ([ad isKindOfClass:[GADRewardedInterstitialAd class]]) {
			GADRewardedInterstitialAd *rewarded = (GADRewardedInterstitialAd *)ad;
			[rewarded presentFromRootViewController:controller
								   userDidEarnRewardHandler:^{
									   MobileServicesAds *plugin = MobileServicesAds::get_singleton();
									   if (plugin) {
										   plugin->report_rewarded(ms_str(placement),
												   ms_str(rewarded.adReward.type),
												   [rewarded.adReward.amount intValue]);
									   }
								   }];
			return true;
		}
		if ([ad respondsToSelector:@selector(presentFromRootViewController:)]) {
			[ad performSelector:@selector(presentFromRootViewController:) withObject:controller];
			return true;
		}
		return false;
	}
}

bool MobileServicesAds::is_ad_loaded(const String &p_placement) {
	@autoreleasepool {
		MSAdSlot *slot = ms_slots()[ms_ns(p_placement)];
		return slot != nil && slot.fullScreenAd != nil;
	}
}

void MobileServicesAds::show_banner(const String &p_placement, const String &p_unit_id, const String &p_position) {
	@autoreleasepool {
		NSString *placement = ms_ns(p_placement);
		MSAdSlot *slot = ms_slot(placement, @"banner", ms_ns(p_unit_id));
		if (slot.bannerView != nil) {
			slot.bannerContainer.hidden = NO;
			return;
		}
		UIViewController *controller = ms_root_controller();
		if (controller == nil) {
			report_show_failed(p_placement, String("banner"), 0, String("no root view controller"));
			return;
		}
		CGFloat width = controller.view.frame.size.width;
		GADBannerView *banner =
				[[GADBannerView alloc] initWithAdSize:GADCurrentOrientationAnchoredAdaptiveBannerAdSizeWithWidth(width)];
		banner.adUnitID = slot.unitID;
		banner.rootViewController = controller;
		banner.delegate = slot;
		banner.paidEventHandler = ^(GADAdValue *value) {
			[slot reportRevenue:value
						network:banner.responseInfo.loadedAdNetworkResponseInfo.adSourceName];
		};
		banner.translatesAutoresizingMaskIntoConstraints = NO;
		[controller.view addSubview:banner];
		// Pinned to the SAFE AREA, not the view: a bottom banner pinned to the
		// view sits under the home indicator on every modern iPhone and eats the
		// taps meant for it.
		UILayoutGuide *safe = controller.view.safeAreaLayoutGuide;
		NSLayoutConstraint *vertical = (p_position == String("top"))
				? [banner.topAnchor constraintEqualToAnchor:safe.topAnchor]
				: [banner.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor];
		[NSLayoutConstraint activateConstraints:@[
			vertical,
			[banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
		]];
		slot.bannerView = banner;
		slot.bannerContainer = banner;
		[banner loadRequest:[GADRequest request]];
	}
}

void MobileServicesAds::hide_banner(const String &p_placement) {
	@autoreleasepool {
		MSAdSlot *slot = ms_slots()[ms_ns(p_placement)];
		slot.bannerContainer.hidden = YES;
	}
}

void MobileServicesAds::destroy_ad(const String &p_placement) {
	@autoreleasepool {
		NSString *placement = ms_ns(p_placement);
		MSAdSlot *slot = ms_slots()[placement];
		if (slot == nil) {
			return;
		}
		[slot.bannerView removeFromSuperview];
		slot.bannerView = nil;
		slot.bannerContainer = nil;
		slot.fullScreenAd = nil;
		[ms_slots() removeObjectForKey:placement];
	}
}

void MobileServicesAds::set_muted(bool p_muted) {
	@autoreleasepool {
		[GADMobileAds sharedInstance].applicationMuted = p_muted;
	}
}

/** AdMob reads consent from the UMP SDK itself, so there is nothing to forward.
 * See the Android provider for the full argument. */
void MobileServicesAds::set_privacy(bool p_has_consent, bool p_under_age, bool p_do_not_sell) {
}

void MobileServicesAds::report_initialized() {
	started = true;
	last_error = String();
	MS_EMIT("ads_initialized", provider_name);
}

void MobileServicesAds::report_initialization_failed(const String &p_message) {
	started = false;
	last_error = p_message;
	MS_EMIT("ads_initialization_failed", p_message);
}

void MobileServicesAds::report_loaded(const String &p_placement, const String &p_format) {
	MS_EMIT("ad_loaded", p_placement, p_format);
}

void MobileServicesAds::report_load_failed(const String &p_placement, const String &p_format,
		int p_code, const String &p_message) {
	last_error = p_message;
	MS_EMIT("ad_load_failed", p_placement, p_format, p_code, p_message);
}

void MobileServicesAds::report_shown(const String &p_placement, const String &p_format) {
	MS_EMIT("ad_shown", p_placement, p_format);
}

void MobileServicesAds::report_show_failed(const String &p_placement, const String &p_format,
		int p_code, const String &p_message) {
	last_error = p_message;
	MS_EMIT("ad_show_failed", p_placement, p_format, p_code, p_message);
}

void MobileServicesAds::report_clicked(const String &p_placement, const String &p_format) {
	MS_EMIT("ad_clicked", p_placement, p_format);
}

void MobileServicesAds::report_closed(const String &p_placement, const String &p_format) {
	MS_EMIT("ad_closed", p_placement, p_format);
}

void MobileServicesAds::report_rewarded(const String &p_placement, const String &p_type, int p_amount) {
	MS_EMIT("ad_reward_earned", p_placement, p_type, p_amount);
}

void MobileServicesAds::report_revenue(const String &p_placement, const String &p_json) {
	MS_EMIT("ad_revenue_paid", p_placement, p_json);
}

MobileServicesAds::MobileServicesAds() {
	ERR_FAIL_COND(instance != nullptr);
	instance = this;
}

MobileServicesAds::~MobileServicesAds() {
	if (instance == this) {
		instance = nullptr;
	}
}
