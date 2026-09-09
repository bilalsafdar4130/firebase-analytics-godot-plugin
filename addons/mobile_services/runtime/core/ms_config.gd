class_name MSConfig
extends RefCounted
## Everything a game tells the SDK, read from one file it owns.
##
## THE WHOLE POINT OF THIS CLASS is that the SDK's source is identical in every
## game and only this file differs. There are no ad unit ids, product ids or
## API keys anywhere in `addons/mobile_services/` — they live in
## `res://mobile_services.cfg`, which each game writes for itself. Adding the
## SDK to a fourth game is copying a folder and writing one config file.
##
## ENVIRONMENTS. The base file is overlaid by `mobile_services.<env>.cfg` when
## one exists — key by key, so a development overlay usually just says
## `test_mode = true` and leaves the rest alone. `<env>` comes from the project
## setting `mobile_services/config/environment`, which Godot's own
## feature-override syntax can set per export preset
## (`mobile_services/config/environment.debug = "development"`).
##
## PURE ON PURPOSE. Parsing and validation touch no engine singleton, so
## `tests/test_config.gd` exercises them headlessly and the export plugin can
## validate a project's config before a build rather than after a release.

const DEFAULT_PATH := "res://mobile_services.cfg"

## Ad formats a placement may declare. A placement whose format is not one of
## these is a configuration error rather than a silently ignored line.
const AD_FORMATS := [
	"banner", "interstitial", "rewarded", "rewarded_interstitial", "app_open",
]

## Product types. `subscription` is separate from `non_consumable` because the
## entitlement it grants can expire, and the SDK re-checks it on every launch.
const PRODUCT_TYPES := ["consumable", "non_consumable", "subscription"]

## Ad providers this SDK knows how to drive.
const AD_PROVIDERS := ["none", "admob", "applovin_max"]

const BANNER_POSITIONS := ["top", "bottom"]

const DEBUG_GEOGRAPHIES := ["disabled", "eea", "not_eea"]

# --- Parsed configuration -----------------------------------------------
# Plain dictionaries rather than a class per section: they cross into
# `get_diagnostics()`, into the JSON handed to the native side, and into test
# assertions, and a dictionary is already all three of those.

var environment: String = "production"
var source_paths: PackedStringArray = PackedStringArray()

var core := {
	"log_level": "warn",
	"test_mode": false,
	"auto_initialize": true,
}

var analytics := {
	"enabled": false,
	"crashlytics_enabled": false,
	"remote_config_enabled": false,
	"remote_config_min_fetch_seconds": 3600,
	"auto_ad_events": true,
	"auto_iap_events": true,
	"sync_user_id": true,
}

var ads := {
	"enabled": false,
	"provider": "none",
	"android_app_id": "",
	"ios_app_id": "",
	"applovin_sdk_key": "",
	"test_device_ids": PackedStringArray(),
	"banner_position": "bottom",
	"auto_reload": true,
	"reload_backoff_seconds": PackedFloat32Array([5.0, 15.0, 45.0, 120.0, 300.0]),
	"max_ad_content_rating": "",
	"tag_for_child_directed_treatment": false,
	"tag_for_under_age_of_consent": false,
	"mute_on_start": false,
	# The entitlement whose presence stops the SDK serving ads — normally
	# "remove_ads". Empty means a purchase never affects ad serving, and the game
	# calls MobileServices.ads.set_suppressed() itself.
	"suppress_when_entitled": "",
	# Extra Maven coordinates added to the Android build, for mediation adapters
	# the SDK does not ship itself (AppLovin's AdMob adapter, an IronSource
	# adapter, a network's SDK). Kept here rather than in the addon's Gradle files
	# so adding one to a game does not fork the addon.
	"extra_android_dependencies": PackedStringArray(),
	# The same for iOS: extra CocoaPods lines, as "PodName", "~> 1.2".
	"extra_ios_pods": PackedStringArray(),
}

var iap := {
	"enabled": false,
	"auto_acknowledge": true,
	"auto_consume": true,
	"restore_on_start": true,
}

var player := {
	"enabled": true,
	"play_games_enabled": false,
	"game_center_enabled": false,
	"play_games_server_client_id": "",
	# The numeric Play Games project id from the Play Console. Android needs it in
	# the manifest before Play Games will authenticate at all; the export plugin
	# writes it into a string resource for you.
	"play_games_app_id": "",
}

var consent := {
	"enabled": false,
	"debug_geography": "disabled",
	"under_age_of_consent": false,
	"test_device_hashed_ids": PackedStringArray(),
	"request_on_start": true,
	"att_prompt": true,
	# The sentence Apple shows in the tracking prompt. Apple rejects builds whose
	# text does not say what the data is used for, and rejects the default
	# placeholder outright.
	"att_message": "This lets us show ads that are more relevant to you.",
}

