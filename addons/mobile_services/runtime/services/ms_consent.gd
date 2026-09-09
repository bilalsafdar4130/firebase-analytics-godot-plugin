class_name MSConsent
extends MSService
## Whether this player has agreed to be tracked, and what the rest of the SDK
## may do about it.
##
## THE ORDER MATTERS AND IT IS EASY TO GET WRONG. Google requires a consent
## decision BEFORE the ad SDK makes its first request in the EEA and the UK, and
## Firebase Analytics starts collecting from a ContentProvider that runs before
## the game's first frame. So this SDK does two things: the Android manifest
## defaults every Firebase consent flag to DENIED (see the export plugin), and
## [MobileServices] runs consent to completion before it starts the ad service.
## Nothing collects anything until this class has answered.
##
## APPLE'S ATT IS A SEPARATE QUESTION and this class keeps it separate. The UMP
## form is about GDPR; App Tracking Transparency is about the IDFA. A player can
## consent to one and refuse the other, both are asked on iOS, and
## [method get_tracking_status] answers the Apple half.
##
## A GAME MAY RUN ITS OWN UI INSTEAD. [method set_manual_consent] takes the four
## Consent Mode flags directly, for a project that has its own privacy screen or
## a legal team with opinions. What it must not do is skip the question: an
## EEA build serving personalised ads without a consent record is a policy
## violation, and Google enforces it by refusing to serve.

## Matches Google UMP's own `ConsentStatus`, so the numbers line up on both
## platforms and in Google's documentation.
enum Status {
	UNKNOWN = 0,
	REQUIRED = 1,
	NOT_REQUIRED = 2,
	OBTAINED = 3,
}

## Apple's `ATTrackingManager.AuthorizationStatus`, same reasoning.
enum Tracking {
	NOT_DETERMINED = 0,
	RESTRICTED = 1,
	DENIED = 2,
	AUTHORIZED = 3,
	## Not one of Apple's: this build is not on iOS, so the question does not
	## arise.
	NOT_APPLICABLE = 4,
}

signal consent_updated(status: int, can_request_ads: bool)
signal consent_form_dismissed(error: Dictionary)
signal tracking_authorization_updated(status: int)
## The four Consent Mode flags changed. [MobileServices] listens and passes
## them to analytics and ads; a game normally does not need to.
signal consent_flags_changed(flags: Dictionary)

## Denied until something says otherwise. Every default in this SDK points the
## same way, on purpose.
const DENIED_FLAGS := {
	"analytics_storage": false,
	"ad_storage": false,
	"ad_user_data": false,
	"ad_personalization": false,
}

var _status: Status = Status.UNKNOWN
var _can_request_ads := false
var _privacy_options_required := false
var _tracking: Tracking = Tracking.NOT_APPLICABLE
var _flags := DENIED_FLAGS.duplicate()


func is_enabled() -> bool:
	return config != null and bool(config.consent["enabled"])


func setup() -> void:
	if not is_enabled():
		# CONSENT OFF MEANS "THIS PROJECT HANDLES IT", NOT "DENY EVERYTHING".
		#
		# The export plugin writes Firebase's consent defaults into the manifest
		# as DENIED, so the SDK collects nothing before the game has spoken. If
		# this service then also stayed denied, a project that simply never
		# switched consent on would ship with analytics silently dead — the
		# single worst failure mode this SDK could have, because the symptom is
		# an empty dashboard that looks like a game nobody plays.
		#
		# So it grants, and says out loud what that means.
		_status = Status.NOT_REQUIRED
		_can_request_ads = true
		_flags = {
			"analytics_storage": true,
			"ad_storage": true,
			"ad_user_data": true,
			"ad_personalization": true,
		}
		log.warn(service_name, (
			"consent management is off, so the SDK grants Firebase and the ad SDK "
			+ "full consent. Shipping to the EEA, the UK or Switzerland without a "
			+ "consent form breaks Google's policy — set consent/enabled = true, "
			+ "or call MobileServices.consent.set_manual_consent() from your own "
			+ "privacy screen. See docs/privacy.md."
		))
		_started = true
		consent_flags_changed.emit(get_flags())
		return
	if not is_available():
		# No UMP in this build — the editor, a desktop run, or an export without
		# the consent plugin. Ads and analytics must not be held hostage to a
		# form that cannot be shown, so this reports "no decision needed" the way
		# a non-EEA device would.
		_status = Status.NOT_REQUIRED
		_can_request_ads = true
		_flags = {
			"analytics_storage": true,
			"ad_storage": true,
			"ad_user_data": true,
			"ad_personalization": false,
		}
		_started = true
		consent_flags_changed.emit(get_flags())
		return
	native.connect_signal("consent_updated", _on_native_updated)
	native.connect_signal("consent_form_dismissed", _on_native_form_dismissed)
	native.connect_signal("tracking_status", _on_native_tracking_status)
	_started = true
	if bool(config.consent["request_on_start"]):
		request_update()


## Asks Google whether this player needs to be shown a consent form.
##
## Answers on [signal consent_updated]. Costs a network round trip; the result
## is cached by the UMP SDK for the session.
func request_update() -> Dictionary:
	var problem := guard("update consent information")
	if not problem.is_empty():
		return problem
	# Comma-separated rather than an array: the native boundary in this SDK
	# carries primitives only. See MSService's "The native boundary" note.
	native.call_method("requestConsentUpdate", [
		bool(config.consent["under_age_of_consent"]),
		_debug_geography_code(),
		",".join(config.consent["test_device_hashed_ids"]),
	])
	return {}


