class_name MSAds
extends MSService
## Ads, addressed by what they are FOR rather than by which network serves them.
##
## GAME CODE NAMES A PLACEMENT, NEVER A UNIT ID. `show("rewarded_extra_life")`
## works whether the build is on AdMob or AppLovin MAX, and switching between
## them is one line in `mobile_services.cfg`. The ad unit ids live in that file,
## per provider and per platform; nothing in a game's source has ever heard of
## `ca-app-pub-…`. That is what makes this addon reusable across several games
## instead of copied and edited for each.
##
## THE REWARD RULE, which is the one thing here worth being strict about. A
## reward is granted only when the provider reports one, only for the ad that is
## on screen at the time, and only once. Not when the ad opens, not when it
## closes, not on a second reward callback for the same impression. Every
## rewarded-ad bug that costs real money is a variant of granting on the wrong
## signal, so `_current_show` tracks a single impression and
## [signal reward_earned] fires at most once per entry in it.
##
## FAILURES ARE ORDINARY. No fill, no network, a rewarded ad that is not ready
## yet — these happen constantly on real devices and none of them is a reason to
## interrupt a player. Everything reports through signals and return values, and
## a game that ignores all of them still runs.

signal ads_ready(provider: String)
signal ads_failed(error: Dictionary)

signal ad_loaded(placement: String, format: String)
signal ad_load_failed(placement: String, format: String, error: Dictionary)
signal ad_shown(placement: String, format: String)
signal ad_show_failed(placement: String, format: String, error: Dictionary)
signal ad_clicked(placement: String, format: String)
signal ad_closed(placement: String, format: String)

## The only signal that may pay a player. See the reward rule above.
signal reward_earned(placement: String, reward_type: String, amount: int)

## Per-impression revenue, where the provider reports it. Keys: provider,
## network, placement, format, revenue, currency, precision.
signal ad_impression(placement: String, info: Dictionary)

## Formats that are loaded once and shown once.
const ONE_SHOT_FORMATS := ["interstitial", "rewarded", "rewarded_interstitial", "app_open"]

var _provider := "none"
## placement -> {"format", "loaded", "loading", "attempts", "unit"}
var _state := {}
## The impression currently on screen, or {} between ads. Carries `rewarded`,
## which is what stops a second reward callback paying twice.
var _current_show := {}
var _muted := false
## Set by the game (or by an entitlement) to stop serving without unloading.
var _suppressed := false
var _impression_count := 0
var _reward_count := 0


func is_enabled() -> bool:
	return config != null and bool(config.ads["enabled"]) and config.ads["provider"] != "none"


func setup() -> void:
	if not is_enabled():
		return
	if not is_available():
		return
	_provider = str(config.ads["provider"])
	for signal_name in [
		"ads_initialized", "ads_initialization_failed", "ad_loaded",
		"ad_load_failed", "ad_shown", "ad_show_failed", "ad_clicked",
		"ad_closed", "ad_reward_earned", "ad_revenue_paid",
	]:
		native.connect_signal(signal_name, Callable(self, "_on_native_" + signal_name))
	_muted = bool(config.ads["mute_on_start"])
	native.call_method("initializeAds", [_provider, JSON.stringify(_native_config())])


func teardown() -> void:
	if is_available():
		for placement in _state.keys():
			native.call_method("destroyAd", [placement])
	_state.clear()
	_current_show.clear()
	super.teardown()


## What the native half needs that is not per-call: the app id for this
## platform, the AppLovin key, test devices and the privacy flags AdMob wants
## set before its first request.
func _native_config() -> Dictionary:
	var platform := MSConfig.current_platform()
	return {
		"app_id": config.get_ads_app_id(platform),
		"applovin_sdk_key": str(config.ads["applovin_sdk_key"]),
		"test_mode": bool(config.core["test_mode"]),
		"test_device_ids": Array(config.ads["test_device_ids"]),
		"muted": _muted,
		"max_ad_content_rating": str(config.ads["max_ad_content_rating"]),
		"tag_for_child_directed_treatment": bool(config.ads["tag_for_child_directed_treatment"]),
		"tag_for_under_age_of_consent": bool(config.ads["tag_for_under_age_of_consent"]),
	}


# --- Loading and showing ------------------------------------------------

## Asks the provider for an ad, so it is ready when the game wants it.
##
## Interstitials and rewarded ads take seconds to fetch; a game that calls
## [method show] without having loaded first will usually be told `NOT_READY`.
## Load them a screen ahead — at level start for a game-over interstitial, at
## menu time for a rewarded ad.
func load_ad(placement_name: String) -> Dictionary:
	var problem := guard("load %s" % placement_name)
	if not problem.is_empty():
		return problem
	var resolved := _resolve(placement_name)
	if resolved.has("error"):
		return resolved["error"]
	var state: Dictionary = resolved["state"]
	if state["loaded"] or state["loading"]:
		return {}
	state["loading"] = true
	native.call_method("loadAd", [placement_name, state["format"], state["unit"]])
	return {}