## Logical placement name -> placement dictionary. See [method get_ad_unit].
var placements := {}

## Logical product name -> product dictionary. See [method get_store_id].
var products := {}

## Problems found while parsing, in the order they were found. Empty means the
## file is usable; it does not mean every id in it is correct, only that the
## SDK understood all of them.
var errors: PackedStringArray = PackedStringArray()

## Things that are legal but probably not what was meant — a rewarded
## placement with no unit id on the platform being built, say.
var warnings: PackedStringArray = PackedStringArray()


## Reads the base file plus its environment overlay.
##
## A MISSING FILE IS NOT AN ERROR. It produces a configuration with every
## service switched off, which is exactly right for a project that has added
## the addon but not configured it yet: the game runs, every call answers
## `SERVICE_DISABLED`, and nothing crashes.
static func load_from(base_path: String, env: String) -> MSConfig:
	var config := MSConfig.new()
	config.environment = env
	var overlay_path := _overlay_path(base_path, env)
	for path in [base_path, overlay_path]:
		if path.is_empty() or not FileAccess.file_exists(path):
			continue
		var file := ConfigFile.new()
		var err := file.load(path)
		if err != OK:
			config.errors.append("%s could not be read (error %d)" % [path, err])
			continue
		config.source_paths.append(path)
		config._apply(file)
	config._validate()
	return config


## Builds a configuration straight from a dictionary, for tests and for games
## that would rather configure in code than in a file.
static func from_dictionary(data: Dictionary) -> MSConfig:
	var config := MSConfig.new()
	var file := ConfigFile.new()
	for section in data:
		var values = data[section]
		if not (values is Dictionary):
			continue
		for key in values:
			file.set_value(str(section), str(key), values[key])
	config._apply(file)
	config._validate()
	return config


## `res://mobile_services.cfg` -> `res://mobile_services.development.cfg`.
static func _overlay_path(base_path: String, env: String) -> String:
	if env.is_empty() or base_path.is_empty():
		return ""
	var extension := base_path.get_extension()
	var stem := base_path.substr(0, base_path.length() - extension.length() - 1)
	return "%s.%s.%s" % [stem, env, extension]


## Overlays one loaded file onto whatever is already here.
##
## Only keys the file actually contains are touched, which is what makes an
## environment overlay a two-line file instead of a second copy of everything.
func _apply(file: ConfigFile) -> void:
	_apply_section(file, "core", core)
	_apply_section(file, "analytics", analytics)
	_apply_section(file, "ads", ads)
	_apply_section(file, "iap", iap)
	_apply_section(file, "player", player)
	_apply_section(file, "consent", consent)
	for section in file.get_sections():
		if section.begins_with("ads.placement."):
			_apply_placement(file, section)
		elif section.begins_with("iap.product."):
			_apply_product(file, section)
		elif not section in ["core", "analytics", "ads", "iap", "player", "consent"]:
			warnings.append(
				"[%s] is not a section this SDK reads; it was ignored" % section
			)


## Copies the keys a section defines into `target`, coercing each to the type
## the default already there has.
##
## THE COERCION IS THE POINT. A ConfigFile carries whatever Variant was
## written, so `test_mode = "true"` parses as a String and `if config.test_mode`
## is then true for the string "false" as well. Anchoring every value to the
## default's type turns that whole class of silent misconfiguration into a
## value that behaves, or an error naming the key.
func _apply_section(file: ConfigFile, section: String, target: Dictionary) -> void:
	if not file.has_section(section):
		return
	for key in file.get_section_keys(section):
		if not target.has(key):
			warnings.append(
				"[%s] %s is not a key this SDK reads; it was ignored" % [section, key]
			)
			continue
		target[key] = _coerce(file.get_value(section, key), target[key], "%s/%s" % [section, key])


