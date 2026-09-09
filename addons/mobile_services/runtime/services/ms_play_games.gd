class_name MSPlayGames
extends MSService
## Google Play Games Services on Android, Game Center on iOS, behind one API.
##
## THE TWO PLATFORMS ARE NOT THE SAME SHAPE, and this class does not pretend
## otherwise. Play Games v2 signs a player in automatically at launch and has no
## sign-out; Game Center authenticates by presenting a view controller. Play
## Games has incremental achievements and snapshot saves; Game Center has
## achievement percentages and iCloud saves. What is common — sign-in state, a
## player id, achievements, leaderboards, a cloud save slot — is here with the
## same method names on both. What is not is documented in docs/play_games.md
## rather than faked, and [method is_supported] answers per feature.
##
## EVERY GAME USING THIS MUST WORK WITHOUT IT. Players decline sign-in, Play
## Services is missing on some devices, and Game Center is off in Settings for
## plenty of people. Achievements and leaderboards are extras layered on top of
## a game that already works; the SDK never blocks on them.

## Feature names for [method is_supported].
const FEATURE_ACHIEVEMENTS := "achievements"
const FEATURE_LEADERBOARDS := "leaderboards"
const FEATURE_SAVED_GAMES := "saved_games"
const FEATURE_SERVER_ACCESS := "server_access"

signal signed_in(provider_id: String, display_name: String)
signal sign_in_failed(error: Dictionary)
signal achievement_unlocked(achievement_id: String)
signal achievements_loaded(achievements: Array)
signal score_submitted(leaderboard_id: String, score: int)
signal server_access_granted(auth_code: String)
signal game_saved(slot: String)
signal game_loaded(slot: String, data: PackedByteArray)
signal operation_failed(operation: String, error: Dictionary)

## Set by [MobileServices] so a sign-in can update the identity facade.
var player: MSService = null

var _authenticated := false
var _provider_id := ""
var _display_name := ""
var _supported: Array[String] = []


func is_enabled() -> bool:
	if config == null:
		return false
	match MSConfig.current_platform():
		"android":
			return bool(config.player["play_games_enabled"])
		"ios":
			return bool(config.player["game_center_enabled"])
	return false


func setup() -> void:
	if not is_enabled() or not is_available():
		return
	for signal_name in [
		"play_games_signed_in", "play_games_sign_in_failed",
		"play_games_achievement_unlocked", "play_games_achievements_loaded",
		"play_games_score_submitted", "play_games_server_access",
		"play_games_saved", "play_games_loaded", "play_games_failed",
	]:
		native.connect_signal(signal_name, Callable(self, "_on_native_" + signal_name))
	native.call_method("initializePlayGames", [str(config.player["play_games_server_client_id"])])
	# A comma-separated string rather than an array, for the reason in
	# MSService's "The native boundary" note.
	var features := str(native.call_method("getSupportedFeatures", [], ""))
	for feature in features.split(",", false):
		_supported.append(feature.strip_edges())
	_started = true
	# Play Games v2 authenticates on its own at launch. Asking straight away
	# turns that into a signal the game can wait on, and on iOS it is what
	# starts Game Center authentication in the first place.
	sign_in()


## Whether one feature works on this platform and this device.
func is_supported(feature: String) -> bool:
	return _supported.has(feature)


func is_authenticated() -> bool:
	return _authenticated


func get_provider_id() -> String:
	return _provider_id


func get_display_name() -> String:
	return _display_name


## Signs the player in, or confirms they already are.
##
## On Android this is a silent check most of the time — Play Games v2 has
## usually done it before the game's first frame — and shows a prompt only when
## it has not. On iOS it presents Game Center's own authentication controller,
## which the player may dismiss; that is a `USER_CANCELLED`, not an error to
## show them.
func sign_in() -> Dictionary:
	var problem := guard("sign in")
	if not problem.is_empty():
		return problem
	native.call_method("signIn")
	return {}


func unlock_achievement(achievement_id: String) -> Dictionary:
	var problem := guard("unlock an achievement")
	if not problem.is_empty():
		return problem
	if achievement_id.strip_edges().is_empty():
		return fail(MSError.INVALID_ARGUMENT, "an achievement needs an id")
	native.call_method("unlockAchievement", [achievement_id])
	return {}


## Adds steps to an incremental achievement.
##
## Android takes a number of steps to ADD; Game Center takes a percentage
## COMPLETE. The native halves translate, so pass steps here and set the
## achievement's total in the platform console.
func increment_achievement(achievement_id: String, steps: int) -> Dictionary:
	var problem := guard("increment an achievement")
	if not problem.is_empty():
		return problem
	if steps <= 0:
		return fail(MSError.INVALID_ARGUMENT, "steps must be positive")
	native.call_method("incrementAchievement", [achievement_id, steps])
	return {}


## Opens the platform's own achievements UI. There is no way to build this
## screen yourself from the APIs, and no need to.
func show_achievements() -> Dictionary:
	var problem := guard("show achievements")
	if not problem.is_empty():
		return problem
	native.call_method("showAchievements")
	return {}


