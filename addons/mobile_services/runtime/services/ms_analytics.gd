class_name MSAnalytics
extends MSService
## Firebase Analytics, with the rules Firebase silently enforces applied here
## instead.
##
## FIREBASE DROPS WHAT IT DOES NOT LIKE, WITHOUT SAYING SO. An event name over
## 40 characters, a name starting with a digit, a reserved `firebase_` prefix,
## a 26th parameter, a string value past 100 characters — each is discarded or
## truncated by the SDK, and the only symptom is a report that is emptier than
## it should be, discovered weeks later. Every one of those is checked here,
## where there is a log to complain to and a developer to read it.
##
## EVENTS SENT BEFORE THE SDK IS READY ARE KEPT. Firebase initialises from a
## ContentProvider that races the game's first scene, and the events around
## first launch are the ones nobody can re-collect. Anything logged before the
## native half answers is queued (up to [constant QUEUE_LIMIT]) and flushed in
## order once it does.

## Firebase's own limits, applied before the SDK sees the event.
const MAX_EVENT_NAME := 40
const MAX_PARAM_NAME := 40
const MAX_PARAM_VALUE := 100
const MAX_PARAMS := 25

## Prefixes Google reserves. An event using one is dropped by the SDK.
const RESERVED_PREFIXES := ["firebase_", "google_", "ga_"]

## How many events to hold while the SDK starts. Twenty is a comfortable
## first-scene's worth; past that something is wrong and the queue itself would
## become the leak.
const QUEUE_LIMIT := 20

signal analytics_ready()
signal analytics_failed(error: Dictionary)
## Emitted after an event actually reaches the SDK, queued ones included.
## Games use it for an on-screen event monitor; nothing in the SDK listens.
signal event_logged(event_name: String, params: Dictionary)

var _queue: Array[Dictionary] = []
var _sent_count := 0
var _dropped_count := 0
var _collection_enabled := true


func is_enabled() -> bool:
	return config != null and bool(config.analytics["enabled"])


func setup() -> void:
	if not is_enabled():
		return
	if not is_available():
		# Not a failure worth reporting: it is what the editor and every
		# desktop run look like. `guard()` explains it per call.
		return
	native.connect_signal("firebase_ready", _on_native_ready)
	native.connect_signal("firebase_failed", _on_native_failed)
	var started := bool(native.call_method("initializeFirebase", [
		true,
		bool(config.analytics["crashlytics_enabled"]),
		bool(config.analytics["remote_config_enabled"]),
	], false))
	# The native side answers synchronously when Firebase was already up (the
	# usual case, since its ContentProvider runs before the first scene) and
	# emits `firebase_ready` when it had to wait. Handle both, once.
	if started:
		_on_native_ready()


func teardown() -> void:
	_queue.clear()
	super.teardown()


# --- Logging ------------------------------------------------------------

## Logs one event.
##
## Returns `{}` on success or a failure dictionary — but the return value is
## for tests and diagnostics screens, not for game code: an analytics call that
## the game has to check is a call that will be written without checking. It is
## safe to ignore, and safe to make from any platform.
func log_event(event_name: String, params: Dictionary = {}) -> Dictionary:
	var clean_name := _clean_event_name(event_name)
	if clean_name.is_empty():
		return fail(
			MSError.INVALID_ARGUMENT,
			"%s is not a usable Firebase event name (see docs/firebase.md)" % event_name
		)
	var clean_params := _clean_params(clean_name, params)

	var problem := guard("log an event")
	if not problem.is_empty():
		# Queue rather than drop while the SDK is still starting; genuinely
		# unavailable platforms are told apart by the code.
		if problem["code"] == MSError.SERVICE_UNAVAILABLE and not _started:
			_enqueue(clean_name, clean_params)
		return problem
	if not _started:
		_enqueue(clean_name, clean_params)
		return {}
	return _send(clean_name, clean_params)


## Sets a user property, which Firebase attaches to every subsequent event and
## uses for audience segmentation.
##
## Not for anything identifying a person: property values are visible in the
## console to everyone with project access, and Firebase's own terms forbid
## putting personal data here. Player skill band, chosen difficulty, whether
## ads are removed — those are the shape of it.
func set_user_property(name: String, value: String) -> Dictionary:
	var problem := guard("set a user property")
	if not problem.is_empty():
		return problem
	if name.strip_edges().is_empty():
		return fail(MSError.INVALID_ARGUMENT, "a user property needs a name")
	native.call_method("setUserProperty", [
		name.substr(0, MAX_PARAM_NAME), value.substr(0, MAX_PARAM_VALUE)
	])
	return {}


