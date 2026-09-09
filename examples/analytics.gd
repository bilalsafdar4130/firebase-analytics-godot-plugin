extends Node
## Analytics, as a game would actually use it.
##
## The habit worth forming: send events for the DECISIONS a player makes and the
## walls they hit, not for everything that happens. A funnel you can read beats a
## complete record you cannot.

func _ready() -> void:
	MobileServices.analytics.log_event("game_started")


# --- Progression --------------------------------------------------------

func on_level_started(level: int) -> void:
	MobileServices.analytics.log_level_start("level_%02d" % level)
	# Breadcrumbs cost nothing and turn a crash report full of engine symbols
	# into one that names where the player was.
	MobileServices.crash.set_key("level", level)


func on_level_finished(level: int, won: bool, seconds: float, deaths: int) -> void:
	MobileServices.analytics.log_level_end("level_%02d" % level, won, {
		"seconds": int(seconds),
		"deaths": deaths,
	})


func on_player_quit_mid_level(level: int, progress_percent: int) -> void:
	# The event most games forget, and the one that tells you which level is too
	# hard: quits with progress, not just failures.
	MobileServices.analytics.log_event("level_abandoned", {
		"level_name": "level_%02d" % level,
		"progress": progress_percent,
	})


# --- Screens ------------------------------------------------------------

func on_screen_opened(screen: String) -> void:
	MobileServices.analytics.log_screen_view(screen)
	MobileServices.crash.log_breadcrumb("screen: %s" % screen)


# --- Segmentation -------------------------------------------------------

func on_settings_changed(difficulty: String, ads_removed: bool) -> void:
	# User properties segment every FUTURE event, so set them when they change,
	# not on every event. Nothing identifying a person belongs here.
	MobileServices.analytics.set_user_property("difficulty", difficulty)
	MobileServices.analytics.set_user_property("ads_removed", "yes" if ads_removed else "no")


# --- A game's own event names -------------------------------------------

## Firebase drops names it does not like, silently. The SDK checks first and logs
## the reason, but the cheapest fix is a helper like this, so the rules are
## satisfied in one place instead of at forty call sites.
func track(action: String, params: Dictionary = {}) -> void:
	# ≤ 40 chars, letters/digits/underscore, not starting with a digit, and not
	# prefixed firebase_/google_/ga_.
	var name := action.to_snake_case().substr(0, 40)
	MobileServices.analytics.log_event(name, params)
