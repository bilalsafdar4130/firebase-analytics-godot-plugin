extends Control
## Everything this SDK does, on one screen.
##
## This is the shortest complete integration there is: connect the signals you
## care about, call `initialize()`, and use the services. It runs on a PC, where
## none of the native plugins exist — every button answers `SERVICE_UNAVAILABLE`
## and the log says so, which is exactly what a game should do when it is not on
## a phone.
##
## Read it alongside docs/quick_start.md.

@onready var status: Label = %Status
@onready var output: RichTextLabel = %Output


func _ready() -> void:
	# Connect BEFORE initialising: the SDK can finish in the same frame it starts
	# in, and a signal connected afterwards would miss it.
	MobileServices.initialized.connect(_on_initialized)
	MobileServices.initialization_failed.connect(_on_initialization_failed)

	MobileServices.ads.ad_loaded.connect(func(p, f): _say("ad_loaded: %s (%s)" % [p, f]))
	MobileServices.ads.ad_load_failed.connect(
		func(p, _f, e): _say("ad_load_failed: %s — %s" % [p, MSError.describe(e)])
	)
	MobileServices.ads.ad_closed.connect(func(p, _f): _say("ad_closed: %s" % p))
	# THE ONLY SIGNAL THAT MAY PAY THE PLAYER. Not ad_shown, not ad_closed.
	MobileServices.ads.reward_earned.connect(_on_reward_earned)

	MobileServices.iap.products_loaded.connect(_on_products_loaded)
	MobileServices.iap.purchase_completed.connect(_on_purchase_completed)
	MobileServices.iap.purchase_failed.connect(
		func(product, e): _say("purchase_failed: %s — %s" % [product, MSError.describe(e)])
	)
	MobileServices.iap.purchase_cancelled.connect(func(p): _say("the player cancelled %s" % p))
	MobileServices.iap.entitlements_changed.connect(
		func(list): _say("entitlements: %s" % ", ".join(list))
	)

	MobileServices.player.player_ready.connect(
		func(id, provider): _say("player %s (%s)" % [id, provider])
	)
	MobileServices.consent.consent_updated.connect(
		func(state, can_ads): _say("consent %d, ads %s" % [state, "yes" if can_ads else "no"])
	)

	# `auto_initialize` is on in mobile_services.cfg, so the SDK has already
	# started by the time this runs. Calling it again is deliberate and harmless:
	# initialisation is idempotent, and a game that wants to hold off until after
	# its own privacy screen turns the flag off and calls this instead.
	MobileServices.initialize()
	_refresh_status()


func _on_initialized(report: Dictionary) -> void:
	_say("Mobile Services %s ready on %s" % [report["sdk_version"], report["platform"]])
	_refresh_status()
	MobileServices.analytics.log_event("demo_opened")


func _on_initialization_failed(error: Dictionary) -> void:
	# Only ever a configuration the SDK could not read. A service failing to
	# start does not come through here — the game keeps running without it.
	_say("[color=red]initialisation failed: %s[/color]" % MSError.describe(error))


func _refresh_status() -> void:
	var parts := PackedStringArray()
	parts.append("state: %s" % MobileServices.get_state_name())
	parts.append("ads: %s" % ("ready" if MobileServices.ads.is_ready() else "unavailable"))
	parts.append("iap: %s" % ("ready" if MobileServices.iap.is_ready() else "unavailable"))
	status.text = "  |  ".join(parts)


# --- Ads ----------------------------------------------------------------

func _on_banner_pressed() -> void:
	_report(MobileServices.ads.show_banner("banner_main"))


func _on_hide_banner_pressed() -> void:
	_report(MobileServices.ads.hide_banner("banner_main"))


func _on_interstitial_pressed() -> void:
	# `show()` returning {} means the ad was handed to the provider, NOT that it
	# was watched. Anything that matters happens on a signal.
	_report(MobileServices.ads.show("interstitial_game_over"))


func _on_rewarded_pressed() -> void:
	var problem := MobileServices.ads.show("rewarded_extra_life")
	if not problem.is_empty() and problem["code"] == MSError.NOT_READY:
		# The right thing to tell a player: the ad is coming, not "error 4".
		_say("the rewarded ad is still loading — try again in a moment")
		return
	_report(problem)


func _on_reward_earned(placement: String, reward_type: String, amount: int) -> void:
	# THE ONE PLACE A REWARD IS GRANTED. The SDK guarantees this fires at most
	# once per impression and only when the provider says the player earned it.
	_say("[color=green]reward: %d %s at %s[/color]" % [amount, reward_type, placement])


# --- Purchases ----------------------------------------------------------

func _on_products_loaded(products: Dictionary) -> void:
	for name in products:
		# The store's own formatted price. Never build one from the number: the
		# player's App Store or Play account may be in another currency.
		_say("%s — %s" % [name, products[name].get("price", "?")])


func _on_buy_remove_ads_pressed() -> void:
	if MobileServices.iap.has_entitlement("remove_ads"):
		_say("already owned")
		return
	_report(MobileServices.iap.purchase("remove_ads"))


func _on_restore_pressed() -> void:
	# Apple requires a button that does this. Play does not, but a player on a
	# new phone expects one.
	_report(MobileServices.iap.restore_purchases())


# --- Player and diagnostics ---------------------------------------------

func _on_sign_in_pressed() -> void:
	_report(MobileServices.player.sign_in())


func _on_diagnostics_pressed() -> void:
	# Worth copying into a real game behind a hidden gesture: it answers almost
	# every "it does not work on my phone" question without a debugger, and
	# contains no ids, keys or tokens.
	output.text = ""
	_say("[code]%s[/code]" % MobileServices.get_diagnostics_text())


func _on_privacy_pressed() -> void:
	_report(MobileServices.consent.show_privacy_options())


# --- Plumbing -----------------------------------------------------------

## Shows the outcome of a call that answers with a failure dictionary.
##
## Every service method in this SDK returns `{}` for success or a failure naming
## what went wrong, so one helper covers all of them.
func _report(result: Dictionary) -> void:
	if result.is_empty():
		return
	var code := str(result.get("code", MSError.UNKNOWN))
	var colour := "gray" if MSError.is_benign(code) else "orange"
	_say("[color=%s]%s[/color]" % [colour, MSError.describe(result)])


func _say(line: String) -> void:
	output.text += line + "\n"
	output.scroll_to_line(output.get_line_count() - 1)