func submit_score(leaderboard_id: String, score: int) -> Dictionary:
	var problem := guard("submit a score")
	if not problem.is_empty():
		return problem
	if leaderboard_id.strip_edges().is_empty():
		return fail(MSError.INVALID_ARGUMENT, "a leaderboard needs an id")
	native.call_method("submitScore", [leaderboard_id, score])
	return {}


func show_leaderboard(leaderboard_id: String = "") -> Dictionary:
	var problem := guard("show a leaderboard")
	if not problem.is_empty():
		return problem
	native.call_method("showLeaderboard", [leaderboard_id])
	return {}


## Writes a cloud save slot. Play Games calls these snapshots, Game Center uses
## iCloud saved games; both are keyed by a slot name the game chooses.
##
## Not a replacement for a local save. Cloud saves fail off-line, conflict
## between devices, and are unavailable to a player who declined sign-in — save
## locally first and treat this as the copy that survives a new phone.
func save_game(slot: String, data: PackedByteArray, description: String = "") -> Dictionary:
	var problem := guard("save to the cloud")
	if not problem.is_empty():
		return problem
	if not is_supported(FEATURE_SAVED_GAMES):
		return fail(MSError.UNSUPPORTED, "cloud saves are not available on this device")
	if slot.strip_edges().is_empty():
		return fail(MSError.INVALID_ARGUMENT, "a save needs a slot name")
	native.call_method("saveGame", [slot, Marshalls.raw_to_base64(data), description])
	return {}


## Reads a cloud save slot. Arrives on [signal game_loaded]; a slot that has
## never been written reports through [signal operation_failed] rather than
## returning empty data, so "no save yet" and "the save failed to load" are
## different answers.
func load_game(slot: String) -> Dictionary:
	var problem := guard("load from the cloud")
	if not problem.is_empty():
		return problem
	if not is_supported(FEATURE_SAVED_GAMES):
		return fail(MSError.UNSUPPORTED, "cloud saves are not available on this device")
	native.call_method("loadGame", [slot])
	return {}


## See [method MSPlayer.request_server_side_access]. Android only.
func request_server_side_access(force_refresh: bool = false) -> Dictionary:
	var problem := guard("request server-side access")
	if not problem.is_empty():
		return problem
	if not is_supported(FEATURE_SERVER_ACCESS):
		return fail(MSError.UNSUPPORTED, "server-side access is Play Games only")
	if str(config.player["play_games_server_client_id"]).is_empty():
		return fail(
			MSError.INVALID_CONFIGURATION,
			"player/play_games_server_client_id is empty in mobile_services.cfg"
		)
	native.call_method("requestServerSideAccess", [force_refresh])
	return {}


# --- Native callbacks ---------------------------------------------------

func _on_native_play_games_signed_in(provider_id: String, display_name: String) -> void:
	_authenticated = true
	_provider_id = provider_id
	_display_name = display_name
	var provider := MSPlayer.PROVIDER_PLAY_GAMES if MSConfig.current_platform() == "android" \
		else MSPlayer.PROVIDER_GAME_CENTER
	if player != null:
		player.call("adopt_platform_identity", provider, provider_id, display_name)
	signed_in.emit(provider_id, display_name)


func _on_native_play_games_sign_in_failed(code: int, message: String) -> void:
	_authenticated = false
	var error := record(MSError.make(
		MSError.USER_CANCELLED if code == 1 else MSError.INITIALIZATION_FAILED,
		message, service_name, code
	))
	if player != null:
		player.call("report_sign_in_failure", error)
	sign_in_failed.emit(error)


func _on_native_play_games_achievement_unlocked(achievement_id: String) -> void:
	achievement_unlocked.emit(achievement_id)


func _on_native_play_games_achievements_loaded(achievements_json: String) -> void:
	achievements_loaded.emit(parse_array(achievements_json))


func _on_native_play_games_score_submitted(leaderboard_id: String, score: int) -> void:
	score_submitted.emit(leaderboard_id, score)


func _on_native_play_games_server_access(auth_code: String) -> void:
	# Deliberately not logged: this is a credential, however short-lived.
	server_access_granted.emit(auth_code)


func _on_native_play_games_saved(slot: String) -> void:
	game_saved.emit(slot)


func _on_native_play_games_loaded(slot: String, data_base64: String) -> void:
	game_loaded.emit(slot, Marshalls.base64_to_raw(data_base64))


func _on_native_play_games_failed(operation: String, code: int, message: String) -> void:
	var error := record(MSError.make(_translate(code), message, service_name, code))
	operation_failed.emit(operation, error)


static func _translate(code: int) -> String:
	match code:
		1: return MSError.USER_CANCELLED
		2: return MSError.NETWORK_ERROR
		3: return MSError.UNSUPPORTED
		4: return MSError.NOT_READY
	return MSError.UNKNOWN


func diagnostics() -> Dictionary:
	var report := super.diagnostics()
	report["authenticated"] = _authenticated
	report["features"] = _supported
	return report
