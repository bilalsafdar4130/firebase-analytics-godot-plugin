/**************************************************************************/
/*  ms_firebase.mm                                                        */
/**************************************************************************/

#import "ms_firebase.h"

#import <Foundation/Foundation.h>

@import FirebaseCore;
@import FirebaseAnalytics;

MobileServicesFirebase *MobileServicesFirebase::instance = nullptr;

/** Firebase's limits, applied here so a truncated value is never a surprise.
 * The GDScript side applies the same ones; both, because either half can be the
 * one a game reaches first. */
static const int MS_MAX_PARAM_CHARS = 100;

/**
 * A Godot Dictionary as the NSDictionary Firebase wants.
 *
 * Ints widen to long long and floats to double for the reason the Android side
 * gives: Firebase registers a parameter's type from the first event carrying it,
 * and a value that arrives as an int on one build and a float on the next is a
 * column that stops aggregating.
 */
static NSDictionary *ms_params(const Dictionary &p_params) {
	NSMutableDictionary *out = [NSMutableDictionary dictionary];
	Array keys = p_params.keys();
	for (int i = 0; i < keys.size(); i++) {
		String key = keys[i];
		Variant value = p_params[keys[i]];
		NSString *name = ms_ns(key);
		switch (value.get_type()) {
			case Variant::BOOL:
				out[name] = @((long long)((bool)value ? 1 : 0));
				break;
			case Variant::INT:
				out[name] = @((long long)value);
				break;
			case Variant::FLOAT:
				out[name] = @((double)value);
				break;
			default: {
				String text = value;
				if (text.length() > MS_MAX_PARAM_CHARS) {
					text = text.substr(0, MS_MAX_PARAM_CHARS);
				}
				out[name] = ms_ns(text);
			} break;
		}
	}
	return out;
}

MobileServicesFirebase *MobileServicesFirebase::get_singleton() {
	return instance;
}

void MobileServicesFirebase::_bind_methods() {
	ClassDB::bind_method(D_METHOD("initializeFirebase", "analytics", "crashlytics", "remote_config"),
			&MobileServicesFirebase::initialize_firebase);
	ClassDB::bind_method(D_METHOD("isReady"), &MobileServicesFirebase::is_ready);
	ClassDB::bind_method(D_METHOD("lastError"), &MobileServicesFirebase::last_error_message);
	ClassDB::bind_method(D_METHOD("logEvent", "event", "params"), &MobileServicesFirebase::log_event);
	ClassDB::bind_method(D_METHOD("logScreenView", "name", "class"), &MobileServicesFirebase::log_screen_view);
	ClassDB::bind_method(D_METHOD("setUserProperty", "name", "value"), &MobileServicesFirebase::set_user_property);
	ClassDB::bind_method(D_METHOD("setUserId", "id"), &MobileServicesFirebase::set_user_id);
	ClassDB::bind_method(D_METHOD("setAnalyticsCollectionEnabled", "enabled"),
			&MobileServicesFirebase::set_analytics_collection_enabled);
	ClassDB::bind_method(D_METHOD("setConsent", "analytics_storage", "ad_storage", "ad_user_data", "ad_personalization"),
			&MobileServicesFirebase::set_consent);
	ClassDB::bind_method(D_METHOD("resetAnalyticsData"), &MobileServicesFirebase::reset_analytics_data);

	ClassDB::bind_method(D_METHOD("setCrashlyticsCollectionEnabled", "enabled"),
			&MobileServicesFirebase::set_crashlytics_collection_enabled);
	ClassDB::bind_method(D_METHOD("crashlyticsLog", "message"), &MobileServicesFirebase::crashlytics_log);
	ClassDB::bind_method(D_METHOD("crashlyticsSetKey", "key", "value"), &MobileServicesFirebase::crashlytics_set_key);
	ClassDB::bind_method(D_METHOD("crashlyticsRecordError", "name", "reason", "context"),
			&MobileServicesFirebase::crashlytics_record_error);
	ClassDB::bind_method(D_METHOD("crashlyticsTestCrash"), &MobileServicesFirebase::crashlytics_test_crash);

	ClassDB::bind_method(D_METHOD("remoteConfigSetDefaults", "defaults"),
			&MobileServicesFirebase::remote_config_set_defaults);
	ClassDB::bind_method(D_METHOD("remoteConfigFetch", "minimum_interval_seconds"),
			&MobileServicesFirebase::remote_config_fetch);
	ClassDB::bind_method(D_METHOD("remoteConfigGetAll"), &MobileServicesFirebase::remote_config_get_all);

	ADD_SIGNAL(MethodInfo("firebase_ready"));
	ADD_SIGNAL(MethodInfo("firebase_failed", PropertyInfo(Variant::STRING, "message")));
	ADD_SIGNAL(MethodInfo("remote_config_fetched", PropertyInfo(Variant::BOOL, "updated")));
	ADD_SIGNAL(MethodInfo("remote_config_failed",
			PropertyInfo(Variant::INT, "code"), PropertyInfo(Variant::STRING, "message")));
}