## Ties everything reported from now on to one player id.
##
## `MobileServices` calls this itself with the id from [MSPlayer] when
## `analytics/sync_user_id` is on, which is the normal way to use it — a game
## rarely needs to call it directly.
func set_user_id(user_id: String) -> Dictionary:
	var problem := guard("set the user id")
	if not problem.is_empty():
		return problem
	native.call_method("setUserId", [user_id])
	return {}


## Records a screen change. Firebase's own `screen_view` event, which its
## engagement reports are built on.
func log_screen_view(screen_name: String, screen_class: String = "") -> Dictionary:
	var problem := guard("log a screen view")
	if not problem.is_empty():
		return problem
	native.call_method("logScreenView", [
		screen_name.substr(0, MAX_PARAM_VALUE),
		(screen_class if not screen_class.is_empty() else screen_name).substr(0, MAX_PARAM_VALUE),
	])
	return {}


## Turns the SDK's own collection on or off — automatic events included.
##
## The lever [method log_event] cannot pull. `session_start`, `first_open` and
## `app_update` are collected by the SDK itself and never pass through GDScript,
## so a game that stops SENDING events is still a game the SDK reports for. A
## player who said no meant no to those too. The setting persists across
## launches; the SDK stores it.
func set_collection_enabled(enabled: bool) -> Dictionary:
	_collection_enabled = enabled
	var problem := guard("change analytics collection")
	if not problem.is_empty():
		return problem
	native.call_method("setAnalyticsCollectionEnabled", [enabled])
	return {}


func is_collection_enabled() -> bool:
	return _collection_enabled


## Google Consent Mode, one flag per storage type.
##
## Called by [MSConsent] whenever consent changes; a game that runs its own
## consent UI can call it directly. Four booleans rather than a dictionary
## because the names have to survive the JNI boundary and a misspelled key
## would fail silently.
func apply_consent(
	analytics_storage: bool,
	ad_storage: bool,
	ad_user_data: bool,
	ad_personalization: bool
) -> Dictionary:
	var problem := guard("apply consent")
	if not problem.is_empty():
		return problem
	native.call_method("setConsent", [
		analytics_storage, ad_storage, ad_user_data, ad_personalization
	])
	return {}


## Throws away the app instance id, so nothing sent afterwards can be joined to
## anything sent before. This is what a "delete my data" button calls.
func reset_data() -> Dictionary:
	var problem := guard("reset analytics data")
	if not problem.is_empty():
		return problem
	native.call_method("resetAnalyticsData")
	return {}


# --- Helpers for the events most games send -----------------------------
#
# Convenience only. They are ordinary `log_event` calls with names Firebase's
# own reports understand, and nothing in the SDK requires their use — a game
# with its own naming scheme should ignore them entirely.

func log_level_start(level: String, params: Dictionary = {}) -> Dictionary:
	var merged := params.duplicate()
	merged["level_name"] = level
	return log_event("level_start", merged)


func log_level_end(level: String, success: bool, params: Dictionary = {}) -> Dictionary:
	var merged := params.duplicate()
	merged["level_name"] = level
	merged["success"] = 1 if success else 0
	return log_event("level_end", merged)


func log_tutorial_begin(params: Dictionary = {}) -> Dictionary:
	return log_event("tutorial_begin", params)


func log_tutorial_complete(params: Dictionary = {}) -> Dictionary:
	return log_event("tutorial_complete", params)


func log_unlock_achievement(achievement_id: String) -> Dictionary:
	return log_event("unlock_achievement", {"achievement_id": achievement_id})


func log_post_score(score: int, level: String = "") -> Dictionary:
	var params := {"score": score}
	if not level.is_empty():
		params["level"] = level
	return log_event("post_score", params)


## Firebase's `ad_impression`, with the parameter names its ad-revenue reports
## look for. [MSAds] sends this for you when `analytics/auto_ad_events` is on.
func log_ad_impression(info: Dictionary) -> Dictionary:
	return log_event("ad_impression", {
		"ad_platform": str(info.get("provider", "")),
		"ad_source": str(info.get("network", "")),
		"ad_unit_name": str(info.get("placement", "")),
		"ad_format": str(info.get("format", "")),
		"value": float(info.get("revenue", 0.0)),
		"currency": str(info.get("currency", "USD")),
	})


