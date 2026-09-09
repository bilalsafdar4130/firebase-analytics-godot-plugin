extends Node
## The one thing a game talks to. Autoloaded as `MobileServices`.
##
##     func _ready() -> void:
##         MobileServices.initialized.connect(_on_ready)
##         MobileServices.initialize()
##
##     func _on_ready() -> void:
##         MobileServices.analytics.log_event("game_started")
##
## WHAT THIS CLASS ACTUALLY DOES, beyond holding the services: it decides the
## ORDER they start in, and wires the handful of connections between them that
## every game would otherwise write itself.
##
## The order is not arbitrary. Consent comes first because Google requires a
## decision before the ad SDK's first request, and because Firebase's own
## collection defaults to denied in the manifest until something grants it.
## Analytics starts immediately but collects nothing until consent says it may.
## Ads start only once [MSConsent] reports the player may see them — which on a
## device with no network never happens, and the game runs anyway.
##
## The wiring is the boring, forgettable half of every integration:
##
## - the player id becomes the analytics user id (`analytics/sync_user_id`);
## - consent decisions reach Firebase and the ad SDK the moment they change;
## - ad impressions and completed purchases become the Firebase events Google's
##   own revenue reports look for (`analytics/auto_ad_events`,
##   `analytics/auto_iap_events`);
## - a "remove ads" entitlement stops ad serving (`ads/suppress_when_entitled`).
##
## Every one of those is a config switch, and every one can be turned off and
## done by hand.
##
## NOTHING HERE CAN CRASH A GAME. Each service refuses politely when its native
## half is missing, which is what the editor, every desktop run and every build
## exported without the plugins look like. `initialize()` on a PC succeeds, with
## a diagnostics report saying nothing is available.

## Initialisation finished. Some services may have failed; the report says which.
signal initialized(report: Dictionary)
## Initialisation could not be attempted at all — a config file with errors in
## it, essentially. Individual services failing does NOT produce this.
signal initialization_failed(error: Dictionary)
## One service finished starting. `name` is "analytics", "ads", …
signal service_ready(service: String)
signal service_failed(service: String, error: Dictionary)

enum State {
	NOT_INITIALIZED,
	INITIALIZING,
	INITIALIZED,
	FAILED,
}

const VERSION := "2.0.0"

## Where each service's native half lives. Six plugins rather than one, so a
## game that wants analytics and nothing else ships neither the ad SDK nor the
## billing library — see docs/architecture.md.
const SINGLETONS := {
	"core": "MobileServicesCore",
	"firebase": "MobileServicesFirebase",
	"ads": "MobileServicesAds",
	"billing": "MobileServicesBilling",
	"play_games": "MobileServicesPlayGames",
	"consent": "MobileServicesConsent",
}

const SETTING_CONFIG_PATH := "mobile_services/config/path"
const SETTING_ENVIRONMENT := "mobile_services/config/environment"

var log := MSLog.new()
var config: MSConfig = null

var analytics: MSAnalytics = null
var crash: MSCrash = null
var remote_config: MSRemoteConfig = null
var ads: MSAds = null
var iap: MSIap = null
var player: MSPlayer = null
var play_games: MSPlayGames = null
var consent: MSConsent = null

var _state: State = State.NOT_INITIALIZED
var _services: Array[MSService] = []
var _ads_started := false
var _started_at_msec := 0


func _ready() -> void:
	# Services must keep running while the game is paused: an ad closing is
	# exactly the moment a paused game is waiting for.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	if config != null and bool(config.core["auto_initialize"]):
		initialize()