func _coerce(value: Variant, like: Variant, where: String) -> Variant:
	match typeof(like):
		TYPE_BOOL:
			if value is String:
				var text := str(value).strip_edges().to_lower()
				if text in ["true", "yes", "on", "1"]:
					return true
				if text in ["false", "no", "off", "0"]:
					return false
				errors.append("%s: %s is not a true/false value" % [where, value])
				return like
			return bool(value)
		TYPE_INT:
			if value is bool:
				return 1 if value else 0
			if value is String and not str(value).is_valid_int():
				errors.append("%s: %s is not a whole number" % [where, value])
				return like
			return int(value)
		TYPE_FLOAT:
			if value is String and not str(value).is_valid_float():
				errors.append("%s: %s is not a number" % [where, value])
				return like
			return float(value)
		TYPE_STRING:
			return str(value)
		TYPE_PACKED_STRING_ARRAY:
			var strings := PackedStringArray()
			if value is Array or value is PackedStringArray:
				for item in value:
					strings.append(str(item))
			elif not str(value).strip_edges().is_empty():
				strings.append(str(value))
			return strings
		TYPE_PACKED_FLOAT32_ARRAY:
			var floats := PackedFloat32Array()
			if value is Array or value is PackedFloat32Array:
				for item in value:
					floats.append(float(item))
			return floats
	return value


func _apply_placement(file: ConfigFile, section: String) -> void:
	var name := section.substr("ads.placement.".length())
	if name.is_empty():
		errors.append("[%s] has no placement name after the last dot" % section)
		return
	var placement: Dictionary = placements.get(name, {
		"name": name,
		"format": "",
		"admob_android": "",
		"admob_ios": "",
		"applovin_android": "",
		"applovin_ios": "",
	})
	for key in file.get_section_keys(section):
		if not placement.has(key) or key == "name":
			warnings.append("[%s] %s is not a placement key; it was ignored" % [section, key])
			continue
		placement[key] = str(file.get_value(section, key))
	placements[name] = placement


func _apply_product(file: ConfigFile, section: String) -> void:
	var name := section.substr("iap.product.".length())
	if name.is_empty():
		errors.append("[%s] has no product name after the last dot" % section)
		return
	var product: Dictionary = products.get(name, {
		"name": name,
		"type": "",
		# Defaults to the logical name, because most games use the same string
		# on both stores and repeating it three times invites a typo.
		"android_id": name,
		"ios_id": name,
		# What owning it grants. Empty for consumables, which grant currency
		# through game code rather than an entitlement.
		"entitlement": "",
	})
	for key in file.get_section_keys(section):
		if not product.has(key) or key == "name":
			warnings.append("[%s] %s is not a product key; it was ignored" % [section, key])
			continue
		product[key] = str(file.get_value(section, key))
	products[name] = product


## Checks the values against each other and against what the platforms require.
##
## Runs on load and again from the editor before an export, because every one
## of these is a mistake that produces a build that installs, runs, and quietly
## earns nothing.
func _validate() -> void:
	if not core["log_level"] in MSLog.LEVEL_NAMES.values():
		errors.append("core/log_level: %s is not one of %s" % [
			core["log_level"], ", ".join(MSLog.LEVEL_NAMES.values())
		])
	if not ads["provider"] in AD_PROVIDERS:
		errors.append("ads/provider: %s is not one of %s" % [
			ads["provider"], ", ".join(AD_PROVIDERS)
		])
	if not ads["banner_position"] in BANNER_POSITIONS:
		errors.append("ads/banner_position: %s is not top or bottom" % ads["banner_position"])
	if not consent["debug_geography"] in DEBUG_GEOGRAPHIES:
		errors.append("consent/debug_geography: %s is not one of %s" % [
			consent["debug_geography"], ", ".join(DEBUG_GEOGRAPHIES)
		])

	if bool(ads["enabled"]):
		if ads["provider"] == "none":
			errors.append("ads/enabled is true but ads/provider is none")
		if ads["provider"] == "applovin_max" and str(ads["applovin_sdk_key"]).is_empty():
			errors.append("ads/provider is applovin_max but ads/applovin_sdk_key is empty")
		if placements.is_empty():
			warnings.append("ads are enabled but no [ads.placement.*] section is defined")
	for name in placements:
		var placement: Dictionary = placements[name]
		if not placement["format"] in AD_FORMATS:
			errors.append("ads.placement.%s: format %s is not one of %s" % [
				name, placement["format"], ", ".join(AD_FORMATS)
			])
		if bool(ads["enabled"]):
			for platform in ["android", "ios"]:
				var unit := str(placement.get("%s_%s" % [ads["provider"], platform], ""))
				if unit.is_empty():
					warnings.append("ads.placement.%s has no %s unit id for %s" % [
						name, ads["provider"], platform
					])

	for name in products:
		var product: Dictionary = products[name]
		if not product["type"] in PRODUCT_TYPES:
			errors.append("iap.product.%s: type %s is not one of %s" % [
				name, product["type"], ", ".join(PRODUCT_TYPES)
			])
		if product["type"] == "consumable" and not str(product["entitlement"]).is_empty():
			warnings.append(
				("iap.product.%s is consumable but grants entitlement %s; " % [
					name, product["entitlement"]
				])
				+ "consumables are spent, so the entitlement would come back false "
				+ "after the first launch. Grant currency in game code instead."
			)
	if bool(iap["enabled"]) and products.is_empty():
		warnings.append("iap is enabled but no [iap.product.*] section is defined")

	var suppressor := str(ads["suppress_when_entitled"])
	if not suppressor.is_empty():
		var granted := false
		for name in products:
			if str(products[name]["entitlement"]) == suppressor:
				granted = true
				break
		if not granted:
			errors.append(
				("ads/suppress_when_entitled is %s, but no [iap.product.*] " % suppressor)
				+ "section grants that entitlement — ads would never be suppressed"
			)

	if bool(analytics["crashlytics_enabled"]) and not bool(analytics["enabled"]):
		errors.append("analytics/crashlytics_enabled needs analytics/enabled")
	if bool(analytics["remote_config_enabled"]) and not bool(analytics["enabled"]):
		errors.append("analytics/remote_config_enabled needs analytics/enabled")

	if bool(player["play_games_enabled"]) and str(player["play_games_app_id"]).is_empty():
		errors.append(
			"player/play_games_enabled is true but player/play_games_app_id is empty. "
			+ "Play Games refuses to authenticate without the numeric project id in "
			+ "the manifest, and reports it only in logcat."
		)
	if not str(player["play_games_app_id"]).is_empty() \
			and not str(player["play_games_app_id"]).is_valid_int():
		errors.append(
			"player/play_games_app_id must be the numeric project id (e.g. 123456789012), "
			+ "not the package name or the OAuth client id"
		)

