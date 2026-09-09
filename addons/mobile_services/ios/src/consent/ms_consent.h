/**************************************************************************/
/*  ms_consent.h — MobileServicesConsent on iOS                           */
/**************************************************************************/
/*
 * Google's UMP consent form, and Apple's App Tracking Transparency prompt.
 *
 * THEY ARE TWO DIFFERENT QUESTIONS and this file keeps them apart. UMP is about
 * GDPR and decides whether ads may be personalised; ATT is about the IDFA and
 * decides whether the device may be tracked across apps. A player can consent to
 * one and refuse the other, iOS asks both, and conflating them is how apps end
 * up serving personalised ads to somebody who said no.
 *
 * ORDER MATTERS: Google requires the UMP form to be shown BEFORE ATT, because
 * the ATT prompt is meaningless to a player who has not yet been told what the
 * app collects. `MobileServices` runs consent to completion before ads start,
 * and a game should call `request_tracking_authorization()` after that — at a
 * moment the player understands, not on the splash screen. Apple allows the
 * prompt once per install, ever.
 */

#ifndef MS_CONSENT_H
#define MS_CONSENT_H

#include "core/object/object.h"
#include "ms_common.h"

class MobileServicesConsent : public Object {
	GDCLASS(MobileServicesConsent, Object);

	static MobileServicesConsent *instance;
	String last_error;

protected:
	static void _bind_methods();

public:
	static MobileServicesConsent *get_singleton();

	void request_consent_update(bool p_under_age, int p_debug_geography, const String &p_test_devices);
	void show_consent_form_if_required();
	void show_privacy_options_form();
	bool can_request_ads();
	bool is_privacy_options_required();
	int get_consent_status();
	void reset_consent();
	String get_consent_flags();
	void request_tracking_authorization();
	String last_error_message() const { return last_error; }

	void announce();
	void report_form_dismissed(int p_code, const String &p_message);

	MobileServicesConsent();
	~MobileServicesConsent();
};

#endif // MS_CONSENT_H
