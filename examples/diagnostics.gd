extends Control
## A debug screen worth having in every build, behind a hidden gesture.
##
## It answers almost every "it doesn't work on my phone" without a debugger, and
## a player can read it out over chat where they cannot read logcat. It contains
## no ad unit ids, no product ids, no keys and no purchase tokens — `MSLog.redact`
## and each service's own `diagnostics()` see to that — so it is safe to paste
## into a public issue.

@onready var output: RichTextLabel = %Output

## Seven taps on the version label. Enough that nobody finds it by accident.
const TAPS_TO_OPEN := 7
var _taps := 0


func _on_version_label_pressed() -> void:
	_taps += 1
	if _taps >= TAPS_TO_OPEN:
		_taps = 0
		show_diagnostics()


func show_diagnostics() -> void:
	show()
	output.text = "[code]%s[/code]" % MobileServices.get_diagnostics_text()


func _on_copy_pressed() -> void:
	DisplayServer.clipboard_set(MobileServices.get_diagnostics_text())
	%Message.text = "Copied. Paste it into your bug report."


## A short summary for a support screen, rather than the whole dump.
func summary() -> String:
	var report := MobileServices.get_diagnostics()
	var lines := PackedStringArray()
	lines.append("SDK %s on %s %s" % [
		report["sdk_version"], report["platform"], report["os_version"]
	])
	lines.append("Godot %s, %s" % [report["godot_version"], report["model"]])
	lines.append("state: %s" % report["state"])
	for service in report["services"]:
		var detail: Dictionary = report["services"][service]
		var state := "ready" if detail["ready"] else (
			"off" if not detail["enabled"] else "unavailable"
		)
		var line := "%s: %s" % [service, state]
		if not str(detail["last_error"]).is_empty():
			line += " — %s" % detail["last_error"]
		lines.append(line)
	lines.append("player: %s" % report["services"]["player"].get("player_id", "?"))
	return "\n".join(lines)


## Everything a bug report needs, in one place, with nothing sensitive.
func _on_report_a_problem_pressed() -> void:
	# Firebase would silently drop an event name over 40 characters; the SDK
	# checks first. `player_reported_problem` is fine.
	MobileServices.analytics.log_event("player_reported_problem")
	MobileServices.crash.record_error(
		"player_report", "the player used the report button",
		MobileServices.get_diagnostics()
	)
	%Message.text = "Thanks — that's been sent."
