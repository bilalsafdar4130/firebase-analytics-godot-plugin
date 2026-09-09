extends RefCounted
## `MSConfig` — the file every game writes and nothing else in this SDK does.
##
## The cases here are the ones that produce a build that INSTALLS AND RUNS and is
## nonetheless wrong: a placement with no unit id, a consumable that pretends to
## grant a permanent entitlement, a release build left in test mode. A crash
## would be easier to notice than any of them.


func run() -> Array[MSTestCase]:
	return [
		_defaults_are_all_off(),
		_values_are_coerced_to_their_declared_type(),
		_placements_and_products_are_read(),
		_unknown_keys_warn_rather_than_fail(),
		_validation_catches_the_expensive_mistakes(),
		_lookups_answer_per_platform_and_provider(),
	]


func _defaults_are_all_off() -> MSTestCase:
	var test := MSTestCase.new("an empty config switches everything off")
	var config := MSConfig.from_dictionary({})
	test.check(not bool(config.analytics["enabled"]), "analytics off")
	test.check(not bool(config.ads["enabled"]), "ads off")
	test.check(not bool(config.iap["enabled"]), "iap off")
	test.check(not bool(config.core["test_mode"]), "test mode off")
	test.is_empty_array(config.errors, "no errors from an empty config")
	return test


func _values_are_coerced_to_their_declared_type() -> MSTestCase:
	var test := MSTestCase.new("values are coerced to the type of their default")
	# A ConfigFile carries whatever Variant was written, so `test_mode = "true"`
	# arrives as a String — and `if config.test_mode` would then be true for the
	# string "false" as well.
	var config := MSConfig.from_dictionary({
		"core": {"test_mode": "true"},
		"analytics": {"remote_config_min_fetch_seconds": "900"},
		"ads": {"enabled": "yes", "reload_backoff_seconds": [1, 2, 3]},
	})
	test.equals(config.core["test_mode"], true, "\"true\" becomes true")
	test.equals(config.analytics["remote_config_min_fetch_seconds"], 900, "\"900\" becomes 900")
	test.equals(config.ads["enabled"], true, "\"yes\" becomes true")
	test.equals(config.ads["reload_backoff_seconds"].size(), 3, "an int list becomes floats")
	test.equals(config.ads["reload_backoff_seconds"][1], 2.0, "and each entry is a float")

	var bad := MSConfig.from_dictionary({"core": {"test_mode": "sometimes"}})
	test.contains(bad.errors, "true/false", "an unparseable boolean is an error")
	test.equals(bad.core["test_mode"], false, "and the default is kept")
	return test


func _placements_and_products_are_read() -> MSTestCase:
	var test := MSTestCase.new("placements and products are read from their sections")
	var config := MSConfig.from_dictionary({
		"ads": {"enabled": true, "provider": "admob", "android_app_id": "ca-app-pub-1~1"},
		"ads.placement.rewarded_life": {
			"format": "rewarded",
			"admob_android": "unit-android",
			"admob_ios": "unit-ios",
		},
		"iap": {"enabled": true},
		"iap.product.remove_ads": {
			"type": "non_consumable",
			"entitlement": "remove_ads",
			"android_id": "remove_ads_android",
		},
	})
	test.equals(config.placements.size(), 1, "one placement")
	test.equals(config.get_placement("rewarded_life")["format"], "rewarded", "format read")
	test.equals(config.products.size(), 1, "one product")
	# A product that names no ios_id falls back to its logical name, because most
	# games use the same string on both stores.
	test.equals(config.get_store_id("remove_ads", "ios"), "remove_ads", "ios id defaults to the name")
	test.equals(config.get_store_id("remove_ads", "android"), "remove_ads_android", "android id read")
	var found := config.get_product_by_store_id("remove_ads_android", "android")
	test.equals(found.get("name", ""), "remove_ads", "reverse lookup by store id")
	return test


func _unknown_keys_warn_rather_than_fail() -> MSTestCase:
	var test := MSTestCase.new("an unknown key warns and is ignored")
	# A typo must not stop a game starting — but it must be visible, because the
	# symptom otherwise is a setting that silently does nothing.
	var config := MSConfig.from_dictionary({
		"ads": {"privder": "admob"},
		"nonsense": {"x": 1},
	})
	test.is_empty_array(config.errors, "a typo is not fatal")
	test.contains(config.warnings, "privder", "the misspelled key is named")
	test.contains(config.warnings, "nonsense", "the unknown section is named")
	return test


func _validation_catches_the_expensive_mistakes() -> MSTestCase:
	var test := MSTestCase.new("validation catches the mistakes that cost money")

	var no_provider := MSConfig.from_dictionary({"ads": {"enabled": true, "provider": "none"}})
	test.contains(no_provider.errors, "provider is none", "ads on with no provider")

	var no_key := MSConfig.from_dictionary({
		"ads": {"enabled": true, "provider": "applovin_max", "android_app_id": "x"},
	})
	test.contains(no_key.errors, "applovin_sdk_key", "MAX with no SDK key")

	var bad_format := MSConfig.from_dictionary({
		"ads.placement.p": {"format": "poster"},
	})
	test.contains(bad_format.errors, "poster", "an unknown ad format")

	var crashlytics_alone := MSConfig.from_dictionary({
		"analytics": {"enabled": false, "crashlytics_enabled": true},
	})
	test.contains(crashlytics_alone.errors, "crashlytics_enabled needs", "Crashlytics without analytics")

	# The one that is legal, silent, and wrong: a consumable is spent, so an
	# entitlement it grants is gone by the next launch.
	var spent := MSConfig.from_dictionary({
		"iap.product.coins": {"type": "consumable", "entitlement": "rich"},
	})
	test.contains(spent.warnings, "consumable", "a consumable granting an entitlement warns")

	# Ads suppressed by an entitlement no product grants would never be
	# suppressed at all, and the game would look like it ignores the purchase.
	var orphan := MSConfig.from_dictionary({
		"ads": {"suppress_when_entitled": "remove_ads"},
	})
	test.contains(orphan.errors, "suppress_when_entitled", "suppressor with no product")

	var play_games := MSConfig.from_dictionary({
		"player": {"play_games_enabled": true},
	})
	test.contains(play_games.errors, "play_games_app_id", "Play Games without its project id")

	var not_numeric := MSConfig.from_dictionary({
		"player": {"play_games_enabled": true, "play_games_app_id": "com.example.game"},
	})
	test.contains(not_numeric.errors, "numeric project id", "a package name is not a project id")
	return test


func _lookups_answer_per_platform_and_provider() -> MSTestCase:
	var test := MSTestCase.new("ad unit lookup is per provider and per platform")
	var config := MSConfig.from_dictionary({
		"ads": {"enabled": true, "provider": "admob", "android_app_id": "a", "ios_app_id": "b"},
		"ads.placement.banner": {
			"format": "banner",
			"admob_android": "A", "admob_ios": "B",
			"applovin_android": "C", "applovin_ios": "D",
		},
	})
	test.equals(config.get_ad_unit("banner", "admob", "android"), "A", "admob/android")
	test.equals(config.get_ad_unit("banner", "admob", "ios"), "B", "admob/ios")
	test.equals(config.get_ad_unit("banner", "applovin", "ios"), "D", "applovin/ios")
	test.equals(config.get_ad_unit("nothing", "admob", "ios"), "", "an unknown placement is empty")
	test.equals(config.placements_with_format("banner").size(), 1, "placements by format")
	test.equals(config.get_ads_app_id("ios"), "b", "app id per platform")
	return test
