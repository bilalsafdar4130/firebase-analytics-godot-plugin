/**************************************************************************/
/*  ms_consent.mm                                                         */
/**************************************************************************/

#import "ms_consent.h"

#import <AppTrackingTransparency/AppTrackingTransparency.h>
#import <UIKit/UIKit.h>
#import <UserMessagingPlatform/UserMessagingPlatform.h>

MobileServicesConsent *MobileServicesConsent::instance = nullptr;

/** IAB TCF v2 keys, written into NSUserDefaults by any conforming CMP — UMP
 * included. Reading them is the documented way for an app to find out what the
 * player agreed to; see the Android module for the same argument. */
static NSString *const kTCFGdprApplies = @"IABTCF_gdprApplies";
static NSString *const kTCFPurposeConsents = @"IABTCF_PurposeConsents";

static UIViewController *ms_consent_controller() {
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

static bool ms_purpose(NSString *consents, int number) {
	NSInteger index = number - 1;
	if (consents == nil || index < 0 || index >= (NSInteger)consents.length) {
		return false;
	}
	return [consents characterAtIndex:index] == '1';
}

MobileServicesConsent *MobileServicesConsent::get_singleton() {
	return instance;
}

void MobileServicesConsent::_bind_methods() {
	ClassDB::bind_method(D_METHOD("requestConsentUpdate", "under_age", "debug_geography", "test_devices"),
			&MobileServicesConsent::request_consent_update);
	ClassDB::bind_method(D_METHOD("showConsentFormIfRequired"),
			&MobileServicesConsent::show_consent_form_if_required);
	ClassDB::bind_method(D_METHOD("showPrivacyOptionsForm"), &MobileServicesConsent::show_privacy_options_form);
	ClassDB::bind_method(D_METHOD("canRequestAds"), &MobileServicesConsent::can_request_ads);
	ClassDB::bind_method(D_METHOD("isPrivacyOptionsRequired"), &MobileServicesConsent::is_privacy_options_required);
	ClassDB::bind_method(D_METHOD("getConsentStatus"), &MobileServicesConsent::get_consent_status);
	ClassDB::bind_method(D_METHOD("resetConsent"), &MobileServicesConsent::reset_consent);
	ClassDB::bind_method(D_METHOD("getConsentFlags"), &MobileServicesConsent::get_consent_flags);
	ClassDB::bind_method(D_METHOD("requestTrackingAuthorization"),
			&MobileServicesConsent::request_tracking_authorization);
	ClassDB::bind_method(D_METHOD("lastError"), &MobileServicesConsent::last_error_message);

	ADD_SIGNAL(MethodInfo("consent_updated", PropertyInfo(Variant::INT, "status"),
			PropertyInfo(Variant::BOOL, "can_request_ads"),
			PropertyInfo(Variant::BOOL, "privacy_options_required")));
	ADD_SIGNAL(MethodInfo("consent_form_dismissed", PropertyInfo(Variant::INT, "code"),
			PropertyInfo(Variant::STRING, "message")));
	ADD_SIGNAL(MethodInfo("tracking_status", PropertyInfo(Variant::INT, "status")));
}

void MobileServicesConsent::request_consent_update(bool p_under_age, int p_debug_geography,
		const String &p_test_devices) {
	@autoreleasepool {
		UMPRequestParameters *parameters = [[UMPRequestParameters alloc] init];
		parameters.tagForUnderAgeOfConsent = p_under_age;
		NSArray *devices = [ms_ns(p_test_devices) componentsSeparatedByString:@","];
		NSMutableArray *cleaned = [NSMutableArray array];
		for (NSString *device in devices) {
			NSString *trimmed = [device stringByTrimmingCharactersInSet:
										   [NSCharacterSet whitespaceCharacterSet]];
			if (trimmed.length > 0) {
				[cleaned addObject:trimmed];
			}
		}
		if (p_debug_geography != 0 || cleaned.count > 0) {
			// Debug settings only take effect on a device whose id is listed.
			// Forcing a geography on an unlisted device does nothing at all,
			// which is the usual reason "the form never appears in testing".
			UMPDebugSettings *debug = [[UMPDebugSettings alloc] init];
			debug.geography = (UMPDebugGeography)p_debug_geography;
			debug.testDeviceIdentifiers = cleaned;
			parameters.debugSettings = debug;
		}
		[UMPConsentInformation.sharedInstance
				requestConsentInfoUpdateWithParameters:parameters
									 completionHandler:^(NSError *error) {
										 MobileServicesConsent *plugin =
												 MobileServicesConsent::get_singleton();
										 if (!plugin) {
											 return;
										 }
										 if (error != nil) {
											 // Usually no network. It must not
											 // stop the game: canRequestAds still
											 // answers from what was cached.
											 plugin->last_error =
													 ms_str(error.localizedDescription);
										 }
										 plugin->announce();
									 }];
	}
}

void MobileServicesConsent::show_consent_form_if_required() {
	@autoreleasepool {
		UIViewController *controller = ms_consent_controller();
		if (controller == nil) {
			report_form_dismissed(1, String("no view controller to present the form from"));
			return;
		}
		[UMPConsentForm loadAndPresentIfRequiredFromViewController:controller
												completionHandler:^(NSError *error) {
													MobileServicesConsent *plugin =
															MobileServicesConsent::get_singleton();
													if (!plugin) {
														return;
													}
													plugin->report_form_dismissed(
															error == nil ? 0 : (int)error.code,
															error == nil ? String()
																		 : ms_str(error.localizedDescription));
													plugin->announce();
												}];
	}
}

void MobileServicesConsent::show_privacy_options_form() {
	@autoreleasepool {
		UIViewController *controller = ms_consent_controller();
		if (controller == nil) {
			report_form_dismissed(1, String("no view controller to present the form from"));
			return;
		}
		[UMPConsentForm presentPrivacyOptionsFormFromViewController:controller
												 completionHandler:^(NSError *error) {
													 MobileServicesConsent *plugin =
															 MobileServicesConsent::get_singleton();
													 if (!plugin) {
														 return;
													 }
													 plugin->report_form_dismissed(
															 error == nil ? 0 : (int)error.code,
															 error == nil ? String()
																		  : ms_str(error.localizedDescription));
													 plugin->announce();
												 }];
	}
}

bool MobileServicesConsent::can_request_ads() {
	return UMPConsentInformation.sharedInstance.canRequestAds;
}

bool MobileServicesConsent::is_privacy_options_required() {
	return UMPConsentInformation.sharedInstance.privacyOptionsRequirementStatus ==
			UMPPrivacyOptionsRequirementStatusRequired;
}

int MobileServicesConsent::get_consent_status() {
	return (int)UMPConsentInformation.sharedInstance.consentStatus;
}

void MobileServicesConsent::reset_consent() {
	[UMPConsentInformation.sharedInstance reset];
}

/** The four Google Consent Mode flags, derived from the TCF purposes. An
 * approximation that errs towards deny — see docs/privacy.md and the Android
 * module, which uses the identical rule. */
String MobileServicesConsent::get_consent_flags() {
	@autoreleasepool {
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
		// A missing key reads as 0 here, which is also "GDPR does not apply".
		// Both mean nothing is being withheld.
		NSInteger gdpr = [defaults integerForKey:kTCFGdprApplies];
		if (gdpr != 1) {
			return ms_json_from_dictionary(@{
				@"analytics_storage" : @YES,
				@"ad_storage" : @YES,
				@"ad_user_data" : @YES,
				@"ad_personalization" : @YES,
			});
		}
		NSString *purposes = [defaults stringForKey:kTCFPurposeConsents] ?: @"";
		bool storage = ms_purpose(purposes, 1);
		return ms_json_from_dictionary(@{
			@"analytics_storage" : @(storage && (ms_purpose(purposes, 8) ||
											 ms_purpose(purposes, 9) || ms_purpose(purposes, 10))),
			@"ad_storage" : @(storage && ms_purpose(purposes, 2)),
			@"ad_user_data" : @(storage && ms_purpose(purposes, 7)),
			@"ad_personalization" : @(storage && ms_purpose(purposes, 3) && ms_purpose(purposes, 4)),
		});
	}
}

/**
 * Apple's tracking prompt.
 *
 * Answers immediately with the existing status when the question has already
 * been asked — Apple allows the prompt once per install and silently returns the
 * previous answer afterwards, so a game must not treat "denied" as something to
 * ask about again.
 */
void MobileServicesConsent::request_tracking_authorization() {
	@autoreleasepool {
		if (@available(iOS 14.0, *)) {
			[ATTrackingManager requestTrackingAuthorizationWithCompletionHandler:^(
					ATTrackingManagerAuthorizationStatus status) {
				MobileServicesConsent *plugin = MobileServicesConsent::get_singleton();
				if (plugin) {
					plugin->MS_EMIT("tracking_status", (int)status);
				}
			}];
		} else {
			// Before iOS 14 there was no prompt and the IDFA was available
			// subject to the system setting. AUTHORIZED is the honest answer.
			MS_EMIT("tracking_status", 3);
		}
	}
}

void MobileServicesConsent::announce() {
	MS_EMIT("consent_updated", get_consent_status(), can_request_ads(), is_privacy_options_required());
}

void MobileServicesConsent::report_form_dismissed(int p_code, const String &p_message) {
	if (p_code != 0) {
		last_error = p_message;
	}
	MS_EMIT("consent_form_dismissed", p_code, p_message);
}

MobileServicesConsent::MobileServicesConsent() {
	ERR_FAIL_COND(instance != nullptr);
	instance = this;
}

MobileServicesConsent::~MobileServicesConsent() {
	if (instance == this) {
		instance = nullptr;
	}
}
