extends RefCounted
## The google-services.json reader in the Android export plugin.
##
## WHY THIS IS TESTED AND THE REST OF THE EXPORT PLUGIN IS NOT: everything else
## in that file needs a running export, but this part is pure, and it is the part
## where a mistake is invisible. A build made from the wrong client block
## installs, runs, and reports into somebody else's Firebase project — which
## looks exactly like a game nobody plays.

const AndroidExport := preload("res://addons/mobile_services/editor/android_export_plugin.gd")

const CONFIG := {
	"project_info": {
		"project_number": "123456789012",
		"project_id": "my-game",
		"storage_bucket": "my-game.appspot.com",
		"firebase_url": "https://my-game.firebaseio.com",
	},
	"client": [
		{
			"client_info": {
				"mobilesdk_app_id": "1:123:android:aaa",
				"android_client_info": {"package_name": "com.example.other"},
			},
			"api_key": [{"current_key": "KEY-OTHER"}],
		},
		{
			"client_info": {
				"mobilesdk_app_id": "1:123:android:bbb",
				"android_client_info": {"package_name": "com.example.game"},
			},
			"api_key": [{"current_key": "KEY-GAME"}],
		},
	],
}


func run() -> Array[MSTestCase]:
	return [
		_reads_the_matching_client(),
		_refuses_what_it_cannot_use(),
		_renders_valid_xml(),
		_client_config_carries_only_public_values(),
	]


func _reads_the_matching_client() -> MSTestCase:
	var test := MSTestCase.new("the client block is chosen by package name")
	var result := AndroidExport.firebase_resources(CONFIG, "com.example.game")
	test.equals(str(result["error"]), "", "no error")
	var values: Dictionary = result["values"]
	# The second block, not the first — one google-services.json can describe
	# several apps and picking the wrong one is undetectable after release.
	test.equals(values["google_app_id"], "1:123:android:bbb", "the right app id")
	test.equals(values["google_api_key"], "KEY-GAME", "the right API key")
	test.equals(values["gcm_defaultSenderId"], "123456789012", "sender id")
	test.equals(values["project_id"], "my-game", "project id")
	test.equals(values["firebase_database_url"], "https://my-game.firebaseio.com", "database url")
	test.equals(
		values["google_crash_reporting_api_key"], "KEY-GAME",
		"the crash-reporting alias some SDK paths still read"
	)
	return test


func _refuses_what_it_cannot_use() -> MSTestCase:
	var test := MSTestCase.new("bad configurations are refused by name")

	var not_json := AndroidExport.firebase_resources({"hello": 1}, "com.example.game")
	test.contains(str(not_json["error"]), "project_info", "no project_info")

	var no_clients := AndroidExport.firebase_resources(
		{"project_info": {"project_id": "x"}, "client": []}, "com.example.game"
	)
	test.contains(str(no_clients["error"]), "no client apps", "empty client list")

	var wrong_package := AndroidExport.firebase_resources(CONFIG, "com.example.nothere")
	test.contains(str(wrong_package["error"]), "different app", "no matching package")

	var no_key := AndroidExport.firebase_resources({
		"project_info": {"project_id": "x"},
		"client": [{
			"client_info": {
				"mobilesdk_app_id": "1:1:android:a",
				"android_client_info": {"package_name": "com.example.game"},
			},
			"api_key": [],
		}],
	}, "com.example.game")
	test.contains(str(no_key["error"]), "no API key", "client with no API key")
	return test


func _renders_valid_xml() -> MSTestCase:
	var test := MSTestCase.new("the generated resource file is well-formed and stable")
	var values := {"google_app_id": "1:1:android:a", "a_key": "value & <angle>"}
	var xml := AndroidExport.resources_xml(values)
	test.contains(xml, "<?xml version=", "an XML declaration")
	test.contains(xml, "translatable=\"false\"", "identifiers are not translatable")
	test.contains(xml, "value &amp; &lt;angle&gt;", "special characters are escaped")

	var parser := XMLParser.new()
	test.equals(parser.open_buffer(xml.to_utf8_buffer()), OK, "the parser accepts it")
	var elements := 0
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT:
			elements += 1
	test.check(elements >= 3, "resources plus one string per value")

	# Sorted output, so a regenerated file is byte-identical when nothing
	# changed — a diff in a generated file should mean something.
	test.check(
		xml.find("a_key") < xml.find("google_app_id"),
		"entries are sorted"
	)
	return test


func _client_config_carries_only_public_values() -> MSTestCase:
	var test := MSTestCase.new("the GDScript-readable client config carries the public values")
	var text := AndroidExport.client_config_text({
		"google_api_key": "KEY",
		"project_id": "my-game",
		"firebase_database_url": "https://my-game.firebaseio.com",
		"google_app_id": "1:1:android:a",
		"google_storage_bucket": "should-not-appear",
	})
	var file := ConfigFile.new()
	test.equals(file.parse(text), OK, "it parses as a ConfigFile")
	test.equals(file.get_value("firebase", "project_id", ""), "my-game", "project id is readable")
	test.check(not text.contains("should-not-appear"), "only the four documented keys travel")
	return test
