@tool
extends EditorExportPlugin
## Puts the right native halves into an Android build, and nothing else.
##
## THREE JOBS, in the order they happen.
##
## 1. DECIDE WHAT SHIPS. `mobile_services.cfg` says which services the game
##    uses; only those modules' AARs and only those Maven dependencies go into
##    the build. An analytics-only game gets no ad SDK, no billing library and
##    no Play Games client — which is a couple of megabytes, a shorter
##    permission list, and one less thing to declare on a Data Safety form.
##
## 2. WRITE THE MANIFEST ENTRIES the SDKs read before any of the game's code
##    runs. AdMob's application id, AppLovin's key, Play Games' project id,
##    Firebase's consent defaults, the billing permission — all of them are read
##    at process start, so none of them can be set from GDScript.
##
## 3. GENERATE FIREBASE'S CONFIGURATION RESOURCES from google-services.json,
##    which is the part every other Godot Firebase integration gets wrong.
##
## ABOUT THAT LAST ONE. `firebase-common` ships a ContentProvider that runs
## before the app's first Activity and calls `FirebaseApp.initializeApp()`,
## which reads its configuration out of Android STRING RESOURCES —
## `google_app_id`, `google_api_key` and friends. Google's
## `com.google.gms.google-services` Gradle plugin normally generates those from
## google-services.json, and that Gradle plugin cannot be added through any
## Godot export API. So the usual approach is to string-edit the engine's
## generated `build.gradle`, anchored on lines that move between engine
## versions. This addon generates the same resources itself, into the build
## template's own `res/` directory — which Godot's `build.gradle` already
## declares as a resource root — and edits no Gradle file at all.

const Editor := preload("res://addons/mobile_services/editor/editor_config.gd")

## Where the generated resources land inside the Gradle build. One file, always
## rewritten, never merged.
const RESOURCE_FILE := "res/values/mobile_services_generated.xml"

## The addon's built AARs, relative to the project's `addons/` directory —
## which is what Godot resolves `_get_android_libraries` against.
const AAR_DIR := "mobile_services/bin/android"

## Android dependency versions, in one place.
##
## PINNED EXPLICITLY RATHER THAN THROUGH THE FIREBASE BOM. Godot's export API
## inserts each of these as `implementation '<coordinate>'`, and a BOM entry is
## not a coordinate — `platform(...)` is Gradle syntax, not something that
## survives being quoted as a dependency string. These are the versions Firebase
## BOM 33.7.0 resolves to; bump them together, and bump the matching
## `compileOnly` versions in `android/build.gradle.kts` at the same time or the
## bridge compiles against an SDK the app does not carry.
const DEPENDENCIES := {
	"firebase_analytics": "com.google.firebase:firebase-analytics:22.1.2",
	"firebase_crashlytics": "com.google.firebase:firebase-crashlytics:19.3.0",
	"firebase_remote_config": "com.google.firebase:firebase-config:22.0.1",
	"admob": "com.google.android.gms:play-services-ads:23.6.0",
	"applovin": "com.applovin:applovin-sdk:13.0.1",
	"billing": "com.android.billingclient:billing-ktx:7.1.1",
	"play_games": "com.google.android.gms:play-services-games-v2:20.1.2",
	"ump": "com.google.android.ump:user-messaging-platform:3.1.0",
}

## Firebase's own privacy switches, written into the manifest.
##
## THESE ARE READ BEFORE THE GAME RUNS, which is the point. Firebase starts
## Analytics from a ContentProvider that fires before the first Activity, so the
## game's first chance to say "not yet" in GDScript is already several automatic
## events late. A manifest default is the only thing that can be in place before
## that. Every one of them is a DENY, and [MSConsent] grants what it may as soon
## as the SDK is up — those runtime calls persist across launches, so these
## defaults decide the first session only, and decide it in the safe direction.
const PRIVACY_META := {
	"google_analytics_default_allow_analytics_storage": "false",
	"google_analytics_default_allow_ad_storage": "false",
	"google_analytics_default_allow_ad_user_data": "false",
	"google_analytics_default_allow_ad_personalization_signals": "false",
}

