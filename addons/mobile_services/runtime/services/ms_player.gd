class_name MSPlayer
extends MSService
## One id for a player, whatever they have or have not signed in to.
##
## THE PROBLEM THIS SOLVES. A game wants a stable id for save files, support
## tickets, analytics and leaderboards. Google Play Games has one, but only
## after a sign-in the player can refuse; Game Center has a different one; a
## fresh install on a PC has neither. Written per-call, a game ends up with
## three code paths and a save file that changes identity the day someone signs
## in.
##
## So there is always an id. It starts as an anonymous installation id — a
## random value made on first launch and kept on the device — and stays valid
## for the life of the install. If the player signs in to Play Games or Game
## Center, [method get_provider] changes and [method get_provider_id] gains the
## platform's own id, but [method get_id] does NOT move: anything already keyed
## to it keeps working.
##
## NOTHING PRIVATE IS COLLECTED. The anonymous id is generated locally and is
## not derived from any hardware identifier. The SDK never asks for an email
## address, an account name or an OAuth token, and there is no method here that
## could return one. A server that needs to trust a sign-in should use
## [method request_server_side_access], which returns a one-time authorisation
## code for the SERVER to exchange with Google — the game never holds a token.

const CACHE_PATH := "user://mobile_services_player.cfg"

## The identity the id currently comes from.
const PROVIDER_ANONYMOUS := "anonymous"
const PROVIDER_PLAY_GAMES := "play_games"
const PROVIDER_GAME_CENTER := "game_center"

signal player_ready(player_id: String, provider: String)
signal signed_in(provider_id: String, display_name: String)
signal sign_in_failed(error: Dictionary)

var _id := ""
var _provider := PROVIDER_ANONYMOUS
var _provider_id := ""
var _display_name := ""
## Set by [MobileServices]; the sign-in half lives in the platform game service.
var play_games: MSService = null


func is_enabled() -> bool:
	return config == null or bool(config.player["enabled"])


func setup() -> void:
	_id = _resolve_installation_id()
	_started = true
	log.info(service_name, "player id ready (%s)" % _provider)
	player_ready.emit(_id, _provider)


## Always available: on desktop the id comes from a local file rather than the
## native side, and the service still works.
func is_available() -> bool:
	return true


## The id to key everything on. Never empty once [method setup] has run, never
## changes for the life of an install, and survives signing in and out.
func get_id() -> String:
	return _id


## Where the player's account identity currently comes from —
## [constant PROVIDER_ANONYMOUS] until they sign in.
func get_provider() -> String:
	return _provider


## The platform's own player id, once signed in. Empty otherwise. This is the
## one to send to a server that will verify it with Google or Apple; it is
## public by design and identifies a player within one game, not a person.
func get_provider_id() -> String:
	return _provider_id


## The player's platform nickname, when the platform gives one and the player
## has signed in. Display only — do not store it and do not send it anywhere.
func get_display_name() -> String:
	return _display_name


func is_authenticated() -> bool:
	return not _provider_id.is_empty()


## Asks the platform game service to sign the player in.
##
## Optional in every game this SDK is meant for: refusing leaves the anonymous
## id in place and everything keeps working. On Android this is Play Games, on
## iOS Game Center, and on anything else it answers SERVICE_UNAVAILABLE.
func sign_in() -> Dictionary:
	if play_games == null:
		return fail(MSError.SERVICE_UNAVAILABLE, "no platform game service in this build")
	return play_games.call("sign_in")


## Forgets the platform identity locally and reverts to the anonymous id.
##
## NOT a platform sign-out: neither Play Games v2 nor Game Center offers one —
## the account belongs to the device, and only the player can sign out of it,
## from the platform's own app. This is the game forgetting, which is the part a
## game is entitled to do.
func sign_out() -> void:
	if _provider == PROVIDER_ANONYMOUS:
		return
	_provider = PROVIDER_ANONYMOUS
	_provider_id = ""
	_display_name = ""
	log.info(service_name, "reverted to the anonymous id")
	player_ready.emit(_id, _provider)


## A one-time authorisation code for a server to exchange with Google for this
## player's identity.
##
## THE ONLY SAFE SHAPE FOR SERVER-SIDE IDENTITY. The game never sees a token and
## never holds a credential; the code is single-use and worthless to anyone who
## intercepts it without the server's own client secret — which stays on the
## server. Needs `player/play_games_server_client_id` in `mobile_services.cfg`
## (the WEB client id from the Google Cloud console, not the Android one).
##
## Android only today. Arrives on [signal MSPlayGames.server_access_granted].
func request_server_side_access(force_refresh: bool = false) -> Dictionary:
	if play_games == null:
		return fail(MSError.SERVICE_UNAVAILABLE, "no platform game service in this build")
	return play_games.call("request_server_side_access", force_refresh)


## Throws away the anonymous id and makes a new one. What a "reset my data"
## button calls, alongside [method MSAnalytics.reset_data].
func reset_id() -> String:
	_id = _new_installation_id()
	_write_cache()
	if is_available() and native != null:
		native.call_method("setInstallationId", [_id])
	log.info(service_name, "installation id reset")
	player_ready.emit(_id, _provider)
	return _id


## Called by the platform game service when a sign-in lands.
func adopt_platform_identity(provider: String, provider_id: String, display_name: String) -> void:
	if provider_id.is_empty():
		return
	_provider = provider
	_provider_id = provider_id
	_display_name = display_name
	log.info(service_name, "signed in with %s" % provider)
	signed_in.emit(provider_id, display_name)
	player_ready.emit(_id, _provider)


func report_sign_in_failure(error: Dictionary) -> void:
	record(error)
	sign_in_failed.emit(error)


# --- The anonymous id ---------------------------------------------------

## Prefers the native side's id, because it survives a `user://` wipe that
## leaves the app installed, and falls back to a local file everywhere else.
func _resolve_installation_id() -> String:
	if native != null and native.is_available():
		var from_native := str(native.call_method("getInstallationId", [], ""))
		if not from_native.is_empty():
			_id = from_native
			_write_cache()
			return from_native
	var file := ConfigFile.new()
	if file.load(CACHE_PATH) == OK:
		var cached := str(file.get_value("player", "installation_id", ""))
		if not cached.is_empty():
			return cached
	var fresh := _new_installation_id()
	_id = fresh
	_write_cache()
	return fresh


func _write_cache() -> void:
	var file := ConfigFile.new()
	file.load(CACHE_PATH)
	file.set_value("player", "installation_id", _id)
	var err := file.save(CACHE_PATH)
	if err != OK:
		log.warn(service_name, "could not write the player id cache (error %d)" % err)


## A random id, from the engine's crypto RNG rather than `randi()`.
##
## Shaped like a UUID so it is recognisable in a log, but it is not derived from
## anything about the device — that is the point. Two installs on one phone get
## two ids, and no install can be traced to hardware.
static func _new_installation_id() -> String:
	var crypto := Crypto.new()
	var bytes := crypto.generate_random_bytes(16)
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4),
		hex.substr(16, 4), hex.substr(20, 12),
	]


func diagnostics() -> Dictionary:
	var report := super.diagnostics()
	report["provider"] = _provider
	report["authenticated"] = is_authenticated()
	# The id itself is in the dump: it is anonymous, and a support conversation
	# that cannot name the player cannot get anywhere.
	report["player_id"] = _id
	return report