## Starts every enabled service. Safe to call more than once — the second call
## returns immediately rather than starting anything twice.
##
## `overrides` is merged over the config file for this run, which is how a
## test scene switches on `core/test_mode` without editing a file:
## `initialize({"core": {"test_mode": true}})`.
func initialize(overrides: Dictionary = {}) -> void:
	if _state == State.INITIALIZING or _state == State.INITIALIZED:
		log.debug("core", "initialize() called again; already %s" % (
			"running" if _state == State.INITIALIZING else "initialised"
		))
		return
	_state = State.INITIALIZING
	_started_at_msec = Time.get_ticks_msec()
	if not overrides.is_empty():
		_apply_overrides(overrides)

	if not config.errors.is_empty():
		# A config the SDK cannot read is the one failure worth stopping for:
		# every service would start with wrong ids and report to nothing.
		_state = State.FAILED
		var error := MSError.make(
			MSError.INVALID_CONFIGURATION,
			"mobile_services.cfg has %d problem(s): %s" % [
				config.errors.size(), "; ".join(config.errors)
			],
			"core"
		)
		log.failure("core", error)
		initialization_failed.emit(error)
		return

	for warning in config.warnings:
		log.warn("config", warning)

	log.info("core", "Mobile Services %s starting (%s, %s)" % [
		VERSION, config.environment, OS.get_name()
	])
	if bool(config.core["test_mode"]):
		log.warn("core", (
			"TEST MODE is on: ads are test ads and no revenue is earned. "
			+ "Set core/test_mode = false before a release build."
		))

	# Identity first: everything else may want to tag itself with the player id.
	player.setup()

	consent.setup()
	analytics.setup()
	crash.setup()
	remote_config.setup()

	# ...but the id reaches analytics only AFTER analytics has started. `player`
	# emits `player_ready` at the end of its own setup, which is several lines
	# above this one, so connecting the signal alone would miss the first — and
	# the first is the one that matters, because for most players there is never
	# a second. So: connect for later changes (a sign-in, a reset), then apply
	# what is already known, once.
	if bool(config.analytics["sync_user_id"]):
		player.player_ready.connect(_on_player_ready)
		_on_player_ready(player.get_id(), player.get_provider())

	iap.setup()
	if bool(config.analytics["auto_iap_events"]):
		iap.purchase_completed.connect(_on_purchase_completed)
		iap.purchase_failed.connect(_on_purchase_failed)
	play_games.setup()

	# Ads wait for consent. `_maybe_start_ads` runs now (for the common case
	# where consent is not required, or was decided on a previous launch) and
	# again whenever the decision changes.
	consent.consent_updated.connect(_on_consent_updated)
	consent.consent_flags_changed.connect(_on_consent_flags_changed)
	_apply_consent_flags(consent.get_flags())
	_maybe_start_ads()

	for service in _services:
		_announce(service)

	_state = State.INITIALIZED
	var report := get_diagnostics()
	log.info("core", "ready in %d ms" % (Time.get_ticks_msec() - _started_at_msec))
	initialized.emit(report)


## Reports one service's outcome, once.
##
## A service that is switched off says nothing at all: a game with no ads did not
## fail to start ads, and a `service_failed("ads", SERVICE_DISABLED)` on every
## launch would train whoever reads the log to ignore the signal.
func _announce(service: MSService) -> void:
	if not service.is_enabled():
		return
	if service.is_ready():
		service_ready.emit(service.service_name)
		return
	var error := service.get_last_error()
	if error.is_empty():
		error = service.guard("start")
	if not error.is_empty() and not MSError.is_benign(str(error.get("code", ""))):
		service_failed.emit(service.service_name, error)


func is_initialized() -> bool:
	return _state == State.INITIALIZED


func get_state() -> State:
	return _state


## Stops every service and releases native resources.
##
## Rarely needed — the OS tears the process down anyway — but a game that
## returns to a "sign out and wipe" screen wants it, and the test suite needs
## it to run twice in one process.
func shutdown() -> void:
	if _state == State.NOT_INITIALIZED:
		return
	for service in _services:
		service.teardown()
	_ads_started = false
	_state = State.NOT_INITIALIZED
	log.info("core", "shut down")