## Collected by Firebase Analytics by default, and switched off here.
##
## THE AD-ID LINE IS THE LOUD ONE. Firebase Analytics collects the Android
## advertising ID unless told not to, and that single default is what puts
## "Advertising ID" on a Play Data Safety declaration and makes an ad-free game
## look like an ad-supported one. An ad SDK reading that identifier to fill a
## banner is one thing; ANALYTICS also collecting it and joining it to every
## gameplay event is a second, much wider collection that serving a banner does
## not require. So in an ads build the permission comes back — see
## [method _ad_id_permission_xml] — while these two lines do not move.
const IDENTIFIER_META := {
	"google_analytics_adid_collection_enabled": "false",
	"google_analytics_ssaid_collection_enabled": "false",
}

const AD_ID_PERMISSION := "com.google.android.gms.permission.AD_ID"

## The <property> both play-services-ads and play-services-measurement-api
## declare, each pointing at its own xml resource. See `ad_services_config_xml`.
const AD_SERVICES_CONFIG_PROPERTY := "android.adservices.AD_SERVICES_CONFIG"
const AD_SERVICES_CONFIG_RESOURCE := "@xml/gma_ad_services_config"

## The public half of the Firebase configuration, written into the package so
## GDScript can reach it.
##
## Android string resources are invisible to GDScript, so a game that wants to
## call a Firebase REST API — a Realtime Database leaderboard, say — cannot get
## at the project's API key or database URL at all. These particular values are
## PUBLIC by design: a Firebase Web API key identifies a project, it authorises
## nothing on its own, and access is decided by database rules. Generated at
## export time from google-services.json, which is not in the repository, so no
## key is committed and a build made without it simply carries no file. Anything
## reading it must cope with its absence.
const CLIENT_CONFIG_PATH := "res://firebase_client.cfg"

var _client_config_text := ""
var _client_config_added := false
var _modules: PackedStringArray = PackedStringArray()
var _config: MSConfig = null


func _get_name() -> String:
	return "MobileServicesAndroid"


## Loads the configuration if `_export_begin` has not already.
##
## Godot does not document the order it calls these hooks in, and it has moved
## between engine versions. Every getter below therefore stands on its own
## rather than assuming `_export_begin` ran first — the alternative is a build
## that silently ships no modules because a hook fired early.
func _ensure_config(debug: bool) -> void:
	if _config != null:
		return
	_config = Editor.load_for_export(debug)
	_modules = Editor.required_modules(_config)


## Android, and only when the Gradle build is on.
##
## Godot also asks this OUTSIDE any preset — while the editor starts, and on
## every headless `--import`. There is no preset to read options from then, so
## `get_option` answers with a null Variant, and reading one as a value
## ("Nonexistent 'bool' constructor") turns an ordinary editor launch into
## script errors. No preset means nothing to answer with.
func _supports_platform(platform: EditorExportPlatform) -> bool:
	if not (platform is EditorExportPlatformAndroid):
		return false
	var gradle_build = get_option("gradle_build/use_gradle_build")
	if gradle_build == null:
		return false
	if not bool(gradle_build):
		push_warning(
			"[MobileServices] the native plugins need the Gradle build "
			+ "(Project ▸ Install Android Build Template); exporting without them."
		)
		return false
	return true


func _export_begin(
	features: PackedStringArray, debug: bool, _path: String, _flags: int
) -> void:
	_client_config_text = ""
	_client_config_added = false
	if not features.has("android"):
		return
	_config = null
	_ensure_config(debug)

	var blocking := Editor.blocking_problems(_config, "android", debug)
	if not blocking.is_empty():
		# Godot's export API has no way to abort a build, so this is as loud as
		# it gets. Every one of these produces an app that installs and runs and
		# quietly earns nothing, which is the kind of mistake that reaches
		# release.
		push_error("[MobileServices] EXPORT WILL BE BROKEN — %s" % blocking)
	for warning in _config.warnings:
		push_warning("[MobileServices] %s" % warning)

	print("[MobileServices] Android build %s: modules %s" % [
		Editor.VERSION, ", ".join(_modules)
	])
	_write_generated_resources()


func _export_end() -> void:
	_client_config_text = ""
	_client_config_added = false
	_config = null
	_modules = PackedStringArray()


