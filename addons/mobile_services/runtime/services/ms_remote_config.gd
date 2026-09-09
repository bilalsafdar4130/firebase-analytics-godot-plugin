class_name MSRemoteConfig
extends MSService
## Firebase Remote Config: values you can change after a build has shipped.
##
## WHAT IT IS ACTUALLY FOR in a small mobile game — the numbers you will want to
## change without a store review. Interstitial cooldown. Whether a sale banner
## is up. Which of two tutorials new players get. Anything you would otherwise
## have to ship a patch for.
##
## READS ARE ALWAYS SYNCHRONOUS AND ALWAYS ANSWER. [method get_value] never
## waits on the network: it returns the fetched value if there is one, the
## default the game registered if there is not, and the caller's fallback if the
## game never registered one. A first launch with no network gets defaults, and
## nothing in the game has to know the difference.
##
## FETCHING IS THROTTLED BY FIREBASE, hard. In production the minimum interval
## is 12 hours by default and the SDK simply refuses more; while developing, set
## `analytics/remote_config_min_fetch_seconds = 0` in a development overlay so
## every launch fetches. Shipping that setting is the mistake to avoid — see
## docs/troubleshooting.md.

signal fetched(updated: bool)
signal fetch_failed(error: Dictionary)

## Registered by the game before [method fetch]. Also the answer to every read
## that has no fetched value, which is what makes a first launch work.
var _defaults := {}
var _values := {}
var _last_fetch_unix := 0


func is_enabled() -> bool:
	return config != null and bool(config.analytics["enabled"]) \
		and bool(config.analytics["remote_config_enabled"])


func setup() -> void:
	if not is_enabled() or not is_available():
		return
	native.connect_signal("remote_config_fetched", _on_native_fetched)
	native.connect_signal("remote_config_failed", _on_native_failed)
	_started = true


## Registers the values the game expects, with the values to use until a fetch
## lands.
##
## Call this BEFORE [method fetch], once, with every key the game will ever
## read. A key with no default reads as the caller's fallback, which works but
## scatters the game's real defaults across the call sites that happen to read
## them.
func set_defaults(defaults: Dictionary) -> Dictionary:
	_defaults = defaults.duplicate(true)
	var problem := guard("register defaults")
	if not problem.is_empty():
		return problem
	native.call_method("remoteConfigSetDefaults", [JSON.stringify(_defaults)])
	return {}


## Asks Firebase for new values and activates them when they arrive.
##
## `min_interval_seconds` of -1 uses `analytics/remote_config_min_fetch_seconds`
## from the config file. Result arrives on [signal fetched], whose argument says
## whether anything actually changed — a fetch that returns the same values is a
## success with `updated` false, and re-reading everything for nothing is a
## waste worth skipping.
func fetch(min_interval_seconds: int = -1) -> Dictionary:
	var problem := guard("fetch remote config")
	if not problem.is_empty():
		return problem
	var interval := min_interval_seconds
	if interval < 0:
		interval = int(config.analytics["remote_config_min_fetch_seconds"])
	native.call_method("remoteConfigFetch", [interval])
	return {}


## The value for a key: fetched, then default, then `fallback`.
##
## `fallback`'s type decides how the value is read, so `get_value("cooldown",
## 30.0)` gives a float and `get_value("banner_text", "")` a string, whatever
## Remote Config stored it as. That is deliberate: Remote Config's own API has
## `getString`/`getLong`/`getBoolean`/`getDouble` and picking the wrong one is a
## silent zero.
func get_value(key: String, fallback: Variant = null) -> Variant:
	var raw = _values.get(key, _defaults.get(key, fallback))
	if raw == null:
		return fallback
	if fallback == null:
		return raw
	match typeof(fallback):
		TYPE_BOOL:
			if raw is String:
				return str(raw).strip_edges().to_lower() in ["true", "yes", "on", "1"]
			return bool(raw)
		TYPE_INT:
			if raw is String and not str(raw).is_valid_int():
				return fallback
			return int(raw)
		TYPE_FLOAT:
			if raw is String and not str(raw).is_valid_float():
				return fallback
			return float(raw)
		TYPE_STRING:
			return str(raw)
	return raw


## A JSON value, parsed. Remote Config stores strings, so anything structured
## goes through this. Returns `fallback` if the key is missing or the stored
## text does not parse, rather than a half-read dictionary.
func get_json(key: String, fallback: Variant = {}) -> Variant:
	var text := str(get_value(key, ""))
	if text.is_empty():
		return fallback
	var parsed = JSON.parse_string(text)
	if parsed == null:
		log.warn(service_name, "%s does not contain valid JSON" % key)
		return fallback
	return parsed


## Every key currently in effect, defaults included.
func get_all() -> Dictionary:
	var merged := _defaults.duplicate(true)
	merged.merge(_values, true)
	return merged


func has_key(key: String) -> bool:
	return _values.has(key) or _defaults.has(key)


func _on_native_fetched(updated: bool) -> void:
	_last_fetch_unix = int(Time.get_unix_time_from_system())
	_values = parse_object(str(native.call_method("remoteConfigGetAll", [], "")))
	log.info(service_name, "fetched %d value(s)%s" % [
		_values.size(), "" if updated else " (unchanged)"
	])
	fetched.emit(updated)


func _on_native_failed(code: int, message: String) -> void:
	var error := record(MSError.make(
		MSError.THROTTLED if code == 1 else MSError.NETWORK_ERROR,
		message, service_name, code
	))
	fetch_failed.emit(error)


func diagnostics() -> Dictionary:
	var report := super.diagnostics()
	report["defaults"] = _defaults.size()
	report["fetched_keys"] = _values.size()
	report["last_fetch_unix"] = _last_fetch_unix
	return report