## Everything the SDK knows about itself, in one dictionary.
##
## Made to be shown on a debug screen and pasted into a bug report: it names
## versions, says which native halves are present, which services started and
## what the last failure of each was. Carries no ad unit id, no product id, no
## API key and no purchase token — [method MSLog.redact] and each service's own
## `diagnostics()` see to that.
func get_diagnostics() -> Dictionary:
	var natives := {}
	for key in SINGLETONS:
		natives[key] = Engine.has_singleton(SINGLETONS[key])
	var report := {
		"sdk_version": VERSION,
		"godot_version": Engine.get_version_info()["string"],
		"platform": OS.get_name(),
		"os_version": OS.get_version(),
		"model": OS.get_model_name(),
		"debug_build": OS.is_debug_build(),
		"state": State.keys()[_state],
		"native_plugins": natives,
		"config": config.summary() if config != null else {},
		"services": {},
		"recent_log": log.get_tail(),
	}
	for service in _services:
		report["services"][service.service_name] = service.diagnostics()
	return report


## The diagnostics report as text, for a label on a debug screen.
func get_diagnostics_text() -> String:
	return JSON.stringify(get_diagnostics(), "  ")


# --- Construction -------------------------------------------------------

func _build() -> void:
	_register_settings()
	var path := str(ProjectSettings.get_setting(SETTING_CONFIG_PATH, MSConfig.DEFAULT_PATH))
	config = MSConfig.load_from(path, _resolve_environment())
	log.set_level_name(str(config.core["log_level"]))
	if config.source_paths.is_empty():
		log.warn("config", (
			"no configuration found at %s. " % path
			+ "Every service is switched off; copy the template from "
			+ "addons/mobile_services/mobile_services.cfg.template."
		))

	analytics = _add(MSAnalytics.new(), "analytics", "firebase")
	crash = _add(MSCrash.new(), "crash", "firebase")
	remote_config = _add(MSRemoteConfig.new(), "remote_config", "firebase")
	ads = _add(MSAds.new(), "ads", "ads")
	iap = _add(MSIap.new(), "iap", "billing")
	player = _add(MSPlayer.new(), "player", "core")
	play_games = _add(MSPlayGames.new(), "play_games", "play_games")
	consent = _add(MSConsent.new(), "consent", "consent")

	player.play_games = play_games
	play_games.player = player


## Names a service, hands it its dependencies and puts it in the tree.
##
## `service_name` is set HERE rather than left to each `setup()`, because
## `get_diagnostics()` keys its report by it and a service that failed before
## `setup()` ran would otherwise report itself as "service" — several of them
## colliding on one key.
func _add(service: MSService, name_: String, singleton_key: String) -> MSService:
	service.log = log
	service.config = config
	service.native = MSNative.new(SINGLETONS[singleton_key], log)
	service.service_name = name_
	service.name = name_
	add_child(service)
	_services.append(service)
	return service


## Registers the two project settings the SDK reads, so they appear in Project
## Settings with a sensible default rather than only in documentation.
func _register_settings() -> void:
	if not ProjectSettings.has_setting(SETTING_CONFIG_PATH):
		ProjectSettings.set_setting(SETTING_CONFIG_PATH, MSConfig.DEFAULT_PATH)
	ProjectSettings.set_initial_value(SETTING_CONFIG_PATH, MSConfig.DEFAULT_PATH)
	ProjectSettings.add_property_info({
		"name": SETTING_CONFIG_PATH,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_FILE,
		"hint_string": "*.cfg",
	})
	if not ProjectSettings.has_setting(SETTING_ENVIRONMENT):
		ProjectSettings.set_setting(SETTING_ENVIRONMENT, "")
	ProjectSettings.set_initial_value(SETTING_ENVIRONMENT, "")


## Which environment overlay to load.
##
## `--ms-env=<name>` on the command line wins, for a CI run that wants to test
## a production config from a debug build. Otherwise the project setting, which
## Godot's own feature-override syntax can vary per export preset
## (`mobile_services/config/environment.debug`). With neither, a debug build is
## "development" and a release build "production", which is what a project that
## never thinks about this wants.
func _resolve_environment() -> String:
	for argument in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if argument.begins_with("--ms-env="):
			return argument.substr("--ms-env=".length())
	var setting := str(ProjectSettings.get_setting(SETTING_ENVIRONMENT, ""))
	if not setting.strip_edges().is_empty():
		return setting.strip_edges()
	return "development" if OS.is_debug_build() else "production"