## Puts the client config into the package. `add_file` may only be called from
## `_export_file`, so the first file the exporter offers is the hook — which
## file that is does not matter, only that it happens once.
func _export_file(_path: String, _type: String, _features: PackedStringArray) -> void:
	if _client_config_added or _client_config_text.is_empty():
		return
	_client_config_added = true
	add_file(CLIENT_CONFIG_PATH, _client_config_text.to_utf8_buffer(), false)


# --- What goes into the build -------------------------------------------

## One AAR per enabled module. A missing file would otherwise be a silent
## no-services build, so each one is checked and named.
func _get_android_libraries(
	_platform: EditorExportPlatform, debug: bool
) -> PackedStringArray:
	_ensure_config(debug)
	var variant := "debug" if debug else "release"
	var libraries := PackedStringArray()
	for module in _modules:
		var relative := "%s/%s/mobile-services-%s-%s.aar" % [AAR_DIR, variant, module, variant]
		if not FileAccess.file_exists("res://addons".path_join(relative)):
			push_error(
				"[MobileServices] %s has not been built. " % relative
				+ "Run addons/mobile_services/tools/build_android.sh %s. " % variant
				+ "This build would carry the %s SDK but no bridge to it." % module
			)
			continue
		libraries.append(relative)
	return libraries


## The SDKs themselves, as ordinary Maven coordinates the engine's own Gradle
## build resolves.
func _get_android_dependencies(
	_platform: EditorExportPlatform, debug: bool
) -> PackedStringArray:
	_ensure_config(debug)
	var dependencies := PackedStringArray()
	if _modules.has("firebase"):
		dependencies.append(DEPENDENCIES["firebase_analytics"])
		if bool(_config.analytics["crashlytics_enabled"]):
			dependencies.append(DEPENDENCIES["firebase_crashlytics"])
		if bool(_config.analytics["remote_config_enabled"]):
			dependencies.append(DEPENDENCIES["firebase_remote_config"])
	if _modules.has("ads"):
		match str(_config.ads["provider"]):
			"admob":
				dependencies.append(DEPENDENCIES["admob"])
			"applovin_max":
				# AppLovin MAX mediates AdMob among others, and its own adapters
				# depend on the Google SDK being present. Shipping both is what
				# MAX expects; the per-network ADAPTERS are the game's to add
				# through ads/extra_android_dependencies.
				dependencies.append(DEPENDENCIES["applovin"])
				dependencies.append(DEPENDENCIES["admob"])
	if _modules.has("billing"):
		dependencies.append(DEPENDENCIES["billing"])
	if _modules.has("playgames"):
		dependencies.append(DEPENDENCIES["play_games"])
	if _modules.has("consent"):
		dependencies.append(DEPENDENCIES["ump"])
	for extra in _config.ads["extra_android_dependencies"]:
		var coordinate := str(extra).strip_edges()
		if not coordinate.is_empty():
			dependencies.append(coordinate)
	return dependencies


## Godot inserts what this returns as children of `<manifest>`: permissions.
func _get_android_manifest_element_contents(
	_platform: EditorExportPlatform, debug: bool
) -> String:
	_ensure_config(debug)
	var lines := PackedStringArray()
	lines.append("    <!-- Generated by the mobile_services addon. -->")
	if _modules.has("billing"):
		lines.append('    <uses-permission android:name="com.android.vending.BILLING" />')
	lines.append(_ad_id_permission_xml())
	lines.append("")
	return "\n".join(lines)