# --- Lookups the services use -------------------------------------------

## The provider's own ad unit id for a logical placement, or "" when this
## placement has no unit on this platform.
##
## `provider` and `platform` default to the configured provider and the running
## platform; both are arguments so the export plugin can ask about the platform
## it is building for rather than the one the editor runs on.
func get_ad_unit(placement_name: String, provider: String = "", platform: String = "") -> String:
	var placement: Dictionary = placements.get(placement_name, {})
	if placement.is_empty():
		return ""
	var use_provider := provider if not provider.is_empty() else str(ads["provider"])
	var use_platform := platform if not platform.is_empty() else current_platform()
	return str(placement.get("%s_%s" % [use_provider, use_platform], ""))


func get_placement(placement_name: String) -> Dictionary:
	return placements.get(placement_name, {})


## Every placement declaring a given format, in declaration order.
func placements_with_format(format: String) -> Array[String]:
	var names: Array[String] = []
	for name in placements:
		if placements[name]["format"] == format:
			names.append(name)
	return names


## The store's own product id for a logical product on a platform.
func get_store_id(product_name: String, platform: String = "") -> String:
	var product: Dictionary = products.get(product_name, {})
	if product.is_empty():
		return ""
	var use_platform := platform if not platform.is_empty() else current_platform()
	return str(product.get("%s_id" % use_platform, ""))


## The logical product name behind a store id — the reverse lookup, needed
## because purchase callbacks arrive carrying the store's id.
func get_product_by_store_id(store_id: String, platform: String = "") -> Dictionary:
	var use_platform := platform if not platform.is_empty() else current_platform()
	for name in products:
		if str(products[name].get("%s_id" % use_platform, "")) == store_id:
			return products[name]
	return {}


func get_product(product_name: String) -> Dictionary:
	return products.get(product_name, {})


## "android", "ios", or "" on any platform with no native half.
static func current_platform() -> String:
	match OS.get_name():
		"Android":
			return "android"
		"iOS":
			return "ios"
		_:
			return ""


## The ad app id for the platform being built — AdMob wants it in the manifest
## and the Info.plist, so the export plugins ask for it by platform.
func get_ads_app_id(platform: String) -> String:
	return str(ads.get("%s_app_id" % platform, ""))


## A short summary for `MobileServices.get_diagnostics()` and for the export
## log. Carries no ids and no keys: it is meant to be pasted into a bug report.
func summary() -> Dictionary:
	return {
		"environment": environment,
		"sources": source_paths,
		"test_mode": core["test_mode"],
		"log_level": core["log_level"],
		"analytics": analytics["enabled"],
		"crashlytics": analytics["crashlytics_enabled"],
		"remote_config": analytics["remote_config_enabled"],
		"ads": ads["enabled"],
		"ad_provider": ads["provider"],
		"placements": placements.size(),
		"iap": iap["enabled"],
		"products": products.size(),
		"play_games": player["play_games_enabled"],
		"game_center": player["game_center_enabled"],
		"consent": consent["enabled"],
		"errors": errors,
		"warnings": warnings,
	}
