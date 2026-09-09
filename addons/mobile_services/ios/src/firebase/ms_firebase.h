/**************************************************************************/
/*  ms_firebase.h — MobileServicesFirebase on iOS                         */
/**************************************************************************/
/*
 * The iOS half of the Firebase bridge: the same singleton name, method names and
 * signal names as android/firebase/, so one GDScript service drives both.
 *
 * FIREBASE STARTS ITSELF ON iOS TOO, from GoogleService-Info.plist, which the
 * export plugin bundles. `[FIRApp configure]` is called here rather than left to
 * an app-delegate swizzle, because Godot's own delegate is not Firebase's and
 * the order the two run in is not something to rely on.
 *
 * Crashlytics and Remote Config are optional in the same way as on Android:
 * their classes are looked up with NSClassFromString and never referenced
 * directly, so an app that links only FirebaseAnalytics still runs.
 */

#ifndef MS_FIREBASE_H
#define MS_FIREBASE_H

#include "core/object/object.h"
#include "core/variant/dictionary.h"
#include "ms_common.h"

class MobileServicesFirebase : public Object {
	GDCLASS(MobileServicesFirebase, Object);

	static MobileServicesFirebase *instance;
	bool ready = false;
	bool crashlytics_available = false;
	bool remote_config_available = false;
	String last_error;

protected:
	static void _bind_methods();

public:
	static MobileServicesFirebase *get_singleton();

	bool initialize_firebase(bool p_analytics, bool p_crashlytics, bool p_remote_config);
	bool is_ready() const { return ready; }
	String last_error_message() const { return last_error; }

	void log_event(const String &p_event, const Dictionary &p_params);
	void log_screen_view(const String &p_name, const String &p_class);
	void set_user_property(const String &p_name, const String &p_value);
	void set_user_id(const String &p_id);
	void set_analytics_collection_enabled(bool p_enabled);
	void set_consent(bool p_analytics, bool p_ad_storage, bool p_ad_user_data, bool p_ad_personalization);
	void reset_analytics_data();

	void set_crashlytics_collection_enabled(bool p_enabled);
	void crashlytics_log(const String &p_message);
	void crashlytics_set_key(const String &p_key, const String &p_value);
	void crashlytics_record_error(const String &p_name, const String &p_reason, const String &p_context);
	void crashlytics_test_crash();

	void remote_config_set_defaults(const String &p_defaults_json);
	void remote_config_fetch(int p_minimum_interval_seconds);
	String remote_config_get_all();

	MobileServicesFirebase();
	~MobileServicesFirebase();
};

#endif // MS_FIREBASE_H
