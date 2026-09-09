class_name MSTestCase
extends RefCounted
## The smallest test harness that does the job.
##
## No dependency on a testing addon, because the point of these tests is to run
## in CI on a bare engine with `--headless --script`, and a test framework that
## has to be installed first is one more thing that can be the reason CI is red.

var name := "test"
var failures: PackedStringArray = PackedStringArray()
var checks := 0


func _init(test_name: String) -> void:
	name = test_name


func check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)


func equals(actual: Variant, expected: Variant, description: String) -> void:
	checks += 1
	if actual != expected:
		failures.append("%s — expected %s, got %s" % [description, expected, actual])


func contains(haystack: Variant, needle: String, description: String) -> void:
	checks += 1
	var found := false
	if haystack is String:
		found = haystack.contains(needle)
	elif haystack is Array or haystack is PackedStringArray:
		for item in haystack:
			if str(item).contains(needle):
				found = true
				break
	if not found:
		failures.append("%s — %s is not in %s" % [description, needle, haystack])


func is_empty_array(value: Variant, description: String) -> void:
	checks += 1
	if value.size() != 0:
		failures.append("%s — expected nothing, got %s" % [description, value])


func passed() -> bool:
	return failures.is_empty()