func _apply_overrides(overrides: Dictionary) -> void:
	for section in overrides:
		var target = config.get(str(section))
		if not (target is Dictionary):
			log.warn("config", "%s is not a configuration section" % section)
			continue
		for key in overrides[section]:
			if not target.has(key):
				log.warn("config", "%s/%s is not a configuration key" % [section, key])
				continue
			target[key] = overrides[section][key]
	log.set_level_name(str(config.core["log_level"]))


# --- The wiring between services ----------------------------------------

func _on_player_ready(player_id: String, _provider: String) -> void:
	analytics.set_user_id(player_id)
	crash.set_key("player_id", player_id)


func _on_consent_updated(_status: int, _can_request_ads: bool) -> void:
	_maybe_start_ads()


func _on_consent_flags_changed(flags: Dictionary) -> void:
	_apply_consent_flags(flags)


## Passes a consent decision to everything that needs one.
##
## Firebase gets all four Consent Mode flags and a collection switch; the ad
## SDK gets the two booleans AppLovin asks for. Both calls are safe when the
## service is off or absent.
func _apply_consent_flags(flags: Dictionary) -> void:
	var analytics_storage := bool(flags.get("analytics_storage", false))
	analytics.apply_consent(
		analytics_storage,
		bool(flags.get("ad_storage", false)),
		bool(flags.get("ad_user_data", false)),
		bool(flags.get("ad_personalization", false))
	)
	analytics.set_collection_enabled(analytics_storage)
	crash.set_collection_enabled(analytics_storage)
	if _ads_started:
		ads.apply_privacy(
			bool(flags.get("ad_storage", false)),
			bool(config.consent["under_age_of_consent"]),
			not bool(flags.get("ad_personalization", false))
		)


## Starts the ad service the first time the player may see ads.
##
## Called on every consent change and once at the end of initialisation. A
## player who declines, or a device that never reaches Google's consent servers,
## simply never gets here — and the game runs without ads rather than not
## running.
func _maybe_start_ads() -> void:
	if _ads_started or not ads.is_enabled():
		return
	if not consent.can_request_ads():
		log.info("core", "ads are waiting on a consent decision")
		return
	_ads_started = true
	ads.setup()
	_apply_consent_flags(consent.get_flags())
	_connect_ad_wiring()
	# Ads start after everything else, so the loop at the end of initialize() has
	# usually already run by the time they do.
	if _state == State.INITIALIZED:
		_announce(ads)


func _connect_ad_wiring() -> void:
	if bool(config.analytics["auto_ad_events"]):
		ads.ad_impression.connect(_on_ad_impression)
		ads.reward_earned.connect(_on_reward_earned)
	var suppressor := str(config.ads["suppress_when_entitled"])
	if not suppressor.is_empty():
		iap.entitlements_changed.connect(_on_entitlements_changed)
		ads.set_suppressed(iap.has_entitlement(suppressor))


func _on_ad_impression(_placement: String, info: Dictionary) -> void:
	analytics.log_ad_impression(info)


func _on_reward_earned(placement: String, reward_type: String, amount: int) -> void:
	analytics.log_event("rewarded_ad_completed", {
		"placement": placement,
		"reward_type": reward_type,
		"reward_amount": amount,
	})


func _on_entitlements_changed(entitlements: Array) -> void:
	var suppressor := str(config.ads["suppress_when_entitled"])
	ads.set_suppressed(entitlements.has(suppressor))


func _on_purchase_completed(purchase: Dictionary) -> void:
	analytics.log_purchase(purchase)


func _on_purchase_failed(product: String, error: Dictionary) -> void:
	analytics.log_event("purchase_failed", {
		"item_id": product,
		"error_code": str(error.get("code", MSError.UNKNOWN)),
	})
