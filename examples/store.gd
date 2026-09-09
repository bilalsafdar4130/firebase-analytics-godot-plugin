extends Control
## A store screen: prices from the store, buying, entitlements, restore.

@onready var remove_ads_button: Button = %RemoveAds
@onready var coins_button: Button = %Coins
@onready var premium_button: Button = %Premium
@onready var restore_button: Button = %Restore
@onready var message: Label = %Message


func _ready() -> void:
	MobileServices.iap.products_loaded.connect(_on_products_loaded)
	MobileServices.iap.purchase_completed.connect(_on_purchase_completed)
	MobileServices.iap.purchase_pending.connect(_on_purchase_pending)
	MobileServices.iap.purchase_failed.connect(_on_purchase_failed)
	MobileServices.iap.purchase_cancelled.connect(func(_product):
		# Not an error. The player changed their mind; say nothing.
		_set_busy(false)
	)
	MobileServices.iap.entitlements_changed.connect(func(_entitlements): _refresh())
	MobileServices.iap.purchases_restored.connect(func(products):
		_set_busy(false)
		message.text = "Restored %d purchase(s)." % products.size()
	)

	# Prices are not known until the store answers, so build the screen from the
	# signal rather than here. If billing is unavailable — desktop, the editor, a
	# sideloaded debug build — the buttons stay disabled and say why.
	_refresh()
	if not MobileServices.iap.is_ready():
		message.text = "The store is unavailable on this device."


func _on_products_loaded(products: Dictionary) -> void:
	for name in products:
		var info: Dictionary = products[name]
		# ALWAYS the store's own formatted price. Building one from the number
		# gets the symbol, separator or position wrong in some locale — and the
		# player's store account may be in a different country than their phone.
		var price := str(info.get("price", ""))
		match name:
			"remove_ads": remove_ads_button.text = "Remove ads — %s" % price
			"coins_100": coins_button.text = "100 coins — %s" % price
			"premium_monthly": premium_button.text = "Premium — %s / month" % price
	_refresh()


func _refresh() -> void:
	var owned := MobileServices.iap.has_entitlement("remove_ads")
	remove_ads_button.disabled = owned or not MobileServices.iap.is_ready()
	if owned:
		remove_ads_button.text = "Ads removed — thank you"
	premium_button.disabled = MobileServices.iap.is_subscribed("premium") \
		or not MobileServices.iap.is_ready()
	coins_button.disabled = not MobileServices.iap.is_ready()


# --- Buying -------------------------------------------------------------

func _on_remove_ads_pressed() -> void:
	_buy("remove_ads")


func _on_coins_pressed() -> void:
	_buy("coins_100")


func _on_premium_pressed() -> void:
	# For a subscription with several offers — a free trial, an introductory
	# price — pass the offer's token. Empty means the base plan.
	var info := MobileServices.iap.get_product_info("premium_monthly")
	var offers: Array = info.get("offers", [])
	var token := str(offers[0].get("offer_token", "")) if not offers.is_empty() else ""
	_buy("premium_monthly", token)


func _buy(product: String, offer_token: String = "") -> void:
	_set_busy(true)
	var problem := MobileServices.iap.purchase(product, offer_token)
	if problem.is_empty():
		return
	# The sheet did not open. Everything else arrives on a signal.
	_set_busy(false)
	match str(problem["code"]):
		MSError.ALREADY_OWNED:
			message.text = "You already own this."
			_refresh()
		MSError.SERVICE_UNAVAILABLE, MSError.SERVICE_DISABLED:
			message.text = "The store is unavailable on this device."
		MSError.INVALID_CONFIGURATION:
			# A developer's problem, not a player's — but saying nothing leaves
			# a button that does nothing.
			message.text = "This item isn't available right now."
			push_error(MSError.describe(problem))
		_:
			message.text = "Couldn't start the purchase."


# --- Outcomes -----------------------------------------------------------

## Fires ONCE per purchase, including when it arrives from a restore or from a
## purchase completed on another device. Entitlements are granted by the SDK
## before this; consumables are granted here.
func _on_purchase_completed(purchase: Dictionary) -> void:
	_set_busy(false)
	if purchase["product"] == "coins_100":
		coins += 100
		save_game()
	message.text = "Thank you!"
	_refresh()


func _on_purchase_pending(_purchase: Dictionary) -> void:
	_set_busy(false)
	# Cash payments and family approval can take days. Grant nothing; it will
	# complete on a later launch because restore_on_start re-reads the account.
	message.text = "Waiting for payment to clear. You'll get it automatically."


func _on_purchase_failed(_product: String, error: Dictionary) -> void:
	_set_busy(false)
	message.text = "Something went wrong with the purchase."
	push_warning(MSError.describe(error))


## Apple REQUIRES a button that does this, and a player on a new phone expects
## one on Android too.
func _on_restore_pressed() -> void:
	_set_busy(true)
	MobileServices.iap.restore_purchases()


func _set_busy(busy: bool) -> void:
	restore_button.disabled = busy
	if busy:
		message.text = ""


var coins := 0
func save_game() -> void: pass