bool MobileServicesFirebase::initialize_firebase(bool p_analytics, bool p_crashlytics, bool p_remote_config) {
	@autoreleasepool {
		if (!p_analytics) {
			return false;
		}
		if (ready) {
			return true;
		}
		if ([FIRApp defaultApp] == nil) {
			// Reads GoogleService-Info.plist from the bundle. Without that file
			// this is where an iOS Firebase build fails, and it fails loudly —
			// which is better than the Android equivalent, where a missing
			// string resource just makes the SDK do nothing.
			@try {
				[FIRApp configure];
			} @catch (NSException *exception) {
				last_error = ms_str(exception.reason);
				MS_EMIT("firebase_failed", last_error);
				return false;
			}
		}
		if ([FIRApp defaultApp] == nil) {
			last_error = String("GoogleService-Info.plist is missing from the app bundle");
			MS_EMIT("firebase_failed", last_error);
			return false;
		}
		ready = true;
		last_error = String();
		// Looked up by name so this file never references the optional
		// frameworks directly — an app that links only FirebaseAnalytics still
		// loads and runs. Same reasoning as the Android module's Class.forName.
		crashlytics_available = p_crashlytics && (NSClassFromString(@"FIRCrashlytics") != nil);
		remote_config_available = p_remote_config && (NSClassFromString(@"FIRRemoteConfig") != nil);
		return true;
	}
}

void MobileServicesFirebase::log_event(const String &p_event, const Dictionary &p_params) {
	@autoreleasepool {
		if (!ready) {
			return;
		}
		[FIRAnalytics logEventWithName:ms_ns(p_event) parameters:ms_params(p_params)];
	}
}

void MobileServicesFirebase::log_screen_view(const String &p_name, const String &p_class) {
	@autoreleasepool {
		if (!ready) {
			return;
		}
		[FIRAnalytics logEventWithName:kFIREventScreenView
							parameters:@{
								kFIRParameterScreenName : ms_ns(p_name),
								kFIRParameterScreenClass : ms_ns(p_class),
							}];
	}
}

void MobileServicesFirebase::set_user_property(const String &p_name, const String &p_value) {
	@autoreleasepool {
		if (!ready) {
			return;
		}
		[FIRAnalytics setUserPropertyString:ms_ns(p_value) forName:ms_ns(p_name)];
	}
}

void MobileServicesFirebase::set_user_id(const String &p_id) {
	@autoreleasepool {
		if (!ready) {
			return;
		}
		[FIRAnalytics setUserID:p_id.is_empty() ? nil : ms_ns(p_id)];
		if (crashlytics_available) {
			id crashlytics = [NSClassFromString(@"FIRCrashlytics") performSelector:@selector(crashlytics)];
			if ([crashlytics respondsToSelector:@selector(setUserID:)]) {
				[crashlytics performSelector:@selector(setUserID:) withObject:ms_ns(p_id)];
			}
		}
	}
}

