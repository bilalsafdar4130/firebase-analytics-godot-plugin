/**************************************************************************/
/*  ms_ads.h — MobileServicesAds on iOS                                   */
/**************************************************************************/
/*
 * The iOS half of the ad bridge. Same singleton name, methods and signals as
 * android/ads/, driven by the same `MSAds` GDScript service — so a game switches
 * platform without touching a line of ad code.
 *
 * ADMOB ONLY, FOR NOW. `initializeAds` answers `ads_initialization_failed` for
 * any other provider rather than pretending. Adding AppLovin MAX here is the
 * same shape of work as AdMobProvider.kt was on Android: one class implementing
 * the same seven operations. See docs/ios.md, "Adding a provider".
 *
 * PLACEMENTS, NOT UNIT IDS — as everywhere else in this SDK. The unit id arrives
 * as an argument and is forgotten afterwards; the game's vocabulary stays in
 * mobile_services.cfg.
 */

#ifndef MS_ADS_H
#define MS_ADS_H

#include "core/object/object.h"
#include "ms_common.h"

class MobileServicesAds : public Object {
	GDCLASS(MobileServicesAds, Object);

	static MobileServicesAds *instance;
	bool started = false;
	String provider_name = "none";
	String last_error;

protected:
	static void _bind_methods();

public:
	static MobileServicesAds *get_singleton();

	void initialize_ads(const String &p_provider, const String &p_config_json);
	bool is_ready() const { return started; }
	String get_provider() const { return provider_name; }
	String last_error_message() const { return last_error; }

	void load_ad(const String &p_placement, const String &p_format, const String &p_unit_id);
	bool show_ad(const String &p_placement);
	bool is_ad_loaded(const String &p_placement);
	void show_banner(const String &p_placement, const String &p_unit_id, const String &p_position);
	void hide_banner(const String &p_placement);
	void destroy_ad(const String &p_placement);
	void set_muted(bool p_muted);
	void set_privacy(bool p_has_consent, bool p_under_age, bool p_do_not_sell);

	/** Called from the Objective-C ad delegates, which is why these are public.
	 * Not bound to GDScript — they carry no ClassDB registration. */
	void report_loaded(const String &p_placement, const String &p_format);
	void report_load_failed(const String &p_placement, const String &p_format, int p_code, const String &p_message);
	void report_shown(const String &p_placement, const String &p_format);
	void report_show_failed(const String &p_placement, const String &p_format, int p_code, const String &p_message);
	void report_clicked(const String &p_placement, const String &p_format);
	void report_closed(const String &p_placement, const String &p_format);
	void report_rewarded(const String &p_placement, const String &p_type, int p_amount);
	void report_revenue(const String &p_placement, const String &p_json);
	void report_initialized();
	void report_initialization_failed(const String &p_message);

	MobileServicesAds();
	~MobileServicesAds();
};

#endif // MS_ADS_H