## Shows a loaded interstitial, rewarded, rewarded interstitial or app-open ad.
##
## Banners do not go through here — they are shown and hidden rather than
## consumed, so they have [method show_banner].
##
## Returns `{}` when the ad was handed to the provider, or a failure naming why
## not. `{}` does NOT mean a reward was earned: wait for [signal reward_earned].
func show(placement_name: String) -> Dictionary:
	var problem := guard("show %s" % placement_name)
	if not problem.is_empty():
		return problem
	if _suppressed:
		return fail(
			MSError.SERVICE_DISABLED,
			"ads are suppressed for this player (see set_suppressed / remove-ads entitlement)"
		)
	if placement_name.is_empty():
		return fail(
			MSError.INVALID_CONFIGURATION,
			"no placement was named and mobile_services.cfg declares none of this format"
		)
	var resolved := _resolve(placement_name)
	if resolved.has("error"):
		return resolved["error"]
	var state: Dictionary = resolved["state"]
	if state["format"] == "banner":
		return fail(
			MSError.INVALID_ARGUMENT,
			"%s is a banner; use show_banner()" % placement_name
		)
	if not state["loaded"]:
		# Start a load so the NEXT attempt can work. A game that shows on game
		# over and never preloads would otherwise never see an ad at all.
		load_ad(placement_name)
		return fail(
			MSError.NOT_READY,
			"%s is not loaded yet; a load has been started" % placement_name
		)
	if not _current_show.is_empty():
		return fail(MSError.NOT_READY, "another ad is already on screen")
	_current_show = {
		"placement": placement_name,
		"format": state["format"],
		"rewarded": false,
	}
	state["loaded"] = false
	var accepted := bool(native.call_method("showAd", [placement_name], false))
	if not accepted:
		_current_show.clear()
		return fail(MSError.NOT_READY, "the provider refused to show %s" % placement_name)
	return {}


## Shows a banner and leaves it on screen. Idempotent: calling it for a banner
## that is already up just moves it if the position changed.
func show_banner(placement_name: String, position: String = "") -> Dictionary:
	var problem := guard("show banner %s" % placement_name)
	if not problem.is_empty():
		return problem
	if _suppressed:
		return fail(MSError.SERVICE_DISABLED, "ads are suppressed for this player")
	var resolved := _resolve(placement_name)
	if resolved.has("error"):
		return resolved["error"]
	var state: Dictionary = resolved["state"]
	if state["format"] != "banner":
		return fail(
			MSError.INVALID_ARGUMENT,
			"%s is a %s, not a banner" % [placement_name, state["format"]]
		)
	var where := position if not position.is_empty() else str(config.ads["banner_position"])
	if not where in MSConfig.BANNER_POSITIONS:
		return fail(MSError.INVALID_ARGUMENT, "%s is not a banner position" % where)
	native.call_method("showBanner", [placement_name, state["unit"], where])
	return {}


func hide_banner(placement_name: String) -> Dictionary:
	var problem := guard("hide banner %s" % placement_name)
	if not problem.is_empty():
		return problem
	native.call_method("hideBanner", [placement_name])
	return {}


## Releases a placement's native ad object. Banners hold a view and a network
## connection; a game that shows one only in its menu should destroy it on the
## way out rather than hide it forever.
func destroy(placement_name: String) -> Dictionary:
	var problem := guard("destroy %s" % placement_name)
	if not problem.is_empty():
		return problem
	native.call_method("destroyAd", [placement_name])
	if _state.has(placement_name):
		_state[placement_name]["loaded"] = false
		_state[placement_name]["loading"] = false
	return {}


## Whether [method show] would succeed right now.
func is_loaded(placement_name: String) -> bool:
	if not is_ready() or not _state.has(placement_name):
		return false
	return bool(_state[placement_name]["loaded"])


## Loads every placement of a format at once — the usual thing to do once, at
## start-up, so the first interstitial of the session is not the slowest.
func preload_format(format: String) -> void:
	if config == null:
		return
	for name in config.placements_with_format(format):
		load_ad(name)


## Convenience for games with exactly one interstitial or rewarded placement.
## Passing a name is always clearer; these exist so a first integration is
## three lines rather than ten.
func show_interstitial(placement_name: String = "") -> Dictionary:
	return show(_first_of("interstitial", placement_name))


func show_rewarded(placement_name: String = "") -> Dictionary:
	return show(_first_of("rewarded", placement_name))


func show_app_open(placement_name: String = "") -> Dictionary:
	return show(_first_of("app_open", placement_name))