## ...and this one as children of `<application>`: everything the SDKs read
## before the game's first frame.
func _get_android_manifest_application_element_contents(
	_platform: EditorExportPlatform, debug: bool
) -> String:
	_ensure_config(debug)
	var lines := PackedStringArray([
		"        <!-- Generated by the mobile_services addon. -->",
	])
	if _modules.has("firebase"):
		var names := PRIVACY_META.keys() + IDENTIFIER_META.keys()
		names.sort()
		var all := PRIVACY_META.duplicate()
		all.merge(IDENTIFIER_META)
		for name in names:
			lines.append(
				'        <meta-data android:name="%s" android:value="%s" />' % [name, all[name]]
			)
	if _modules.has("ads"):
		# AdMob reads this at process start. Its absence is not a warning: the
		# SDK throws, and the app crashes on launch.
		lines.append(
			'        <meta-data android:name="com.google.android.gms.ads.APPLICATION_ID"'
			+ ' android:value="%s" />' % _escape(_config.get_ads_app_id("android"))
		)
		# Delay the first app-open ad request until the game asks. Without it
		# AdMob may fetch during start-up and compete with the engine for the
		# first seconds of a small game's launch.
		lines.append(
			'        <meta-data android:name="com.google.android.gms.ads.flag'
			+ '.OPTIMIZE_INITIALIZATION" android:value="true" />'
		)
		if str(_config.ads["provider"]) == "applovin_max":
			lines.append(
				'        <meta-data android:name="applovin.sdk.key" android:value="%s" />'
				% _escape(str(_config.ads["applovin_sdk_key"]))
			)
	# BOTH GOOGLE SDKs CLAIM THIS PROPERTY, AND ONLY THE APP CAN BREAK THE TIE.
	#
	# `play-services-ads` and `play-services-measurement-api` (which arrives with
	# firebase-analytics) each declare a <property> of this name pointing at a
	# DIFFERENT xml resource. Neither outranks the other, so a build carrying both
	# modules does not merge at all:
	#
	#   Manifest merger failed : Attribute
	#   property#android.adservices.AD_SERVICES_CONFIG@resource
	#   value=(@xml/gma_ad_services_config) from play-services-ads-lite ...
	#   is also present at ...measurement-api value=(@xml/ga_ad_services_config).
	#
	# ONLY when both are in the build. Emitting it with just one would declare a
	# `tools:replace` for an attribute nothing else contributes, and the merger
	# fails that too -- which is why this is not simply always written.
	if _modules.has("ads") and _modules.has("firebase"):
		lines.append(_ad_services_config_xml())
	if _modules.has("playgames"):
		# A string RESOURCE rather than a literal: the value is numeric, and the
		# manifest merger turns a bare number into an integer attribute that
		# Play Games then rejects at runtime with an unhelpful message.
		lines.append(
			'        <meta-data android:name="com.google.android.gms.games.APP_ID"'
			+ ' android:value="@string/ms_play_games_app_id" />'
		)
		lines.append(
			'        <meta-data android:name="com.google.android.gms.version"'
			+ ' android:value="@integer/google_play_services_version" />'
		)
	lines.append("")
	return "\n".join(lines)


## The tie-breaking `<property>` for AD_SERVICES_CONFIG.
##
## `tools:replace` is the manifest merger's own mechanism for an app overriding a
## value two libraries disagree about, and this manifest outranks every AAR in
## the merge. The `tools` namespace is declared by the engine's own manifest
## template.
##
## THE GMA RESOURCE IS THE ONE TO KEEP in a build that serves ads: it is the
## superset, declaring the Privacy Sandbox attribution topics the ads SDK needs,
## and Analytics reads its own configuration through the SDK rather than from
## this property.
static func ad_services_config_xml() -> String:
	return "\n".join(PackedStringArray([
		"        <!-- play-services-ads and firebase-analytics each declare this",
		"             property with a different resource and the merger cannot",
		"             pick. The app breaks the tie, keeping the ads SDK's",
		"             superset. -->",
		'        <property android:name="%s"' % AD_SERVICES_CONFIG_PROPERTY,
		'            android:resource="%s"' % AD_SERVICES_CONFIG_RESOURCE,
		'            tools:replace="android:resource" />',
	]))


func _ad_services_config_xml() -> String:
	return ad_services_config_xml()


## The advertising-ID permission, kept or taken back out.
##
## `firebase-analytics` and the ad SDKs declare it themselves, and
## `tools:node="remove"` is the manifest merger's own mechanism for deleting an
## element a library brought in — this manifest outranks every AAR in the merge.
## An app that does not read the advertising ID must not ASK for it: Play's Data
## Safety form treats a declared AD_ID permission as a declaration that the ID
## is collected, and a mismatch is a policy rejection.
func _ad_id_permission_xml() -> String:
	return ad_id_permission_xml(_modules.has("ads"))