## Firebase's `purchase`, from a completed purchase. [MSIap] sends this for you
## when `analytics/auto_iap_events` is on.
func log_purchase(purchase: Dictionary) -> Dictionary:
	return log_event("purchase", {
		"transaction_id": str(purchase.get("order_id", "")),
		"item_id": str(purchase.get("product", "")),
		"value": float(purchase.get("price", 0.0)),
		"currency": str(purchase.get("currency", "USD")),
		"quantity": int(purchase.get("quantity", 1)),
	})


# --- Internals ----------------------------------------------------------

func _enqueue(event_name: String, params: Dictionary) -> void:
	if _queue.size() >= QUEUE_LIMIT:
		# Drop the OLDEST. The events worth keeping when the SDK is slow to
		# start are the most recent ones, and a queue that refuses new entries
		# quietly stops recording exactly when something interesting is
		# happening.
		_queue.pop_front()
		_dropped_count += 1
	_queue.append({"name": event_name, "params": params})


func _flush() -> void:
	if _queue.is_empty():
		return
	var pending := _queue.duplicate()
	_queue.clear()
	for entry in pending:
		_send(entry["name"], entry["params"])
	log.info(service_name, "flushed %d queued event(s)" % pending.size())


func _send(event_name: String, params: Dictionary) -> Dictionary:
	native.call_method("logEvent", [event_name, params])
	_sent_count += 1
	event_logged.emit(event_name, params)
	return {}


func _on_native_ready() -> void:
	if _started:
		return
	_started = true
	log.info(service_name, "Firebase Analytics ready")
	# The manifest defaults every consent flag to denied so the SDK cannot
	# collect anything before the game has run; re-apply whatever the game has
	# since decided, or collection stays off for this whole session.
	native.call_method("setAnalyticsCollectionEnabled", [_collection_enabled])
	_flush()
	analytics_ready.emit()


func _on_native_failed(message: String) -> void:
	_started = false
	var error := record(MSError.make(
		MSError.INITIALIZATION_FAILED, message, service_name
	))
	analytics_failed.emit(error)


## Firebase's rules, applied. Returns "" for a name it would drop.
##
## Deliberately does NOT rewrite a bad name into a legal one: a silently
## renamed event is a report split across two names, which is worse than a
## missing one because it looks like data.
func _clean_event_name(event_name: String) -> String:
	var name := event_name.strip_edges()
	if name.is_empty() or name.length() > MAX_EVENT_NAME:
		return ""
	if not _is_valid_identifier(name):
		return ""
	var lower := name.to_lower()
	for prefix in RESERVED_PREFIXES:
		if lower.begins_with(prefix):
			return ""
	return name


func _clean_params(event_name: String, params: Dictionary) -> Dictionary:
	var out := {}
	for key in params:
		if out.size() >= MAX_PARAMS:
			log.warn(service_name, (
				"%s carries more than %d parameters; the rest were dropped"
				% [event_name, MAX_PARAMS]
			))
			break
		var name := str(key).strip_edges()
		if name.is_empty() or name.length() > MAX_PARAM_NAME or not _is_valid_identifier(name):
			log.warn(service_name, "%s: %s is not a usable parameter name" % [event_name, key])
			continue
		var value = params[key]
		if value is String:
			var text: String = value
			if text.length() > MAX_PARAM_VALUE:
				log.warn(service_name, (
					"%s/%s was truncated to %d characters"
					% [event_name, name, MAX_PARAM_VALUE]
				))
				text = text.substr(0, MAX_PARAM_VALUE)
			out[name] = text
		elif value is bool:
			# Firebase registers a parameter's type from the first event that
			# carries it, so booleans go over as 1/0 and stay numeric forever.
			out[name] = 1 if value else 0
		elif value is int or value is float:
			out[name] = value
		else:
			out[name] = str(value).substr(0, MAX_PARAM_VALUE)
	return out


static func _is_valid_identifier(name: String) -> bool:
	var first := name[0]
	if not ((first >= "a" and first <= "z") or (first >= "A" and first <= "Z")):
		return false
	for index in name.length():
		var c := name[index]
		var ok := (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") \
			or (c >= "0" and c <= "9") or c == "_"
		if not ok:
			return false
	return true


func diagnostics() -> Dictionary:
	var report := super.diagnostics()
	report["events_sent"] = _sent_count
	report["events_queued"] = _queue.size()
	report["events_dropped"] = _dropped_count
	report["collection_enabled"] = _collection_enabled
	return report
