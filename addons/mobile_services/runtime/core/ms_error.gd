class_name MSError
extends RefCounted
## Every failure this SDK can report, as one small vocabulary.
##
## WHY A VOCABULARY RATHER THAN PASSED-THROUGH SDK ERRORS. AdMob answers with
## integers 0-3, AppLovin with a different set, Play Billing with a third, and
## StoreKit with `NSError` domains. A game that wants to say "no network, try
## again" would otherwise have to know all four. So every provider's failure is
## translated once, at the edge, into a code from this list, and the provider's
## own text is carried alongside it in `message` for the log.
##
## The codes are strings, not an enum, because they cross the JNI/Obj-C boundary
## and appear in analytics events and diagnostics dumps: a string survives all
## three legibly, an integer becomes a mystery in a crash report.

## Nothing went wrong. Never appears inside a failure signal.
const OK := "OK"

## `MobileServices.initialize()` has not run, or has not finished.
const NOT_INITIALIZED := "NOT_INITIALIZED"

## The service is switched off in `mobile_services.cfg`. Not a fault: a game
## that ships without ads gets this from every ad call, and should ignore it.
const SERVICE_DISABLED := "SERVICE_DISABLED"

## The native half is missing: desktop, the editor, a build exported without
## the plugin, or a platform this service has no implementation for. Also not a
## fault — it is what running the game on a PC looks like.
const SERVICE_UNAVAILABLE := "SERVICE_UNAVAILABLE"

## The native half is present but its own SDK refused to start (Google Play
## Services too old, Firebase config missing, AppLovin key rejected).
const INITIALIZATION_FAILED := "INITIALIZATION_FAILED"

## The configuration is wrong in a way the SDK can see: an unknown placement, a
## product id that is not in `mobile_services.cfg`, an ad unit with no id for
## this platform.
const INVALID_CONFIGURATION := "INVALID_CONFIGURATION"

## The call itself was malformed — an empty event name, a negative score.
const INVALID_ARGUMENT := "INVALID_ARGUMENT"

## Asked to show something that is not loaded yet.
const NOT_READY := "NOT_READY"

## The provider had no ad to give. Ordinary and frequent; not an error to
## report to the player.
const NO_FILL := "NO_FILL"

## Off-line, or the request timed out.
const NETWORK_ERROR := "NETWORK_ERROR"

## The player backed out: closed the purchase sheet, dismissed the sign-in.
const USER_CANCELLED := "USER_CANCELLED"

## Google Play / the App Store says this account already owns it.
const ALREADY_OWNED := "ALREADY_OWNED"

## ...and this one says it does not, so it cannot be consumed or refunded.
const NOT_OWNED := "NOT_OWNED"

## The purchase is awaiting a slow payment method (cash, family approval).
## Not a failure — see `docs/iap.md`, "Pending purchases".
const PURCHASE_PENDING := "PURCHASE_PENDING"

## The store is unreachable, out of date, or unavailable in this region.
const BILLING_UNAVAILABLE := "BILLING_UNAVAILABLE"

## The player has not consented, and this call needs consent to proceed.
const CONSENT_REQUIRED := "CONSENT_REQUIRED"

## The operating system or store version is too old for this feature.
const UNSUPPORTED := "UNSUPPORTED"

## A rate limit — Remote Config fetches, mostly.
const THROTTLED := "THROTTLED"

## The provider failed in a way that does not map onto anything above. The
## provider's own code and text are in the failure's `native_code`/`message`.
const UNKNOWN := "UNKNOWN"


## Builds the dictionary every failing call and signal in this SDK carries.
##
## Always these five keys, always these types, so game code can read
## `error.code` without checking whether the key is there. `native_code` is the
## provider's own number where there was one, kept for support conversations
## with Google or AppLovin, and `-1` when there was not.
static func make(
	code: String,
	message: String = "",
	source: String = "",
	native_code: int = -1
) -> Dictionary:
	return {
		"code": code,
		"message": message,
		"source": source,
		"native_code": native_code,
		"recoverable": is_recoverable(code),
	}


## Whether retrying the same call later could plausibly work.
##
## The distinction game code actually needs: a "Try again" button is right for
## a timeout and wrong for a product that does not exist. Deliberately
## conservative — anything genuinely unknown is treated as retryable, because a
## button that does nothing is a smaller mistake than a player stuck with no
## way forward.
static func is_recoverable(code: String) -> bool:
	match code:
		SERVICE_DISABLED, SERVICE_UNAVAILABLE, INVALID_CONFIGURATION, \
		INVALID_ARGUMENT, UNSUPPORTED, ALREADY_OWNED, NOT_OWNED:
			return false
		_:
			return true


## True for the codes that mean "this build simply does not do that" rather
## than "something broke".
##
## Games use it to keep quiet: on a desktop test run every ad and billing call
## answers SERVICE_UNAVAILABLE, and a wrapper that logged an error each time
## would bury the failures that matter.
static func is_benign(code: String) -> bool:
	return code == SERVICE_DISABLED or code == SERVICE_UNAVAILABLE


## A one-line rendering for logs and diagnostics screens.
static func describe(error: Dictionary) -> String:
	var code := str(error.get("code", UNKNOWN))
	var message := str(error.get("message", ""))
	var source := str(error.get("source", ""))
	var native := int(error.get("native_code", -1))
	var text := code
	if not source.is_empty():
		text = "%s [%s]" % [text, source]
	if native != -1:
		text = "%s (native %d)" % [text, native]
	if not message.is_empty():
		text = "%s: %s" % [text, message]
	return text
