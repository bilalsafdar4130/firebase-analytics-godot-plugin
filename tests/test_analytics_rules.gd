extends RefCounted
## Firebase's naming rules, which Firebase itself enforces by SILENTLY DROPPING
## what it does not like.
##
## An event name over 40 characters, one starting with a digit, a reserved
## `firebase_` prefix — each is discarded by the SDK with no error anywhere, and
## the only symptom is a report that is emptier than it should be, discovered
## weeks later. These are the checks that turn that into a log line at the moment
## the call is written.


func run() -> Array[MSTestCase]:
	return [_event_names(), _identifiers()]


func _event_names() -> MSTestCase:
	var test := MSTestCase.new("event names are checked against Firebase's rules")
	var analytics := MSAnalytics.new()

	test.equals(analytics._clean_event_name("level_end"), "level_end", "an ordinary name")
	test.equals(analytics._clean_event_name("  level_end  "), "level_end", "surrounding space")
	test.equals(analytics._clean_event_name(""), "", "empty")
	test.equals(analytics._clean_event_name("2fast"), "", "starting with a digit")
	test.equals(analytics._clean_event_name("level end"), "", "containing a space")
	test.equals(analytics._clean_event_name("level-end"), "", "containing a hyphen")
	test.equals(analytics._clean_event_name("firebase_thing"), "", "a reserved prefix")
	test.equals(analytics._clean_event_name("GA_thing"), "", "a reserved prefix, upper case")
	test.equals(analytics._clean_event_name("a".repeat(41)), "", "past 40 characters")
	test.equals(analytics._clean_event_name("a".repeat(40)), "a".repeat(40), "exactly 40")

	# Deliberately NOT rewritten into something legal: a silently renamed event is
	# a report split across two names, which is worse than a missing one because
	# it looks like data.
	test.equals(analytics._clean_event_name("level end"), "", "a bad name is refused, not fixed")
	analytics.free()
	return test


func _identifiers() -> MSTestCase:
	var test := MSTestCase.new("the identifier rule matches Firebase's")
	test.check(MSAnalytics._is_valid_identifier("a"), "one letter")
	test.check(MSAnalytics._is_valid_identifier("a_1"), "letters, digits, underscore")
	test.check(MSAnalytics._is_valid_identifier("Level_End_2"), "mixed case")
	test.check(not MSAnalytics._is_valid_identifier("_leading"), "leading underscore")
	test.check(not MSAnalytics._is_valid_identifier("1a"), "leading digit")
	test.check(not MSAnalytics._is_valid_identifier("a b"), "a space")
	test.check(not MSAnalytics._is_valid_identifier("a.b"), "a dot")
	return test
