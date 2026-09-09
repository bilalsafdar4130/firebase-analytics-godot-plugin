@tool
class_name MobileServicesEditorConfig
extends RefCounted
## The few things both export plugins need to agree on.
##
## Kept apart from the export plugins themselves so the Android and iOS halves
## cannot drift on where the config lives, which environment a build uses, or
## which native modules a given configuration requires. Getting that last one
## wrong produces a build that ships an ad SDK it never calls, or calls one it
## did not ship.

const SETTING_CONFIG_PATH := "mobile_services/config/path"
const SETTING_ENVIRONMENT := "mobile_services/config/environment"

## The addon's version, stated once. Read by both export plugins for the build
## log and by CI for release tagging. Must match `plugin.cfg` and
## `MobileServices.VERSION`; `tests/test_versions.gd` checks that it does.
const VERSION := "2.0.0"


## The configuration a build will actually run with.
##
## `debug` picks the environment the same way the runtime does, so what the
## export plugin validates is what the game will load.
static func load_for_export(debug: bool) -> MSConfig:
	var path := str(ProjectSettings.get_setting(SETTING_CONFIG_PATH, MSConfig.DEFAULT_PATH))
	var env := str(ProjectSettings.get_setting(SETTING_ENVIRONMENT, "")).strip_edges()
	if env.is_empty():
		env = "development" if debug else "production"
	return MSConfig.load_from(path, env)


## Which native modules a configuration needs.
##
## THE LIST IS THE WHOLE POINT OF THE MULTI-MODULE BUILD. A game with analytics
## and nothing else ships `core` and `firebase`, and its APK contains no ad SDK,
## no billing library and no Play Games client — a couple of megabytes, a shorter
## permission list, and nothing to explain on a Data Safety form.
static func required_modules(config: MSConfig) -> PackedStringArray:
	var modules := PackedStringArray(["core"])
	if bool(config.analytics["enabled"]):
		modules.append("firebase")
	if bool(config.ads["enabled"]) and config.ads["provider"] != "none":
		modules.append("ads")
	if bool(config.iap["enabled"]):
		modules.append("billing")
	if bool(config.player["play_games_enabled"]) or bool(config.player["game_center_enabled"]):
		modules.append("playgames")
	if bool(config.consent["enabled"]):
		modules.append("consent")
	return modules


## Fails the export when the configuration would produce a broken build.
##
## Returns the message to show, or "" when all is well. Every one of these is a
## mistake whose only symptom in a shipped game is missing revenue or missing
## data — which is exactly the kind that survives to release.
static func blocking_problems(config: MSConfig, platform: String, debug: bool) -> String:
	var problems := PackedStringArray()
	for problem in config.errors:
		problems.append(problem)

	if bool(config.ads["enabled"]) and config.ads["provider"] != "none":
		if config.get_ads_app_id(platform).is_empty():
			problems.append(
				"ads/%s_app_id is empty. AdMob's initialiser crashes on start-up " % platform
				+ "without it, and AppLovin cannot mediate AdMob without it either."
			)
	if not debug and bool(config.core["test_mode"]):
		problems.append(
			"core/test_mode is true in a release build. Test ads earn nothing, and "
			+ "serving live ads to a registered test device is grounds for an AdMob "
			+ "suspension. Set it false, or put it in a development overlay."
		)
	if problems.is_empty():
		return ""
	return "\n  - ".join(PackedStringArray(["mobile_services.cfg"]) + problems)
