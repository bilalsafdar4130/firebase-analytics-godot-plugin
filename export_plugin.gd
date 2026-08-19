@tool
extends EditorPlugin
## Editor half of the `firebase_analytics` addon: it puts the plugin's AAR and
## the Firebase SDK into an Android export, and turns `google-services.json`
## into the string resources the SDK initialises itself from.
##
## HOW FIREBASE ACTUALLY STARTS, because the design below follows from it.
## `firebase-common` ships a ContentProvider that runs before the app's first
## Activity and calls `FirebaseApp.initializeApp(context)`, which reads its
## configuration out of Android STRING RESOURCES — `google_app_id`,
## `google_api_key` and friends. Normally Google's `com.google.gms.google-services`
## Gradle plugin generates those resources from google-services.json at build
## time. That plugin cannot be added through any Godot export API, so every
## other Godot Firebase integration string-edits the engine's generated
## `build.gradle` to inject it, anchored on lines that change between engine
## versions.
##
## This addon skips that entirely: it generates the same string resources
## itself, into the build template's own `res/` directory (Godot's
## `build.gradle` declares `main.res.srcDirs += ['res']`, so they compile into
## the app like any other resource). No Gradle file is edited, nothing is
## anchored on engine text, and the whole integration is two documented export
## APIs plus one generated XML file.
##
## Everything project-specific is read from the export preset, so this addon can
## be copied into any Godot project unchanged. See README.md.
##
## There is deliberately no `class_name` here: that would register an
## editor-only script in the project's global class list, which an exported game
## then tries to load against a release template that has no `EditorPlugin` in
## it. The work lives in the inner class below, which is also what the headless
## test in tools/verify_firebase_config.gd exercises.

var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_export_plugin = FirebaseAndroidExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null


