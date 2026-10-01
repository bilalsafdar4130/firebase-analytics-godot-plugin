extends RefCounted
## How the native bridge decides whether a plugin has a method.
##
## WHY THIS IS TESTED. It is the one line every native call in the SDK passes
## through, and it was wrong for every Android build ever shipped: it asked
## `Object.has_method`, which cannot see the methods of a `JNISingleton`, so
## Firebase, AdMob, Play Billing and UMP were all told "missing" and every call
## was dropped. Nothing in CI could see it -- the AAB was complete and the
## desktop runs have no plugin at all. These doubles are shaped the way each
## engine platform actually hands a plugin over.


## An Android plugin as the engine presents it: `has_java_method` is the only
## bound method, and the plugin's own methods are invisible to `has_method`.
class JniShapedPlugin:
	extends RefCounted

	const JAVA_METHODS := ["logEvent", "setConsent", "initializeFirebase"]

	func has_java_method(method: StringName) -> bool:
		return JAVA_METHODS.has(String(method))


## An iOS plugin, or anything GDScript-side: methods are bound normally.
class BoundPlugin:
	extends RefCounted

	func logEvent(_event: String, _params: Dictionary) -> void:
		pass


func run() -> Array[MSTestCase]:
	return [
		_a_jni_singleton_is_asked_through_has_java_method(),
		_a_bound_plugin_is_asked_through_has_method(),
		_nothing_answers_for_nothing(),
	]


func _a_jni_singleton_is_asked_through_has_java_method() -> MSTestCase:
	var test := MSTestCase.new("a JNI-shaped plugin's methods are found")
	var plugin := JniShapedPlugin.new()
	test.check(
		not plugin.has_method("logEvent"),
		"the double is faithful: has_method cannot see a Java method"
	)
	test.check(MSNative.answers(plugin, "logEvent"), "logEvent is found")
	test.check(MSNative.answers(plugin, "setConsent"), "setConsent is found")
	test.check(
		not MSNative.answers(plugin, "showBanner"),
		"a method the plugin does not have is still reported missing"
	)
	return test


func _a_bound_plugin_is_asked_through_has_method() -> MSTestCase:
	var test := MSTestCase.new("a bound plugin's methods are found")
	var plugin := BoundPlugin.new()
	test.check(MSNative.answers(plugin, "logEvent"), "logEvent is found")
	test.check(not MSNative.answers(plugin, "setConsent"), "an absent method is not")
	return test


func _nothing_answers_for_nothing() -> MSTestCase:
	var test := MSTestCase.new("no plugin answers nothing")
	test.check(not MSNative.answers(null, "logEvent"), "null has no methods")
	return test