## The same decision, as a pure function of one bool.
##
## SEPARATE FROM THE METHOD ABOVE SO IT CAN BE TESTED. `EditorExportPlugin`
## cannot be instantiated outside the editor -- `ClassDB.can_instantiate()`
## answers false in a game runtime -- so a game's headless compliance check
## cannot construct this plugin to exercise the branches. It would get `null`,
## every assertion against it would error rather than fail, and a check that
## never runs is a check that always passes.
##
## Both branches matter and exactly one is right at a time, so both are reachable
## from a test that needs no editor. See tests/test_ad_id_permission.gd, and
## SparkLogic's tools/verify_compliance.gd, which drives both.
static func ad_id_permission_xml(has_ads: bool) -> String:
	if has_ads:
		return (
			"    <!-- This build serves ads, which read the advertising ID, so the\n"
			+ "         permission the ad SDK declares is left in place. -->"
		)
	return (
		"    <!-- This build reads no advertising ID, so it does not ask for one:\n"
		+ "         a declared AD_ID permission is a Data Safety declaration. -->\n"
		+ '    <uses-permission tools:node="remove" android:name="%s" />' % AD_ID_PERMISSION
	)


# --- Generated resources ------------------------------------------------

## Writes the string resources the SDKs initialise from, into a directory Gradle
## already treats as a resource root.
func _write_generated_resources() -> void:
	var build_dir := gradle_build_dir(option_string("gradle_build/gradle_build_directory"))
	var values := {}

	if _modules.has("playgames"):
		values["ms_play_games_app_id"] = str(_config.player["play_games_app_id"])

	if _modules.has("firebase"):
		var config_path := build_dir.path_join("google-services.json")
		var config_text := FileAccess.get_file_as_string(config_path)
		if config_text.is_empty():
			push_error(
				"[MobileServices] analytics are enabled but there is no "
				+ "google-services.json in %s. " % build_dir
				+ "Firebase cannot start without it and the build will report nothing."
			)
		else:
			var parsed = JSON.parse_string(config_text)
			if not (parsed is Dictionary):
				push_error("[MobileServices] %s is not valid JSON" % config_path)
			else:
				var package_name := option_string("package/unique_name")
				var result := firebase_resources(parsed, package_name)
				if not str(result["error"]).is_empty():
					push_error("[MobileServices] %s" % result["error"])
				else:
					values.merge(result["values"])
					_client_config_text = client_config_text(result["values"])

	var target := build_dir.path_join(RESOURCE_FILE)
	if values.is_empty():
		# Leave nothing behind from a previous export: a stale resource file
		# would keep a removed Firebase project alive in the next build.
		if FileAccess.file_exists(target):
			DirAccess.remove_absolute(target)
		return
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	var file := FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		push_error("[MobileServices] could not write %s (error %d)" % [
			target, FileAccess.get_open_error()
		])
		return
	file.store_string(resources_xml(values))
	file.close()
	print("[MobileServices] wrote %d generated Android resource(s)" % values.size())


# --- The pure half: google-services.json in, Android resources out --------
#
# Static and free of editor state so it can be tested headlessly without running
# an export — see tests/test_firebase_resources.gd. The whole integration turns
# on these values being right, and "wrong Firebase project" is indistinguishable
# from "no players" once a build has shipped.