## Shows the consent form when one is required, and does nothing when it is not.
##
## Safe to call on every launch: outside the EEA and the UK it is a no-op, and
## for a player who has already decided it is also a no-op.
func show_form_if_required() -> Dictionary:
	var problem := guard("show the consent form")
	if not problem.is_empty():
		return problem
	native.call_method("showConsentFormIfRequired")
	return {}


## Re-opens the form so a player can change their mind.
##
## Google REQUIRES this to be reachable from the game — a settings entry, a
## privacy button — for any app that showed a form in the first place.
## [method is_privacy_options_required] says whether to show the button.
func show_privacy_options() -> Dictionary:
	var problem := guard("show privacy options")
	if not problem.is_empty():
		return problem
	if not _privacy_options_required:
		return fail(
			MSError.UNSUPPORTED,
			"this player was not shown a consent form, so there is nothing to revisit"
		)
	native.call_method("showPrivacyOptionsForm")
	return {}


## Whether to show a "Privacy settings" entry. False outside the EEA and the UK.
func is_privacy_options_required() -> bool:
	return _privacy_options_required


## Whether the ad SDK may make requests yet. [MobileServices] waits for this
## before starting the ad service.
func can_request_ads() -> bool:
	if not is_enabled():
		# Consent management off means the project answers this itself; the SDK
		# does not hold ads hostage to a service the game switched off.
		return true
	return _can_request_ads


func get_status() -> Status:
	return _status


## The four Consent Mode flags currently in effect.
func get_flags() -> Dictionary:
	return _flags.duplicate()


## Asks for the IDFA. iOS only; answers NOT_APPLICABLE anywhere else.
##
## Apple only allows the prompt once per install, ever. Ask at a moment the
## player understands why — after the first level, not on the splash screen —
## and expect most people to say no.
func request_tracking_authorization() -> Dictionary:
	if MSConfig.current_platform() != "ios":
		_tracking = Tracking.NOT_APPLICABLE
		return fail(MSError.UNSUPPORTED, "App Tracking Transparency is iOS only")
	var problem := guard("request tracking authorization")
	if not problem.is_empty():
		return problem
	native.call_method("requestTrackingAuthorization")
	return {}


func get_tracking_status() -> Tracking:
	return _tracking


## Sets the four Consent Mode flags directly, for a game running its own
## privacy UI.
##
## This is the whole interface for the "we do our own consent" case: set the
## flags, and analytics and ads follow. Set `consent/enabled = false` in
## `mobile_services.cfg` so the SDK does not also show Google's form.
func set_manual_consent(
	analytics_storage: bool,
	ad_storage: bool,
	ad_user_data: bool,
	ad_personalization: bool
) -> void:
	_flags = {
		"analytics_storage": analytics_storage,
		"ad_storage": ad_storage,
		"ad_user_data": ad_user_data,
		"ad_personalization": ad_personalization,
	}
	_status = Status.OBTAINED
	_can_request_ads = ad_storage or analytics_storage
	log.info(service_name, "consent set by the game: %s" % _flags)
	consent_flags_changed.emit(get_flags())
	consent_updated.emit(_status, _can_request_ads)


## Clears the stored decision so the form appears again. Test only — it refuses
## outside `core/test_mode`, because a shipped build that resets consent asks
## every player on every launch.
func reset() -> Dictionary:
	if not bool(config.core["test_mode"]):
		return fail(MSError.INVALID_ARGUMENT, "reset() only works with core/test_mode = true")
	var problem := guard("reset consent")
	if not problem.is_empty():
		return problem
	_status = Status.UNKNOWN
	_flags = DENIED_FLAGS.duplicate()
	_can_request_ads = false
	native.call_method("resetConsent")
	return {}


func _debug_geography_code() -> int:
	# UMP's DebugGeography: 0 disabled, 1 EEA, 2 not EEA.
	match str(config.consent["debug_geography"]):
		"eea":
			return 1
		"not_eea":
			return 2
	return 0


func _on_native_updated(status: int, can_request_ads: bool, privacy_options_required: bool) -> void:
	_status = status as Status
	_can_request_ads = can_request_ads
	_privacy_options_required = privacy_options_required
	var flags := parse_object(str(native.call_method("getConsentFlags", [], "")))
	if not flags.is_empty():
		for key in DENIED_FLAGS:
			_flags[key] = bool(flags.get(key, false))
	else:
		# No per-purpose information from the platform. Fall back to the one
		# thing that is always known — whether Google will serve ads — and keep
		# the personalisation flags denied, which is the safe direction.
		_flags = {
			"analytics_storage": can_request_ads,
			"ad_storage": can_request_ads,
			"ad_user_data": can_request_ads,
			"ad_personalization": false,
		}
	log.info(service_name, "consent status %d, ads %s" % [
		_status, "allowed" if _can_request_ads else "not allowed"
	])
	consent_flags_changed.emit(get_flags())
	consent_updated.emit(_status, _can_request_ads)


func _on_native_form_dismissed(code: int, message: String) -> void:
	if code == 0:
		consent_form_dismissed.emit({})
		return
	var error := record(MSError.make(MSError.CONSENT_REQUIRED, message, service_name, code))
	consent_form_dismissed.emit(error)


func _on_native_tracking_status(status: int) -> void:
	_tracking = status as Tracking
	tracking_authorization_updated.emit(_tracking)


func diagnostics() -> Dictionary:
	var report := super.diagnostics()
	report["status"] = _status
	report["can_request_ads"] = _can_request_ads
	report["privacy_options_required"] = _privacy_options_required
	report["tracking"] = _tracking
	report["flags"] = _flags
	return report
