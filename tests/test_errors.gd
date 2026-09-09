extends RefCounted
## The error vocabulary every service answers in.
##
## The shape matters more than it looks: game code reads `error.code` without
## checking the key is there, so every failure this SDK produces must carry all
## five keys with the right types.


func run() -> Array[MSTestCase]:
	return [_shape(), _recoverability(), _rendering()]


func _shape() -> MSTestCase:
	var test := MSTestCase.new("every error carries the same five keys")
	var error := MSError.make(MSError.NO_FILL, "nothing to serve", "admob/banner", 3)
	test.equals(error["code"], "NO_FILL", "code")
	test.equals(error["message"], "nothing to serve", "message")
	test.equals(error["source"], "admob/banner", "source")
	test.equals(error["native_code"], 3, "the provider's own number is kept")
	test.equals(error["recoverable"], true, "recoverable")

	var bare := MSError.make(MSError.UNKNOWN)
	test.equals(bare["message"], "", "message defaults to empty, not null")
	test.equals(bare["native_code"], -1, "no native code is -1, not 0")
	return test


func _recoverability() -> MSTestCase:
	var test := MSTestCase.new("recoverable says whether a retry could work")
	# The distinction a "Try again" button needs: right for a timeout, wrong for
	# a product that does not exist.
	test.check(MSError.is_recoverable(MSError.NETWORK_ERROR), "a timeout is retryable")
	test.check(MSError.is_recoverable(MSError.NO_FILL), "no fill is retryable")
	test.check(MSError.is_recoverable(MSError.UNKNOWN), "the unknown is treated as retryable")
	test.check(not MSError.is_recoverable(MSError.ALREADY_OWNED), "already owned is not")
	test.check(not MSError.is_recoverable(MSError.INVALID_CONFIGURATION), "a bad config is not")
	test.check(not MSError.is_recoverable(MSError.SERVICE_DISABLED), "a disabled service is not")

	# Benign codes are what a desktop test run produces on every call; a game
	# that logged them as errors would bury the ones that matter.
	test.check(MSError.is_benign(MSError.SERVICE_UNAVAILABLE), "no plugin is benign")
	test.check(MSError.is_benign(MSError.SERVICE_DISABLED), "switched off is benign")
	test.check(not MSError.is_benign(MSError.NETWORK_ERROR), "a network failure is not benign")
	return test


func _rendering() -> MSTestCase:
	var test := MSTestCase.new("errors render as one readable line")
	var error := MSError.make(MSError.NO_FILL, "nothing to serve", "admob/banner", 3)
	var line := MSError.describe(error)
	test.contains(line, "NO_FILL", "the code")
	test.contains(line, "admob/banner", "the source")
	test.contains(line, "native 3", "the provider's number")
	test.contains(line, "nothing to serve", "the message")

	var sparse := MSError.describe(MSError.make(MSError.NOT_READY))
	test.equals(sparse, "NOT_READY", "nothing extra when there is nothing to add")
	return test
