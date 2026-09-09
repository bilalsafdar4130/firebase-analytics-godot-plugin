class_name MSCrash
extends MSService
## Firebase Crashlytics: the crashes, and the breadcrumbs that explain them.
##
## GDSCRIPT ERRORS ARE NOT CRASHES, which is the thing to understand before
## using this. Crashlytics catches native and JVM crashes automatically — the
## engine segfaulting, an ANR, an uncaught Java exception in a plugin — and
## those need no code here at all. A GDScript error does not crash the process,
## so nothing reports it unless the game does, through [method record_error].
##
## THE BREADCRUMBS MATTER MORE THAN THE STACK. A native crash report from a
## Godot game is a stack full of engine symbols and nothing about the game. What
## makes one actionable is [method log] and [method set_key]: the last scene
## loaded, the level being played, whether an ad was on screen. Leaving a
## breadcrumb at each scene change costs nothing and turns "crashed in
## `Object::call`" into "crashed in `Object::call` while opening the shop with a
## banner up".
##
## NOTHING SENSITIVE GOES IN. Breadcrumbs and custom keys are uploaded to
## Google and readable by anyone with console access. No player names, no
## tokens, no free-text the player typed.

## Crashlytics truncates past this; done here so a long breadcrumb is cut
## predictably rather than in the middle of the interesting part.
const MAX_LOG_CHARS := 1024
const MAX_KEY_VALUE_CHARS := 1024

var _breadcrumbs := 0
var _non_fatals := 0
var _collection_enabled := true


func is_enabled() -> bool:
	return config != null and bool(config.analytics["enabled"]) \
		and bool(config.analytics["crashlytics_enabled"])


func setup() -> void:
	if not is_enabled() or not is_available():
		return
	_started = true
	# Crashlytics keys the report to whoever the game says the player is; the
	# anonymous installation id is exactly the right amount of identity.
	native.call_method("setCrashlyticsCollectionEnabled", [_collection_enabled])


## Leaves a breadcrumb. Cheap — this is a local ring buffer until a crash
## happens, and only then does anything get uploaded.
func log_breadcrumb(message: String) -> Dictionary:
	var problem := guard("leave a breadcrumb")
	if not problem.is_empty():
		return problem
	_breadcrumbs += 1
	native.call_method("crashlyticsLog", [message.substr(0, MAX_LOG_CHARS)])
	return {}


## Attaches a key/value to every report from now on. Use it for the handful of
## facts that would change how you read a crash: level, scene, build flavour,
## whether the player has removed ads.
func set_key(key: String, value: Variant) -> Dictionary:
	var problem := guard("set a crash key")
	if not problem.is_empty():
		return problem
	if key.strip_edges().is_empty():
		return fail(MSError.INVALID_ARGUMENT, "a crash key needs a name")
	native.call_method("crashlyticsSetKey", [key, str(value).substr(0, MAX_KEY_VALUE_CHARS)])
	return {}


## Reports an error the game recovered from — a failed save, a corrupt level
## file, a REST call that gave up.
##
## These appear in Crashlytics as non-fatals, grouped by `name` and `reason`, so
## keep both stable and put the varying part in `context`. `record_error("save",
## "disk full", {"path": "..."})` groups; `record_error("save failed at
## 12:04:11", ...)` makes a new group every time and is useless.
func record_error(
	error_name: String, reason: String, context: Dictionary = {}
) -> Dictionary:
	var problem := guard("record an error")
	if not problem.is_empty():
		return problem
	if error_name.strip_edges().is_empty():
		return fail(MSError.INVALID_ARGUMENT, "a non-fatal needs a name")
	_non_fatals += 1
	native.call_method("crashlyticsRecordError", [
		error_name, reason, JSON.stringify(MSLog.redact(context))
	])
	return {}


## Turns reporting off for a player who has not consented, or on for one who
## has. Persists across launches — the SDK stores it — and takes effect at the
## next launch for crashes that already happened.
func set_collection_enabled(enabled: bool) -> Dictionary:
	_collection_enabled = enabled
	var problem := guard("change crash reporting")
	if not problem.is_empty():
		return problem
	native.call_method("setCrashlyticsCollectionEnabled", [enabled])
	return {}


func is_collection_enabled() -> bool:
	return _collection_enabled


## Crashes the app on purpose, to prove the pipeline works.
##
## There is no other way to know Crashlytics is wired up: it uploads on the
## launch AFTER a crash, so a real crash you did not cause tells you nothing for
## a day. Refuses to run unless `core/test_mode` is on, because a call to this
## left in a shipped build is a game that crashes on every launch.
func force_test_crash() -> Dictionary:
	if not bool(config.core["test_mode"]):
		return fail(
			MSError.INVALID_ARGUMENT,
			"force_test_crash() only works with core/test_mode = true"
		)
	var problem := guard("force a test crash")
	if not problem.is_empty():
		return problem
	log.warn(service_name, "forcing a test crash on purpose")
	native.call_method("crashlyticsTestCrash")
	return {}


func diagnostics() -> Dictionary:
	var report := super.diagnostics()
	report["breadcrumbs"] = _breadcrumbs
	report["non_fatals"] = _non_fatals
	report["collection_enabled"] = _collection_enabled
	return report
