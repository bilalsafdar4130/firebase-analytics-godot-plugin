class_name MSNative
extends RefCounted
## The only place in this SDK that touches an engine singleton.
##
## WHY EVERY NATIVE CALL GOES THROUGH ONE OBJECT. A Godot Android or iOS plugin
## is an `Object` obtained by name at runtime. Calling a method it does not have
## is a script error; connecting a signal it does not declare is another; and
## on desktop, in the editor, and in any build exported without the plugin,
## there is no object at all. Written call-by-call, that is four checks in front
## of every line of the SDK and a crash the first time one is forgotten.
##
## Here it is one class. [method call_method] answers with a caller-supplied
## default instead of failing, [method connect_signal] reports rather than
## throws, and the result is that the whole SDK runs unchanged on a desktop
## machine with no native half — which is where most of a game is actually
## developed.
##
## IT ALSO SURVIVES VERSION SKEW. A game running last release's AAR against
## this release's GDScript hits `has_method` returning false and gets
## `SERVICE_UNAVAILABLE` with the missing method named, rather than a crash on
## the player's device. That is worth the `has_method` call per invocation.

## The singleton name, as registered by the native plugin.
var name: String = ""

var _singleton: Object = null
var _log: MSLog = null

## Methods already found missing, so a call in `_process` reports once rather
## than every frame.
var _missing: Dictionary = {}


func _init(singleton_name: String, log: MSLog = null) -> void:
	name = singleton_name
	_log = log
	if Engine.has_singleton(singleton_name):
		_singleton = Engine.get_singleton(singleton_name)


## Whether the native half is actually here. Everything else in this class is
## safe without checking, but services use it to answer `is_available()`.
func is_available() -> bool:
	return _singleton != null and is_instance_valid(_singleton)


## The raw object, for the rare caller that needs it. Null when absent.
func get_object() -> Object:
	return _singleton if is_available() else null


func has(method: String) -> bool:
	return is_available() and _singleton.has_method(method)


## Calls a native method, or answers `fallback` if it cannot.
##
## Never fails: a missing plugin, a missing method and a plugin that is present
## but has been freed all return `fallback`. The one thing it does not swallow
## is an exception inside the native method itself — the native side catches
## those and reports them through its own error channel, because it is the only
## side that can say anything useful about them.
func call_method(method: String, args: Array = [], fallback: Variant = null) -> Variant:
	if not is_available():
		return fallback
	if not _singleton.has_method(method):
		if not _missing.has(method):
			_missing[method] = true
			if _log != null:
				_log.warn(name, (
					"%s() is missing from the installed native plugin. " % method
					+ "The AAR/framework in this build is older than the GDScript "
					+ "half — rebuild it (see docs/installation.md)."
				))
		return fallback
	return _singleton.callv(method, args)


## Connects one native signal, reporting a name that does not exist rather than
## throwing.
##
## Returns whether the connection was made, which callers use to decide between
## "the plugin drives this" and "poll it instead".
func connect_signal(signal_name: String, target: Callable) -> bool:
	if not is_available():
		return false
	if not _singleton.has_signal(signal_name):
		if _log != null:
			_log.warn(name, (
				"the installed native plugin does not declare the signal %s; "
				% signal_name
				+ "events of this kind will not reach the game."
			))
		return false
	if _singleton.is_connected(signal_name, target):
		return true
	var err := _singleton.connect(signal_name, target)
	if err != OK:
		if _log != null:
			_log.error(name, "could not connect %s (error %d)" % [signal_name, err])
		return false
	return true


## Drops every connection this SDK made to the native object.
##
## Called from `MobileServices.shutdown()`. A native singleton outlives the
## scene tree, so a `Callable` still bound to a freed service node is a real
## leak and, on the next emission, a real crash.
func disconnect_all(target_object: Object) -> void:
	if not is_available() or target_object == null:
		return
	for info in _singleton.get_signal_list():
		var signal_name := str(info.get("name", ""))
		for connection in _singleton.get_signal_connection_list(signal_name):
			var callable: Callable = connection.get("callable", Callable())
			if callable.is_valid() and callable.get_object() == target_object:
				_singleton.disconnect(signal_name, callable)


## The failure a service returns when it has no native half, phrased so the
## message alone explains it.
func unavailable_error(what: String) -> Dictionary:
	if OS.has_feature("editor"):
		return MSError.make(
			MSError.SERVICE_UNAVAILABLE,
			"%s is not available in the editor; export to a device to test it." % what,
			name
		)
	var platform := MSConfig.current_platform()
	if platform.is_empty():
		return MSError.make(
			MSError.SERVICE_UNAVAILABLE,
			"%s is Android/iOS only; this build runs on %s." % [what, OS.get_name()],
			name
		)
	return MSError.make(
		MSError.SERVICE_UNAVAILABLE,
		(
			"the %s native plugin is not in this build. " % name
			+ "Check that the addon is enabled and the plugin binaries are built "
			+ "(addons/mobile_services/tools/build_android.sh)."
		),
		name
	)