void MobileServicesFirebase::set_analytics_collection_enabled(bool p_enabled) {
	@autoreleasepool {
		[FIRAnalytics setAnalyticsCollectionEnabled:p_enabled];
	}
}

void MobileServicesFirebase::set_consent(bool p_analytics, bool p_ad_storage,
		bool p_ad_user_data, bool p_ad_personalization) {
	@autoreleasepool {
		[FIRAnalytics setConsent:@{
			FIRConsentTypeAnalyticsStorage : p_analytics ? FIRConsentStatusGranted : FIRConsentStatusDenied,
			FIRConsentTypeAdStorage : p_ad_storage ? FIRConsentStatusGranted : FIRConsentStatusDenied,
			FIRConsentTypeAdUserData : p_ad_user_data ? FIRConsentStatusGranted : FIRConsentStatusDenied,
			FIRConsentTypeAdPersonalization : p_ad_personalization ? FIRConsentStatusGranted : FIRConsentStatusDenied,
		}];
	}
}

void MobileServicesFirebase::reset_analytics_data() {
	@autoreleasepool {
		[FIRAnalytics resetAnalyticsData];
	}
}

// --- Crashlytics, reached only by name ---------------------------------

void MobileServicesFirebase::set_crashlytics_collection_enabled(bool p_enabled) {
	@autoreleasepool {
		if (!crashlytics_available) {
			return;
		}
		id crashlytics = [NSClassFromString(@"FIRCrashlytics") performSelector:@selector(crashlytics)];
		SEL selector = @selector(setCrashlyticsCollectionEnabled:);
		if ([crashlytics respondsToSelector:selector]) {
			NSMethodSignature *signature = [crashlytics methodSignatureForSelector:selector];
			NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
			[call setSelector:selector];
			[call setTarget:crashlytics];
			BOOL enabled = p_enabled;
			[call setArgument:&enabled atIndex:2];
			[call invoke];
		}
	}
}

void MobileServicesFirebase::crashlytics_log(const String &p_message) {
	@autoreleasepool {
		if (!crashlytics_available) {
			return;
		}
		id crashlytics = [NSClassFromString(@"FIRCrashlytics") performSelector:@selector(crashlytics)];
		if ([crashlytics respondsToSelector:@selector(log:)]) {
			[crashlytics performSelector:@selector(log:) withObject:ms_ns(p_message)];
		}
	}
}

void MobileServicesFirebase::crashlytics_set_key(const String &p_key, const String &p_value) {
	@autoreleasepool {
		if (!crashlytics_available) {
			return;
		}
		id crashlytics = [NSClassFromString(@"FIRCrashlytics") performSelector:@selector(crashlytics)];
		SEL selector = @selector(setCustomValue:forKey:);
		if ([crashlytics respondsToSelector:selector]) {
			[crashlytics performSelector:selector withObject:ms_ns(p_value) withObject:ms_ns(p_key)];
		}
	}
}

void MobileServicesFirebase::crashlytics_record_error(const String &p_name,
		const String &p_reason, const String &p_context) {
	@autoreleasepool {
		if (!crashlytics_available) {
			return;
		}
		id crashlytics = [NSClassFromString(@"FIRCrashlytics") performSelector:@selector(crashlytics)];
		if (!p_context.is_empty() && p_context != String("{}") &&
				[crashlytics respondsToSelector:@selector(log:)]) {
			[crashlytics performSelector:@selector(log:)
							  withObject:[NSString stringWithFormat:@"%@ context: %@",
											 ms_ns(p_name), ms_ns(p_context)]];
		}
		// Grouped by domain and code the way the Android side groups by class and
		// message: the name is the group, the reason is the detail.
		NSError *error = [NSError errorWithDomain:ms_ns(p_name)
											 code:0
										 userInfo:@{ NSLocalizedDescriptionKey : ms_ns(p_reason) }];
		if ([crashlytics respondsToSelector:@selector(recordError:)]) {
			[crashlytics performSelector:@selector(recordError:) withObject:error];
		}
	}
}

