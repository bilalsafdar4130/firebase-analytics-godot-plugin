class_name MSLegacyFirebase
extends RefCounted
## The 1.x `FirebaseAnalyticsBridge` API, forwarded to the 2.x SDK.
##
## FOR GAMES ALREADY SHIPPING AGAINST THE OLD ADDON. Version 1.x exposed one
## Android singleton called `FirebaseAnalyticsBridge` with six methods, and game
## code reached it directly:
##
##     var firebase := Engine.get_singleton("FirebaseAnalyticsBridge")
##     firebase.logEvent("level_end", {"level_name": "grid_012"})
##
## That still works unchanged in 2.x — the Android build keeps registering that
## singleton, see `FirebaseAnalyticsCompatPlugin.kt` — so upgrading the addon
## breaks nothing on day one.
##
## This class is for the day after: it has the same six methods with the same
## names and signatures, but goes through [MobileServices] instead of the native
## singleton, so it also works on iOS, on desktop, and in the editor, where the
## old singleton does not exist at all. Swap the `Engine.get_singleton` line for
## `MSLegacyFirebase.new()` and nothing else has to change:
##
##     var firebase := MSLegacyFirebase.new()
##     firebase.logEvent("level_end", {"level_name": "grid_012"})
##
## Then port the call sites to `MobileServices.analytics.log_event(...)` at
## leisure. See MIGRATION.md.
##
## Deprecated: new code should call [MSAnalytics] directly.


func logEvent(event: String, params: Dictionary = {}) -> void:
	MobileServices.analytics.log_event(event, params)


func setUserProperty(name: String, value: String) -> void:
	MobileServices.analytics.set_user_property(name, value)


func setAnalyticsCollectionEnabled(enabled: bool) -> void:
	MobileServices.analytics.set_collection_enabled(enabled)


func setConsent(
	analyticsStorage: bool,
	adStorage: bool,
	adUserData: bool,
	adPersonalization: bool
) -> void:
	MobileServices.consent.set_manual_consent(
		analyticsStorage, adStorage, adUserData, adPersonalization
	)


func resetAnalyticsData() -> void:
	MobileServices.analytics.reset_data()


func isReady() -> bool:
	return MobileServices.analytics.is_ready()


func lastError() -> String:
	var error := MobileServices.analytics.get_last_error()
	return "" if error.is_empty() else MSError.describe(error)