## Pulls the values Firebase initialises from out of a parsed
## google-services.json.
##
## Returns `{"error": String, "values": Dictionary}` — `error` empty on success,
## a sentence naming what is wrong otherwise. `package_name` selects which client
## block to read: one google-services.json can describe several apps in a
## Firebase project, and picking the wrong one produces a build that reports as
## somebody else's app.
static func firebase_resources(config: Dictionary, package_name: String) -> Dictionary:
	var project_info: Dictionary = config.get("project_info", {})
	if project_info.is_empty():
		return {
			"error": "no project_info block — this is not a google-services.json",
			"values": {},
		}
	var clients: Array = config.get("client", [])
	if clients.is_empty():
		return {"error": "google-services.json lists no client apps", "values": {}}

	var client := {}
	for entry in clients:
		if not (entry is Dictionary):
			continue
		var info: Dictionary = entry.get("client_info", {})
		var android_info: Dictionary = info.get("android_client_info", {})
		if str(android_info.get("package_name", "")) == package_name:
			client = entry
			break
	if client.is_empty():
		return {
			"error": (
				"google-services.json has no client for package %s — " % package_name
				+ "it belongs to a different app"
			),
			"values": {},
		}

	var client_info: Dictionary = client.get("client_info", {})
	var app_id := str(client_info.get("mobilesdk_app_id", ""))
	if app_id.is_empty():
		return {
			"error": "the client for %s has no mobilesdk_app_id" % package_name,
			"values": {},
		}
	var api_key := ""
	for entry in client.get("api_key", []):
		if entry is Dictionary and not str(entry.get("current_key", "")).is_empty():
			api_key = str(entry["current_key"])
			break
	if api_key.is_empty():
		return {
			"error": "the client for %s carries no API key" % package_name,
			"values": {},
		}

	# The two `FirebaseOptions` requires, then the ones it reads when present.
	# The names are Firebase's, not ours: they are exactly what
	# `FirebaseOptions.fromResource` looks up.
	var values := {
		"google_app_id": app_id,
		"google_api_key": api_key,
		# The same key under the name some SDK paths still read, which is also
		# what Google's own generator emits.
		"google_crash_reporting_api_key": api_key,
	}
	var sender_id := str(project_info.get("project_number", ""))
	if not sender_id.is_empty():
		values["gcm_defaultSenderId"] = sender_id
	var project_id := str(project_info.get("project_id", ""))
	if not project_id.is_empty():
		values["project_id"] = project_id
	var bucket := str(project_info.get("storage_bucket", ""))
	if not bucket.is_empty():
		values["google_storage_bucket"] = bucket
	var database := str(project_info.get("firebase_url", ""))
	if not database.is_empty():
		values["firebase_database_url"] = database
	return {"error": "", "values": values}


## Renders values as an Android string-resource file.
##
## `translatable="false"` on every entry because they are identifiers, not copy:
## without it the Android toolchain treats a missing translation as something to
## warn about, and a translator as somebody who might edit an API key.
static func resources_xml(values: Dictionary) -> String:
	var lines := PackedStringArray([
		'<?xml version="1.0" encoding="utf-8"?>',
		"<!-- Generated by the mobile_services addon. Do not edit: it is rewritten",
		'     on every Android export, and the directory it lives in is',
		'     regenerated by "Install Android Build Template". -->',
		"<resources>",
	])
	# Sorted, so a regenerated file is byte-identical when the configuration has
	# not changed — a diff here should mean something.
	var names := values.keys()
	names.sort()
	for name in names:
		lines.append(
			'    <string name="%s" translatable="false">%s</string>'
			% [str(name), _escape(str(values[name]))]
		)
	lines.append("</resources>")
	lines.append("")
	return "\n".join(lines)


## The client config's text, from the same values the Android resources are
## built from.
static func client_config_text(values: Dictionary) -> String:
	var lines := PackedStringArray([
		"; Generated at export time by the mobile_services addon from",
		"; google-services.json. These values identify the Firebase project;",
		"; they authorise nothing on their own - database rules do that.",
		"; Do not commit a copy of this file: it is written into the package,",
		"; never into the repository.",
		"",
		"[firebase]",
	])
	for key in ["google_api_key", "firebase_database_url", "project_id", "google_app_id"]:
		lines.append('%s="%s"' % [key, str(values.get(key, ""))])
	lines.append("")
	return "\n".join(lines)


static func _escape(value: String) -> String:
	return (
		value
		.replace("&", "&amp;")
		.replace("<", "&lt;")
		.replace(">", "&gt;")
		.replace('"', "&quot;")
		.replace("'", "&apos;")
	)


## One export option as a String, empty when there is nothing to read.
##
## `get_option` answers with a null Variant whenever Godot asks outside a
## preset, and `str(null)` is the string "<null>" — a value that would sail on to
## be used as a directory name. Both failure modes are silent, so absence is
## turned into an empty string once, here.
func option_string(name: String) -> String:
	var value = get_option(name)
	return "" if value == null else str(value)


## The Gradle build directory an export will use, honouring a project that has
## moved it off the default.
static func gradle_build_dir(custom_directory: String) -> String:
	var root := custom_directory.strip_edges()
	if root.is_empty():
		root = "res://android"
	return root.path_join("build")
