extends Node
## Ads with the two things every game needs and the SDK deliberately does not do
## for you: a frequency rule, and a reward that is granted in exactly one place.

## How long after an interstitial before another may show. A real game reads this
## from Remote Config so it can be tuned without a store review.
var interstitial_cooldown := 90.0
var _last_interstitial_at := -1000.0


func _ready() -> void:
	MobileServices.ads.reward_earned.connect(_on_reward_earned)
	MobileServices.ads.ad_load_failed.connect(_on_load_failed)
	MobileServices.ads.ad_closed.connect(func(placement, _format):
		if placement.begins_with("interstitial"):
			get_tree().paused = false
	)
	# A player who bought remove_ads. `ads/suppress_when_entitled` does this
	# automatically; this is the by-hand version.
	MobileServices.iap.entitlements_changed.connect(func(entitlements):
		MobileServices.ads.set_suppressed(entitlements.has("remove_ads"))
	)


# --- Banners ------------------------------------------------------------

func show_menu_banner() -> void:
	MobileServices.ads.show_banner("banner_main")


func leave_menu() -> void:
	# Hide keeps it refreshing for when the player comes back; destroy releases
	# the view and the connection. Hide for a screen you return to, destroy for
	# one you do not.
	MobileServices.ads.hide_banner("banner_main")


# --- Interstitials ------------------------------------------------------

func on_game_over() -> void:
	if not _may_show_interstitial():
		return
	# Pause first: the ad takes the screen either way, and a game still running
	# underneath it is a game the player comes back to having lost.
	get_tree().paused = true
	var problem := MobileServices.ads.show("interstitial_game_over")
	if problem.is_empty():
		_last_interstitial_at = Time.get_ticks_msec() / 1000.0
	else:
		get_tree().paused = false


func _may_show_interstitial() -> bool:
	if MobileServices.iap.has_entitlement("remove_ads"):
		return false
	var now := Time.get_ticks_msec() / 1000.0
	return now - _last_interstitial_at >= interstitial_cooldown


# --- Rewarded -----------------------------------------------------------

func on_watch_ad_for_a_life_pressed() -> void:
	var problem := MobileServices.ads.show("rewarded_extra_life")
	if problem.is_empty():
		return
	match str(problem["code"]):
		MSError.NOT_READY:
			# Tell the player the truth: it is coming, not "error 4".
			$Message.text = "The ad isn't ready yet — try again in a moment."
		MSError.SERVICE_DISABLED, MSError.SERVICE_UNAVAILABLE:
			$WatchAdButton.hide()
		_:
			$Message.text = "Couldn't load an ad. Check your connection?"


## THE ONLY PLACE A REWARD IS GRANTED.
##
## Not on `ad_shown`, not on `ad_closed`, and not on `show()` returning `{}` —
## that only means the ad was handed to the network. The SDK guarantees this
## fires at most once per impression and only when the network says the player
## earned it.
func _on_reward_earned(placement: String, _reward_type: String, amount: int) -> void:
	match placement:
		"rewarded_extra_life":
			lives += maxi(amount, 1)
			$Message.text = "+%d life" % maxi(amount, 1)
		"rewarded_double_coins":
			coins *= 2
	save_game()


func _on_load_failed(placement: String, _format: String, error: Dictionary) -> void:
	# NO_FILL and NETWORK_ERROR happen constantly on real devices and the SDK is
	# already retrying with backoff. Only the rest is worth a line in the log.
	if not MSError.is_recoverable(error["code"]):
		push_warning("%s will never load: %s" % [placement, MSError.describe(error)])


# Stand-ins so the file reads as a whole script.
var lives := 3
var coins := 0
func save_game() -> void: pass
