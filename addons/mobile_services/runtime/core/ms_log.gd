class_name MSLog
extends RefCounted
## One place every part of the SDK writes to, so a game can turn the whole
## thing down to silence in a release build without hunting for `print` calls.
##
## SHIPPED BUILDS SHOULD NOT BE CHATTY. Godot's `print` reaches logcat and the
## Xcode console; a rewarded ad that logs six lines per impression turns a
## user's bug report into something nobody can read. The default level is
## therefore WARN, and `mobile_services.cfg` raises it while you are working.
##
## NOTHING SENSITIVE GOES THROUGH HERE. Purchase tokens, ID-token strings,
## signatures and the player's Google account details are never logged, at any
## level; [method redact] exists so the few call sites that handle them cannot
## forget.

enum Level {
	NONE = 0,
	ERROR = 1,
	WARN = 2,
	INFO = 3,
	DEBUG = 4,
}

const LEVEL_NAMES := {
	Level.NONE: "none",
	Level.ERROR: "error",
	Level.WARN: "warn",
	Level.INFO: "info",
	Level.DEBUG: "debug",
}

## Keys whose values are never printed, whatever the level. Matched as
## substrings against a lower-cased key name, so `purchaseToken`,
## `purchase_token` and `originalPurchaseToken` are all caught by one entry.
const SECRET_KEY_FRAGMENTS := [
	"token", "signature", "receipt", "secret", "password", "credential",
	"auth_code", "authcode", "id_token", "email",
]

var level: Level = Level.WARN

## The last few lines, kept in memory for `MobileServices.get_diagnostics()` —
## a player can read a diagnostics screen out over chat, and cannot read
## logcat.
var _tail: Array[String] = []
const TAIL_LIMIT := 60


func set_level_name(name: String) -> void:
	var wanted := name.strip_edges().to_lower()
	for key in LEVEL_NAMES:
		if LEVEL_NAMES[key] == wanted:
			level = key
			return
	push_warning("[MobileServices] unknown log level %s; keeping %s" % [
		name, LEVEL_NAMES[level]
	])


func get_level_name() -> String:
	return str(LEVEL_NAMES.get(level, "warn"))


func debug(tag: String, message: String) -> void:
	_write(Level.DEBUG, tag, message)


func info(tag: String, message: String) -> void:
	_write(Level.INFO, tag, message)


func warn(tag: String, message: String) -> void:
	_write(Level.WARN, tag, message)


func error(tag: String, message: String) -> void:
	_write(Level.ERROR, tag, message)


## Reports a failure at the severity it deserves.
##
## The benign codes (a disabled service, a missing native half) are DEBUG: on
## desktop they happen on every single call, and at WARN they would drown the
## log in noise about a build behaving exactly as intended.
func failure(tag: String, error_dict: Dictionary) -> void:
	var code := str(error_dict.get("code", MSError.UNKNOWN))
	var line := MSError.describe(error_dict)
	if MSError.is_benign(code):
		_write(Level.DEBUG, tag, line)
	else:
		_write(Level.ERROR, tag, line)


## A copy of a dictionary safe to print or put in a diagnostics dump.
##
## Values under a key matching [constant SECRET_KEY_FRAGMENTS] are replaced
## with their length, which is all a support conversation ever needs ("the
## token is there and it is 312 characters" answers the question without
## putting a live credential in a chat log).
static func redact(data: Dictionary) -> Dictionary:
	var out := {}
	for key in data:
		var name := str(key).to_lower()
		var secret := false
		for fragment in SECRET_KEY_FRAGMENTS:
			if name.contains(fragment):
				secret = true
				break
		var value = data[key]
		if secret:
			out[key] = "<redacted:%d chars>" % str(value).length()
		elif value is Dictionary:
			out[key] = redact(value)
		elif value is Array:
			var items := []
			for item in value:
				items.append(redact(item) if item is Dictionary else item)
			out[key] = items
		else:
			out[key] = value
	return out


## The recent log lines, oldest first. Read by the diagnostics dump.
func get_tail() -> Array[String]:
	return _tail.duplicate()


func _write(at: Level, tag: String, message: String) -> void:
	var line := "[MobileServices/%s] %s" % [tag, message]
	# The tail keeps everything the caller asked to record, even below the
	# print threshold: the point of a diagnostics screen is to answer questions
	# about a session that has already happened, when nobody was watching the
	# console.
	_tail.append("%s %s" % [LEVEL_NAMES.get(at, "?"), line])
	if _tail.size() > TAIL_LIMIT:
		_tail = _tail.slice(_tail.size() - TAIL_LIMIT)
	if at > level:
		return
	if at == Level.ERROR:
		push_error(line)
	elif at == Level.WARN:
		push_warning(line)
	else:
		print(line)