class FirebaseAndroidExportPlugin extends EditorExportPlugin:

	## Where the generated resources land inside the Gradle build, and the
	## marker identifying them as ours. One file, always rewritten, never merged.
	const RESOURCE_FILE := "res/values/firebase_analytics_bridge.xml"
	const GENERATED_BY := "firebase_analytics addon"

	## The Firebase SDK the APP is built against. PAIRED with the `firebaseBom`
	## the bridge compiles against in android/build.gradle.kts — bump them
	## together, or the plugin compiles against an SDK the app does not carry.
	const FIREBASE_DEPENDENCIES := [
		"platform(com.google.firebase:firebase-bom:33.3.0)",
		"com.google.firebase:firebase-analytics",
	]

	## The built bridge, relative to the project's `addons/` directory — which
	## is what Godot resolves `_get_android_libraries` against.
	const PLUGIN_AAR := "firebase_analytics/bin/release/firebase-analytics-bridge-release.aar"
	const PLUGIN_AAR_DEBUG := "firebase_analytics/bin/debug/firebase-analytics-bridge-debug.aar"

	func _get_name() -> String:
		return "FirebaseAnalyticsBridge"

	## Android only, and only when there is something to configure Firebase
	## WITH. Standing down when google-services.json is absent is what lets a
	## project carry this addon permanently and still produce ordinary builds:
	## no AAR, no SDK, no resources, nothing to explain in a store listing.
	func _supports_platform(platform: EditorExportPlatform) -> bool:
		if not (platform is EditorExportPlatformAndroid):
			return false
		# Godot also asks this OUTSIDE any preset — while the editor starts, and
		# on every headless `--import`. There is no preset to read options from
		# then, so `get_option` answers with a null Variant, and reading one as a
		# value ("Nonexistent 'bool' constructor") turns an ordinary editor
		# launch into script errors. This project's CI fails a run that logs any,
		# and rightly: a plugin cannot be allowed to make a healthy build look
		# broken. No preset means nothing to answer with, and nothing to warn
		# about either.
		var gradle_build = get_option("gradle_build/use_gradle_build")
		if gradle_build == null:
			return false
		if not bool(gradle_build):
			push_warning(
				"[firebase_analytics] Firebase needs the Gradle build "
				+ "(Install Android Build Template); skipping."
			)
			return false
		var build_dir := gradle_build_dir(
			option_string("gradle_build/gradle_build_directory")
		)
		if not FileAccess.file_exists(build_dir.path_join("google-services.json")):
			push_warning(
				"[firebase_analytics] no google-services.json in %s; " % build_dir
				+ "exporting without Firebase."
			)
			return false
		return true

	## The bridge AAR. A missing file would otherwise be a silent
	## no-Firebase build, so it is checked and named here.
	func _get_android_libraries(
		_platform: EditorExportPlatform, debug: bool
	) -> PackedStringArray:
		var relative := PLUGIN_AAR_DEBUG if debug else PLUGIN_AAR
		if not FileAccess.file_exists("res://addons".path_join(relative)):
			push_error(
				"[firebase_analytics] %s has not been built — " % relative
				+ "run addons/firebase_analytics/tools/build_plugin.sh. "
				+ "This build would carry the Firebase SDK but no bridge to it."
			)
			return PackedStringArray()
		return PackedStringArray([relative])

	## The SDK itself, as ordinary Maven coordinates the engine's own Gradle
	## build resolves — including the BOM, which its template handles as a
	## `platform()` entry.
	func _get_android_dependencies(
		_platform: EditorExportPlatform, _debug: bool
	) -> PackedStringArray:
		return PackedStringArray(FIREBASE_DEPENDENCIES)

	## Writes the string resources the SDK initialises from. Runs before Gradle,
	## into a directory Gradle already treats as a resource root.
	func _export_begin(
		features: PackedStringArray, _debug: bool, _path: String, _flags: int
	) -> void:
		if not features.has("android"):
			return
		var build_dir := gradle_build_dir(
			option_string("gradle_build/gradle_build_directory")
		)
		var config_path := build_dir.path_join("google-services.json")
		var config_text := FileAccess.get_file_as_string(config_path)
		if config_text.is_empty():
			push_error("[firebase_analytics] could not read %s" % config_path)
			return
		var parsed = JSON.parse_string(config_text)
		if not (parsed is Dictionary):
			push_error("[firebase_analytics] %s is not valid JSON" % config_path)
			return

		var package_name := option_string("package/unique_name")
		var result := firebase_resources(parsed, package_name)
		if not str(result["error"]).is_empty():
			# Loud, because the alternative is a shipped build that reports to
			# nothing and looks exactly like a game nobody is playing.
			push_error("[firebase_analytics] %s" % result["error"])
			return

		var target := build_dir.path_join(RESOURCE_FILE)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var file := FileAccess.open(target, FileAccess.WRITE)
		if file == null:
			push_error(
				"[firebase_analytics] could not write %s (error %d)"
				% [target, FileAccess.get_open_error()]
			)
			return
		file.store_string(resources_xml(result["values"]))
		file.close()
		print(
			"[firebase_analytics] wrote %d Firebase resources for %s"
			% [int(result["values"].size()), package_name]
		)

	# --- The pure half: google-services.json in, Android resources out --------
	#
	# Static and free of any editor state so it can be tested headlessly without
	# running an export — see tools/verify_firebase_config.gd, which is in CI.
	# The whole integration turns on these values being right, and "wrong
	# Firebase project" is indistinguishable from "no players" once a build has
	# shipped.

	## Pulls the values Firebase initialises from out of a parsed
	## google-services.json.
	##
	## Returns `{"error": String, "values": Dictionary}` — `error` empty on
	## success, a sentence naming what is wrong otherwise. `package_name`
	## selects which client block to read: one google-services.json can describe
	## several apps in a Firebase project, and picking the wrong one produces a
	## build that reports as somebody else's app.
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
					"google-services.json has no client for package %s — "
					% package_name + "it belongs to a different app"
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

		# The two `FirebaseOptions` requires, then the ones it reads when
		# present. The names are Firebase's, not ours: they are exactly what
		# `FirebaseOptions.fromResource` looks up.
		var values := {
			"google_app_id": app_id,
			"google_api_key": api_key,
			# The same key under the name some SDK paths still read, which is
			# also what Google's own generator emits.
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

	## Renders those values as an Android string-resource file.
	##
	## `translatable="false"` on every entry because they are identifiers, not
	## copy: without it the Android toolchain treats a missing translation as
	## something to warn about, and a translator as somebody who might edit an
	## API key.
	static func resources_xml(values: Dictionary) -> String:
		var lines := PackedStringArray([
			'<?xml version="1.0" encoding="utf-8"?>',
			"<!-- Generated by the %s from google-services.json." % GENERATED_BY,
			"     Do not edit: it is rewritten on every Android export, and the",
			"     directory it lives in is regenerated by \"Install Android",
			"     Build Template\". -->",
			"<resources>",
		])
		# Sorted, so a regenerated file is byte-identical when the configuration
		# has not changed — a diff here should mean something.
		var names := values.keys()
		names.sort()
		for name in names:
			lines.append(
				'    <string name="%s" translatable="false">%s</string>'
				% [str(name), escape_xml(str(values[name]))]
			)
		lines.append("</resources>")
		lines.append("")
		return "\n".join(lines)

	static func escape_xml(value: String) -> String:
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
	## preset, and `str(null)` is the string "<null>" — a value that would sail
	## on to be used as a directory name. Both failure modes are silent, so
	## absence is turned into an empty string once, here.
	func option_string(name: String) -> String:
		var value = get_option(name)
		return "" if value == null else str(value)

	## The Gradle build directory an export will use, honouring a project that
	## has moved it off the default.
	static func gradle_build_dir(custom_directory: String) -> String:
		var root := custom_directory.strip_edges()
		if root.is_empty():
			root = "res://android"
		return root.path_join("build")
