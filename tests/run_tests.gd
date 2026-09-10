extends SceneTree
## Runs every test in this folder and exits non-zero if any of them failed.
##
##     godot --headless --script res://tests/run_tests.gd
##
## WHAT IS AND IS NOT TESTED HERE. Everything pure: configuration parsing and
## validation, the google-services.json reader, Firebase's event-name rules, the
## error vocabulary, and that the four places stating the SDK version agree.
## Those are the parts where a mistake is silent in a shipped game — a mis-parsed
## config produces a build that installs, runs, and reports to nothing.
##
## What is NOT tested is anything that needs a device: no ad loads, no purchases,
## no Firebase. Those are checked by hand against the list in docs/testing.md,
## because a test double for Google Play Billing tests the double.

const TESTS := [
	preload("res://tests/test_config.gd"),
	preload("res://tests/test_firebase_resources.gd"),
	preload("res://tests/test_analytics_rules.gd"),
	preload("res://tests/test_errors.gd"),
	preload("res://tests/test_versions.gd"),
	preload("res://tests/test_ad_id_permission.gd"),
]


func _initialize() -> void:
	var total_checks := 0
	var failed: Array[MSTestCase] = []
	var cases: Array[MSTestCase] = []

	for script in TESTS:
		var suite = script.new()
		for case in suite.run():
			cases.append(case)

	for case in cases:
		total_checks += case.checks
		if case.passed():
			print("  ok    %s (%d checks)" % [case.name, case.checks])
		else:
			failed.append(case)
			print("  FAIL  %s" % case.name)
			for failure in case.failures:
				print("          %s" % failure)

	print("")
	print("%d test(s), %d check(s), %d failure(s)" % [
		cases.size(), total_checks, failed.size()
	])
	quit(1 if not failed.is_empty() else 0)
