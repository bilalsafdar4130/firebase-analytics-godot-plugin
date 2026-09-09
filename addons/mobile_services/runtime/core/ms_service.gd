class_name MSService
extends Node
## What every service in this SDK has in common: a switch in the config file, a
## native half that may not be there, and one way of saying no.
##
## THE GUARD IS THE INTERESTING PART. Every public method starts with
## [method guard], which answers with either an empty dictionary ("go ahead") or
## a fully-formed failure naming which of the three reasons applies: the SDK has
## not been initialised, this service is off in `mobile_services.cfg`, or the
## native plugin is not in this build. Written once here, it is why no service
## method in this SDK can crash a game that is missing a plugin — and why a
## desktop test run reports "ads are unavailable on Linux" instead of a null
## dereference.

## Set by [MobileServices] before [method setup] runs.
var log: MSLog = null
var config: MSConfig = null
var native: MSNative = null

## The name this service uses in log lines and error `source` fields.
var service_name: String = "service"

## Whether [method setup] has run and the native side reported itself ready.
var _started := false

## The last failure this service produced, for the diagnostics dump.
var _last_error: Dictionary = {}


## Overridden by each service: the config flag that turns it on.
func is_enabled() -> bool:
	return true


## Whether the native half is present. Not the same question as
## [method is_ready]: a plugin can be installed and still have failed to start.
func is_available() -> bool:
	return native != null and native.is_available()


## Whether calls will actually do something.
func is_ready() -> bool:
	return _started and is_enabled() and is_available()


## The last failure, or an empty dictionary if there has not been one.
func get_last_error() -> Dictionary:
	return _last_error.duplicate()


## The single check in front of every public method.
##
## Returns `{}` when the call may proceed, or the failure to hand back to the
## caller. Callers do `var problem := guard("show an ad"); if not
## problem.is_empty(): return problem`, which reads as one line and cannot
## forget a case.
func guard(what: String) -> Dictionary:
	if not is_enabled():
		return MSError.make(
			MSError.SERVICE_DISABLED,
			(
				"cannot %s: %s is switched off in mobile_services.cfg." % [what, service_name]
			),
			service_name
		)
	if not is_available():
		var error := native.unavailable_error(service_name) if native != null \
			else MSError.make(MSError.SERVICE_UNAVAILABLE, "no native plugin", service_name)
		error["message"] = "cannot %s: %s" % [what, error["message"]]
		return error
	return {}


## Records a failure and returns it, so a caller can `return fail(...)` in one
## line and still have it logged and kept for diagnostics.
func fail(
	code: String, message: String, native_code: int = -1
) -> Dictionary:
	var error := MSError.make(code, message, service_name, native_code)
	_last_error = error
	if log != null:
		log.failure(service_name, error)
	return error


## Remembers a failure that arrived from the native side rather than being
## produced here.
func record(error: Dictionary) -> Dictionary:
	_last_error = error
	if log != null:
		log.failure(service_name, error)
	return error


# --- Lifecycle, driven by MobileServices --------------------------------

## Connects native signals and starts the underlying SDK. Overridden by each
## service; the base does nothing so a service with no start-up work can omit
## it.
func setup() -> void:
	_started = true


## Releases native resources and drops signal connections. Must be safe to call
## twice, and safe to call on a service that never started.
func teardown() -> void:
	if native != null:
		native.disconnect_all(self)
	_started = false


# --- The native boundary ------------------------------------------------
#
# EVERYTHING COMPLEX CROSSES AS JSON. Godot's Android and iOS plugin bridges
# marshal a documented handful of types, and the exact set has moved between
# engine versions — a signal declared with a parameter type the running engine
# does not marshal fails at plugin REGISTRATION, which takes the whole plugin
# down rather than one call. So native signals in this SDK carry only strings,
# integers, booleans and floats, and anything structured travels as a JSON
# string decoded here. It costs a parse per event, which is nothing next to the
# network call that produced it, and it cannot fail in a way that hides the
# plugin.

## A JSON object from the native side, or `{}` if it is not one.
func parse_object(text: String) -> Dictionary:
	if text.strip_edges().is_empty():
		return {}
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	log.warn(service_name, "the native plugin sent something that is not a JSON object")
	return {}


## A JSON array from the native side, or `[]` if it is not one.
func parse_array(text: String) -> Array:
	if text.strip_edges().is_empty():
		return []
	var parsed = JSON.parse_string(text)
	if parsed is Array:
		return parsed
	log.warn(service_name, "the native plugin sent something that is not a JSON array")
	return []


## What this service contributes to `MobileServices.get_diagnostics()`.
## Overridden to add detail; must never include an id, key or token.
func diagnostics() -> Dictionary:
	return {
		"enabled": is_enabled(),
		"native_present": is_available(),
		"ready": is_ready(),
		"last_error": MSError.describe(_last_error) if not _last_error.is_empty() else "",
	}
