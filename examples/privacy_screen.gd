extends Control
## A game's own privacy screen, and the delete-my-data button.
##
## Two ways to do consent, and they must not be mixed:
##
## A. Let Google's UMP do it — `consent/enabled = true` and this file's
##    `_on_privacy_settings_pressed` is the only part you need.
## B. Run your own UI — `consent/enabled = false` and call
##    `set_manual_consent()`. Everything else here.
##
## Doing both asks the player twice.

@onready var analytics_toggle: CheckBox = %AnalyticsToggle
@onready var personalised_toggle: CheckBox = %PersonalisedToggle
@onready var privacy_settings_button: Button = %PrivacySettings


func _ready() -> void:
	# Google requires a way back into the form for any app that showed one. This
	# is false outside the EEA/UK, so the button hides itself where it is not
	# needed rather than confusing everyone else.
	privacy_settings_button.visible = MobileServices.consent.is_privacy_options_required()

	var flags := MobileServices.consent.get_flags()
	analytics_toggle.button_pressed = bool(flags.get("analytics_storage", false))
	personalised_toggle.button_pressed = bool(flags.get("ad_personalization", false))


# --- A. Google's own form -----------------------------------------------

func _on_privacy_settings_pressed() -> void:
	MobileServices.consent.show_privacy_options()


# --- B. Your own UI -----------------------------------------------------

func _on_save_pressed() -> void:
	var analytics := analytics_toggle.button_pressed
	var personalised := personalised_toggle.button_pressed
	# Four Consent Mode flags: analytics storage, ad storage, ad user data, ad
	# personalisation. Analytics and ads follow immediately — Firebase's
	# collection switch and the ad SDK's privacy settings are both updated.
	MobileServices.consent.set_manual_consent(
		analytics,
		personalised,   # ad_storage
		personalised,   # ad_user_data
		personalised    # ad_personalization
	)


# --- Apple's tracking prompt --------------------------------------------

## Ask at a moment the player understands why — after the first level, not on
## the splash screen. Apple allows the prompt ONCE PER INSTALL, ever, and expects
## most people to say no. Google requires the UMP form to be shown first.
func ask_for_tracking_after_first_level() -> void:
	if MobileServices.consent.get_tracking_status() != MSConsent.Tracking.NOT_DETERMINED:
		return
	MobileServices.consent.request_tracking_authorization()


# --- Delete my data -----------------------------------------------------

func _on_delete_my_data_pressed() -> void:
	# There is no account to close: this SDK never collects one. The app instance
	# id, the anonymous player id and the local save are the whole of it.
	MobileServices.analytics.reset_data()
	MobileServices.player.reset_id()
	DirAccess.remove_absolute("user://save.dat")
	DirAccess.remove_absolute(MSIap.CACHE_PATH)
	%Message.text = "Your data has been deleted from this device."
