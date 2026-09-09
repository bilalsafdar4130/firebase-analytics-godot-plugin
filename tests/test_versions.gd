extends RefCounted
## The SDK version is stated in five places. They must agree.
##
## THIS IS NOT PEDANTRY. `MSNative` reports a native plugin that is older than
## the GDScript half as "this method is missing from the installed native
## plugin", and that message is only useful if the version numbers can be
## trusted. A diagnostics dump showing GDScript 2.1 against an AAR that also
## SAYS 2.1 but was built from 2.0 sources sends every investigation the wrong
## way.
##
## It also catches the release mistake that is otherwise silent: bumping
## plugin.cfg and forgetting the constant a game actually reads.

const SOURCES := {
	"plugin.cfg": "res://addons/mobile_services/plugin.cfg",
	"MobileServices.VERSION": "res://addons/mobile_services/runtime/mobile_services.gd",
	"MobileServicesEditorConfig.VERSION": "res://addons/mobile_services/editor/editor_config.gd",
	"BuildInfo.kt (Android)":
		"res://addons/mobile_services/android/core/src/main/java/com/bilalsafdar/godot/mobileservices/core/BuildInfo.kt",
	"ms_core.mm (iOS)": "res://addons/mobile_services/ios/src/core/ms_core.mm",
}


func run() -> Array[MSTestCase]:
	return [_all_five_agree()]


func _all_five_agree() -> MSTestCase:
	var test := MSTestCase.new("the SDK version agrees in all five places")
	var expected := MobileServices.VERSION if Engine.has_singleton("MobileServices") \
		else _extract(SOURCES["MobileServices.VERSION"])
	test.check(not expected.is_empty(), "a version could be read at all")

	for label in SOURCES:
		var found := _extract(SOURCES[label])
		test.equals(found, expected, "%s states the same version" % label)
	return test


## Pulls the first `MAJOR.MINOR.PATCH` out of a file, whatever language it is in.
##
## A regex rather than five parsers: every one of these files states the version
## as a quoted semver and nothing else in them looks like one.
func _extract(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "<%s is missing>" % path
	var text := FileAccess.get_file_as_string(path)
	var regex := RegEx.new()
	regex.compile("\"(\\d+\\.\\d+\\.\\d+)\"")
	var found := regex.search(text)
	return found.get_string(1) if found != null else "<no version in %s>" % path