## The placement a convenience helper should act on: the one named, or the
## project's only placement of that format.
##
## Answers "" when a project has none, which `show()` turns into an
## INVALID_CONFIGURATION naming the format — a clearer thing to read than a
## complaint about a placement called "".
func _first_of(format: String, given: String) -> String:
	if not given.is_empty():
		return given
	if config == null:
		return ""
	var names := config.placements_with_format(format)
	if names.is_empty():
		log.warn(service_name, (
			"no [ads.placement.*] section declares format = \"%s\"" % format
		))
		return ""
	return names[0]


# --- Global switches ----------------------------------------------------

## Stops the SDK serving ads without tearing anything down.
##
## THIS IS WHAT A "REMOVE ADS" PURCHASE TURNS ON. The SDK does not touch the
## game's UI: it stops answering [method show] and [method show_banner], and the
## game decides what to draw in the space. Wire it to an entitlement by setting
## `ads/suppress_when_entitled` in `mobile_services.cfg`, or call it directly.
func set_suppressed(suppressed: bool) -> void:
	if _suppressed == suppressed:
		return
	_suppressed = suppressed
	log.info(service_name, "ad serving %s" % ("suppressed" if suppressed else "resumed"))
	if suppressed and is_ready():
		for placement in _state:
			if _state[placement]["format"] == "banner":
				native.call_method("hideBanner", [placement])


func is_suppressed() -> bool:
	return _suppressed


## Mutes ad audio — worth doing when the game itself is muted, because a
## rewarded video at full volume in a silenced game reads as a bug.
func set_muted(muted: bool) -> Dictionary:
	_muted = muted
	var problem := guard("mute ads")
	if not problem.is_empty():
		return problem
	native.call_method("setMuted", [muted])
	return {}


## Passes the current consent decision to the ad SDK. Called by [MSConsent];
## AppLovin needs it explicitly, AdMob reads UMP itself.
func apply_privacy(has_consent: bool, is_under_age: bool, do_not_sell: bool) -> Dictionary:
	var problem := guard("apply ad privacy settings")
	if not problem.is_empty():
		return problem
	native.call_method("setPrivacy", [has_consent, is_under_age, do_not_sell])
	return {}


func get_provider() -> String:
	return _provider


# --- Placement resolution -----------------------------------------------

## Turns a logical placement name into the state entry the rest of this class
## works with, or into the failure explaining why it cannot.
##
## Every "the ad did not show and nothing said why" bug lands here, so each
## branch names the file and key that would fix it.
func _resolve(placement_name: String) -> Dictionary:
	if _state.has(placement_name):
		return {"state": _state[placement_name]}
	var placement := config.get_placement(placement_name)
	if placement.is_empty():
		return {"error": fail(
			MSError.INVALID_CONFIGURATION,
			(
				"there is no [ads.placement.%s] section in mobile_services.cfg"
				% placement_name
			)
		)}
	var unit := config.get_ad_unit(placement_name, _provider, MSConfig.current_platform())
	if unit.is_empty():
		return {"error": fail(
			MSError.INVALID_CONFIGURATION,
			(
				"[ads.placement.%s] has no %s_%s unit id in mobile_services.cfg"
				% [placement_name, _provider, MSConfig.current_platform()]
			)
		)}
	var state := {
		"format": str(placement["format"]),
		"unit": unit,
		"loaded": false,
		"loading": false,
		"attempts": 0,
	}
	_state[placement_name] = state
	return {"state": state}


# --- Native callbacks ---------------------------------------------------
#
# Everything below runs on the Godot thread: the native side marshals onto it
# before emitting. See docs/ads.md, "Threading".

func _on_native_ads_initialized(provider: String) -> void:
	_started = true
	_provider = provider
	log.info(service_name, "%s initialised" % provider)
	native.call_method("setMuted", [_muted])
	ads_ready.emit(provider)
	if bool(config.ads["auto_reload"]):
		for format in ONE_SHOT_FORMATS:
			preload_format(format)


func _on_native_ads_initialization_failed(message: String) -> void:
	_started = false
	var error := record(MSError.make(MSError.INITIALIZATION_FAILED, message, service_name))
	ads_failed.emit(error)


func _on_native_ad_loaded(placement: String, format: String) -> void:
	var state: Dictionary = _state.get(placement, {})
	if not state.is_empty():
		state["loaded"] = true
		state["loading"] = false
		state["attempts"] = 0
	ad_loaded.emit(placement, format)


func _on_native_ad_load_failed(
	placement: String, format: String, code: int, message: String
) -> void:
	var state: Dictionary = _state.get(placement, {})
	if not state.is_empty():
		state["loaded"] = false
		state["loading"] = false
		state["attempts"] = int(state["attempts"]) + 1
	var error := record(MSError.make(
		_translate(code, message), message, "%s/%s" % [_provider, placement], code
	))
	ad_load_failed.emit(placement, format, error)
	_schedule_retry(placement)