void MobileServicesFirebase::crashlytics_test_crash() {
	// Deliberate; the GDScript side refuses to call it outside core/test_mode.
	@[][1];
}

// --- Remote Config, reached only by name -------------------------------

void MobileServicesFirebase::remote_config_set_defaults(const String &p_defaults_json) {
	@autoreleasepool {
		if (!remote_config_available) {
			return;
		}
		NSDictionary *defaults = ms_dictionary_from_json(p_defaults_json);
		if (defaults.count == 0) {
			return;
		}
		id config = [NSClassFromString(@"FIRRemoteConfig") performSelector:@selector(remoteConfig)];
		if ([config respondsToSelector:@selector(setDefaults:)]) {
			[config performSelector:@selector(setDefaults:) withObject:defaults];
		}
	}
}

void MobileServicesFirebase::remote_config_fetch(int p_minimum_interval_seconds) {
	@autoreleasepool {
		if (!remote_config_available) {
			MS_EMIT("remote_config_failed", 3, String("Remote Config is not in this build"));
			return;
		}
		id config = [NSClassFromString(@"FIRRemoteConfig") performSelector:@selector(remoteConfig)];
		SEL fetch = @selector(fetchWithExpirationDuration:completionHandler:);
		if (![config respondsToSelector:fetch]) {
			MS_EMIT("remote_config_failed", 3, String("Remote Config is not usable"));
			return;
		}
		NSTimeInterval expiration = (NSTimeInterval)p_minimum_interval_seconds;
		void (^completion)(NSInteger, NSError *) = ^(NSInteger status, NSError *error) {
			if (error != nil) {
				MS_EMIT("remote_config_failed", 2, ms_str(error.localizedDescription));
				return;
			}
			if ([config respondsToSelector:@selector(activateWithCompletion:)]) {
				[config activateWithCompletion:^(BOOL changed, NSError *activateError) {
					if (activateError != nil) {
						MS_EMIT("remote_config_failed", 2, ms_str(activateError.localizedDescription));
					} else {
						MS_EMIT("remote_config_fetched", (bool)changed);
					}
				}];
			} else {
				MS_EMIT("remote_config_fetched", false);
			}
		};
		NSMethodSignature *signature = [config methodSignatureForSelector:fetch];
		NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
		[call setSelector:fetch];
		[call setTarget:config];
		[call setArgument:&expiration atIndex:2];
		[call setArgument:&completion atIndex:3];
		[call invoke];
	}
}

String MobileServicesFirebase::remote_config_get_all() {
	@autoreleasepool {
		if (!remote_config_available) {
			return String("{}");
		}
		id config = [NSClassFromString(@"FIRRemoteConfig") performSelector:@selector(remoteConfig)];
		SEL all_keys = @selector(allKeysFromSource:);
		if (![config respondsToSelector:all_keys]) {
			return String("{}");
		}
		// Source 0 is FIRRemoteConfigSourceRemote; the GDScript side merges the
		// game's own defaults over the top, so only fetched values travel.
		NSArray *keys = [config performSelector:all_keys withObject:@(0)];
		NSMutableDictionary *values = [NSMutableDictionary dictionary];
		for (NSString *key in keys) {
			id value = [config performSelector:@selector(configValueForKey:) withObject:key];
			if ([value respondsToSelector:@selector(stringValue)]) {
				NSString *text = [value performSelector:@selector(stringValue)];
				if (text != nil) {
					values[key] = text;
				}
			}
		}
		return ms_json_from_dictionary(values);
	}
}

MobileServicesFirebase::MobileServicesFirebase() {
	ERR_FAIL_COND(instance != nullptr);
	instance = this;
}

MobileServicesFirebase::~MobileServicesFirebase() {
	if (instance == this) {
		instance = nullptr;
	}
}
