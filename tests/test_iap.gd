extends RefCounted
## What `MSIap` does with what Play Billing tells it.
##
## WHY A DOUBLE IS ENOUGH HERE. The README of this folder says a double for
## Play Billing tests the double, and for buying something that is true. These
## tests drive the other direction: the native bridge has ALREADY answered, and
## the question is what the GDScript half does with the answer -- which product
## is reported unavailable and why, and what a refusal leads to. That half is
## pure, and a mistake in it is a BUY button that silently never appears.


## The Android billing plugin as `MSNative` sees it: the signals the bridge
## declares, and every method recorded rather than run.
class FakeBilling:
	extends RefCounted

	signal billing_ready
	signal billing_failed(code: int, message: String)
	signal products_loaded(products_json: String)
	signal products_load_failed(code: int, message: String)
	signal products_unfetched(products_json: String)
	signal purchase_updated(purchase_json: String)
	signal purchase_failed(store_id: String, code: int, message: String)
	signal purchases_queried(purchases_json: String)
	signal purchase_consumed(token: String, store_id: String)
	signal purchase_acknowledged(token: String, store_id: String)

	var calls: Array[String] = []

	func initializeBilling(_products_json: String) -> void:
		calls.append("initializeBilling")

	func queryProducts() -> void:
		calls.append("queryProducts")

	func queryPurchases() -> void:
		calls.append("queryPurchases")

	func purchase(store_id: String, _type: String, _offer_token: String) -> void:
		calls.append("purchase:%s" % store_id)

	func consume(_token: String) -> void:
		calls.append("consume")

	func acknowledge(_token: String) -> void:
		calls.append("acknowledge")


func run() -> Array[MSTestCase]:
	MSConfig.platform_override = "android"
	var cases: Array[MSTestCase] = [
		_unfetched_products_are_reported_with_their_reason(),
		_a_product_on_sale_again_is_no_longer_unavailable(),
		_already_owned_restores_purchases(),
		_a_cancel_is_not_a_failure(),
		_a_consumable_is_granted_once_per_token(),
	]
	MSConfig.platform_override = ""
	return cases


## A started `MSIap` wired to a fresh double, with three products: a coin pack,
## a one-time product, and one whose store id differs from its name.
func _started_iap() -> Array:
	var config := MSConfig.from_dictionary({
		"iap": {"enabled": true, "restore_on_start": false},
		"iap.product.coins_small": {"type": "consumable", "entitlement": ""},
		"iap.product.remove_ads": {"type": "non_consumable", "entitlement": "remove_ads"},
		"iap.product.coins_big": {
			"type": "consumable", "entitlement": "", "android_id": "com.example.coins_big",
		},
	})
	var log := MSLog.new()
	log.level = MSLog.Level.NONE
	var fake := FakeBilling.new()
	var native := MSNative.new("MobileServicesBillingTestDouble", log)
	native._singleton = fake
	var iap := MSIap.new()
	iap.service_name = "iap"
	iap.log = log
	iap.config = config
	iap.native = native
	iap.setup()
	fake.billing_ready.emit()
	fake.calls.clear()
	return [iap, fake]


func _unfetched_products_are_reported_with_their_reason() -> MSTestCase:
	var test := MSTestCase.new("a product Play will not sell is reported, with why")
	var pair := _started_iap()
	var iap: MSIap = pair[0]
	var fake: FakeBilling = pair[1]
	var heard := []
	iap.products_unavailable.connect(func(products: Dictionary) -> void: heard.append(products))
	fake.products_unfetched.emit(JSON.stringify([
		{"id": "com.example.coins_big", "reason": "product_not_found"},
		{"id": "remove_ads", "reason": "no_eligible_offer"},
	]))
	var unavailable := iap.get_unavailable_products()
	test.equals(unavailable.get("coins_big"), "product_not_found",
		"reported under its logical name, not its store id")
	test.equals(unavailable.get("remove_ads"), "no_eligible_offer", "the reason is kept")
	test.equals(heard.size(), 1, "products_unavailable fires once")
	test.contains(iap.diagnostics()["products_unavailable"], "coins_big: product_not_found",
		"the diagnostics dump names it")
	test.check(not MSIap.unavailable_hint("product_not_found").is_empty(),
		"every reason has something to check")
	iap.free()
	return test


func _a_product_on_sale_again_is_no_longer_unavailable() -> MSTestCase:
	var test := MSTestCase.new("a product priced by a later query is not unavailable")
	var pair := _started_iap()
	var iap: MSIap = pair[0]
	var fake: FakeBilling = pair[1]
	fake.products_unfetched.emit(JSON.stringify([
		{"id": "coins_small", "reason": "product_not_found"},
	]))
	fake.products_loaded.emit(JSON.stringify([
		{"id": "coins_small", "price": "$0.99", "price_micros": 990000, "currency": "USD"},
	]))
	test.is_empty_array(iap.get_unavailable_products().keys(),
		"activating it in the Console clears the report on the next query")
	test.equals(iap.get_product_info("coins_small").get("price"), "$0.99", "and it is priced")
	iap.free()
	return test


func _already_owned_restores_purchases() -> MSTestCase:
	var test := MSTestCase.new("ITEM_ALREADY_OWNED re-reads what the account owns")
	var pair := _started_iap()
	var iap: MSIap = pair[0]
	var fake: FakeBilling = pair[1]
	var failures := []
	iap.purchase_failed.connect(
		func(product: String, error: Dictionary) -> void: failures.append([product, error])
	)
	fake.purchase_failed.emit("coins_small", 7, "Item is already owned.")
	test.equals(failures.size(), 1, "the game still hears the refusal")
	test.equals(failures[0][1].get("code"), MSError.ALREADY_OWNED, "as ALREADY_OWNED")
	test.check(fake.calls.has("queryPurchases"),
		"and the stuck purchase is fetched so it can be delivered and consumed")
	iap.free()
	return test


func _a_cancel_is_not_a_failure() -> MSTestCase:
	var test := MSTestCase.new("a cancelled purchase is neither a failure nor a restore")
	var pair := _started_iap()
	var iap: MSIap = pair[0]
	var fake: FakeBilling = pair[1]
	var cancelled := []
	var failed := []
	iap.purchase_cancelled.connect(func(product: String) -> void: cancelled.append(product))
	iap.purchase_failed.connect(func(product: String, _e: Dictionary) -> void: failed.append(product))
	fake.purchase_failed.emit("remove_ads", 1, "")
	test.equals(cancelled, ["remove_ads"], "purchase_cancelled names the product")
	test.is_empty_array(failed, "purchase_failed does not fire")
	test.check(not fake.calls.has("queryPurchases"), "nothing is restored")
	iap.free()
	return test


func _a_consumable_is_granted_once_per_token() -> MSTestCase:
	var test := MSTestCase.new("a consumable is granted once, and always consumed")
	var pair := _started_iap()
	var iap: MSIap = pair[0]
	var fake: FakeBilling = pair[1]
	var granted := []
	iap.purchase_completed.connect(func(p: Dictionary) -> void: granted.append(p["product"]))
	var purchase := JSON.stringify({
		"product_id": "com.example.coins_big", "state": "purchased", "token": "t-1",
		"acknowledged": false,
	})
	fake.purchase_updated.emit(purchase)
	fake.purchase_updated.emit(purchase)
	test.equals(granted, ["coins_big"], "the second report of the same token grants nothing")
	test.equals(fake.calls.count("consume"), 2, "but it is consumed again in case the first failed")
	test.check(not fake.calls.has("acknowledge"), "a consumable is consumed, not acknowledged")
	iap.free()
	return test