func _on_native_ad_shown(placement: String, format: String) -> void:
	_impression_count += 1
	ad_shown.emit(placement, format)


func _on_native_ad_show_failed(
	placement: String, format: String, code: int, message: String
) -> void:
	_current_show.clear()
	var error := record(MSError.make(
		_translate(code, message), message, "%s/%s" % [_provider, placement], code
	))
	ad_show_failed.emit(placement, format, error)
	# A show failure consumes the ad object on both providers, so refill.
	_schedule_retry(placement)


func _on_native_ad_clicked(placement: String, format: String) -> void:
	ad_clicked.emit(placement, format)


func _on_native_ad_closed(placement: String, format: String) -> void:
	_current_show.clear()
	ad_closed.emit(placement, format)
	if bool(config.ads["auto_reload"]) and format in ONE_SHOT_FORMATS:
		load_ad(placement)


## The reward. See the class comment; this is the method the rule is about.
func _on_native_ad_reward_earned(placement: String, reward_type: String, amount: int) -> void:
	# A reward for an impression that is not the one on screen, or a second
	# reward for the one that is, is dropped. Both happen in the wild: AppLovin
	# has delivered duplicate callbacks after a network switch, and a late
	# callback can arrive after the player has already closed the ad and
	# started another.
	if _current_show.is_empty() or _current_show["placement"] != placement:
		log.warn(service_name, (
			"ignored a reward for %s, which is not the ad on screen" % placement
		))
		return
	if bool(_current_show["rewarded"]):
		log.warn(service_name, "ignored a duplicate reward for %s" % placement)
		return
	_current_show["rewarded"] = true
	_reward_count += 1
	log.info(service_name, "reward earned at %s: %d %s" % [placement, amount, reward_type])
	reward_earned.emit(placement, reward_type, amount)


func _on_native_ad_revenue_paid(placement: String, info_json: String) -> void:
	var enriched := parse_object(info_json)
	enriched["placement"] = placement
	enriched["provider"] = _provider
	ad_impression.emit(placement, enriched)


## Retries a failed load, backing off so a device with no network does not spend
## its battery asking every second.
##
## The delays come from `ads/reload_backoff_seconds`; the last one repeats
## forever, which is what you want for a player who is on a train.
func _schedule_retry(placement: String) -> void:
	if not bool(config.ads["auto_reload"]) or not _state.has(placement):
		return
	var backoff: PackedFloat32Array = config.ads["reload_backoff_seconds"]
	if backoff.is_empty():
		return
	var attempts := int(_state[placement]["attempts"])
	var index: int = min(max(attempts - 1, 0), backoff.size() - 1)
	var delay := float(backoff[index])
	log.debug(service_name, "retrying %s in %.0fs (attempt %d)" % [placement, delay, attempts])
	# process_always so a paused game still refills its ad; ignore_time_scale so
	# a slow-motion effect does not stretch the retry to minutes.
	var timer := get_tree().create_timer(delay, true, false, true)
	timer.timeout.connect(_retry.bind(placement), CONNECT_ONE_SHOT)


func _retry(placement: String) -> void:
	if not _state.has(placement) or bool(_state[placement]["loaded"]):
		return
	load_ad(placement)


## Maps a provider's own error number onto this SDK's vocabulary.
##
## Both AdMob and AppLovin use small integers with overlapping meanings, so the
## message is consulted too. Anything unrecognised stays UNKNOWN with the
## original number attached rather than being guessed at.
static func _translate(code: int, message: String) -> String:
	var text := message.to_lower()
	if text.contains("no fill") or text.contains("no ad") or text.contains("no_fill"):
		return MSError.NO_FILL
	if text.contains("network") or text.contains("timeout") or text.contains("offline"):
		return MSError.NETWORK_ERROR
	if text.contains("invalid") and text.contains("unit"):
		return MSError.INVALID_CONFIGURATION
	if text.contains("consent"):
		return MSError.CONSENT_REQUIRED
	# AdMob's own constants: 0 internal, 1 invalid request, 2 network, 3 no fill.
	match code:
		1: return MSError.INVALID_CONFIGURATION
		2: return MSError.NETWORK_ERROR
		3: return MSError.NO_FILL
	return MSError.UNKNOWN


func diagnostics() -> Dictionary:
	var report := super.diagnostics()
	report["provider"] = _provider
	report["suppressed"] = _suppressed
	report["muted"] = _muted
	report["impressions"] = _impression_count
	report["rewards"] = _reward_count
	var loaded: Array[String] = []
	for placement in _state:
		if bool(_state[placement]["loaded"]):
			loaded.append(placement)
	report["placements_configured"] = config.placements.size() if config != null else 0
	report["placements_loaded"] = loaded
	return report
