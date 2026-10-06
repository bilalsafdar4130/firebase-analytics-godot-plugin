class_name MSIap
extends MSService
## In-app purchases and subscriptions, reduced to two questions a game can
## actually answer: did this purchase go through, and does this player own that.
##
## GAMES ASK ABOUT ENTITLEMENTS, NOT ABOUT PURCHASES. Google Play Billing hands
## back purchase objects with states, tokens, acknowledgement flags, quantities
## and auto-renewal booleans; StoreKit hands back something else again. None of
## that belongs in a game's menu code. This service reduces all of it to a set
## of strings — `has_entitlement("remove_ads")`, `is_subscribed("premium")` —
## and keeps the store's own vocabulary to itself.
##
## CONSUMABLES ARE NEVER GRANTED TWICE. A consumable is delivered exactly once,
## on the `purchase_completed` signal, and is consumed with the store
## immediately afterwards so it can be bought again. It grants no entitlement:
## an entitlement is a thing you keep, and a hundred coins is a thing you spend.
## The config validator says so out loud if a project tries.
##
## PENDING PURCHASES ARE NOT FAILURES. Cash payments and "ask to buy" family
## approvals can leave a purchase pending for days. The player is told, the game
## grants nothing, and the purchase completes on a later launch through
## [method restore_purchases] — which is why `iap/restore_on_start` defaults on.
##
## A STORE THAT CANNOT GET STUCK. Billing that failed to connect is retried
## (and [method reconnect] asks again on demand); a price list that failed to
## load is asked for again with back-off; a purchase sheet that never answered
## stops blocking the next purchase after [constant PURCHASE_STALE_SECONDS]; a
## consume or acknowledge that did not land is retried through a restore. Each
## of those used to leave a store shut until the game was restarted.
##
## WHAT THIS CANNOT DO. Entitlements are cached on the device
## ([constant CACHE_PATH]) so a player who is off-line still owns what they
## bought, and a device cache is editable by anyone who wants to edit it. For a
## game where that matters, verify purchases on a server: `purchase_completed`
## carries the token to verify with, and `grant_entitlement` /
## `revoke_entitlement` let a backend have the last word. See docs/iap.md.

## Where owned entitlements are remembered between launches. `user://` rather
## than `res://`, because it is written at runtime.
const CACHE_PATH := "user://mobile_services_entitlements.cfg"

## How long a purchase sheet may stay unanswered before a new purchase is
## allowed anyway. Play answers every sheet it opens, but an activity torn down
## underneath it (a phone call, the OS reclaiming memory) can lose the answer,
## and before this limit every later BUY failed with "already in progress" for
## the rest of the session. Generous, because a player reading a payment sheet
## is not on a timer; a late answer still delivers through `purchase_updated`.
const PURCHASE_STALE_SECONDS := 180.0

## Seconds before each automatic retry of a price list that failed to load.
const PRODUCT_RETRY_SECONDS: Array[float] = [5.0, 20.0, 60.0]

## Restores run to finish a consume or acknowledge that did not land, at most
## this many per session, this many seconds after the failure.
const FINISH_RETRY_LIMIT := 3
const FINISH_RETRY_SECONDS := 15.0

signal iap_ready()
signal iap_failed(error: Dictionary)

## Store metadata arrived: localised titles and prices, keyed by logical product
## name. A store page should be built from this, never from hardcoded prices —
## the store shows the player their own currency and this is where it comes
## from.
signal products_loaded(products: Dictionary)
signal products_load_failed(error: Dictionary)
## Products in mobile_services.cfg that the store would not sell, keyed by
## logical name, each with the store's reason: `product_not_found` (no such id
## in the Play Console, or not active), `invalid_product_id`,
## `no_eligible_offer`, or `unknown`. Arrives just before [signal
## products_loaded]. Android only: Play Billing 8+ is what says why.
signal products_unavailable(products: Dictionary)

signal purchase_started(product: String)
## The purchase is real and paid for. Grant here, once.
signal purchase_completed(purchase: Dictionary)
## Awaiting a slow payment method. Grant nothing yet.
signal purchase_pending(purchase: Dictionary)
signal purchase_failed(product: String, error: Dictionary)
signal purchase_cancelled(product: String)
## Everything this account already owns, at start-up or on demand.
signal purchases_restored(products: Array)
## Play could not say what this account owns (off-line, Play busy). Nothing was
## revoked: the answer is all or nothing, and this time it was nothing.
signal restore_failed(error: Dictionary)
## The player paid and was granted, but consuming or acknowledging with the
## store did not land. Not a failed purchase and nothing to show a player: it is
## retried through a restore. Worth logging, because an unacknowledged purchase
## is refunded by Google after three days.
signal purchase_finish_failed(product: String, error: Dictionary)
## The set of entitlements changed. Carries the whole set, sorted, so a menu can
## rebuild from one signal rather than tracking additions and removals.
signal entitlements_changed(entitlements: Array)

## logical name -> store metadata (price, title, description, currency, offers)
var _catalogue := {}
## logical name -> why the store did not return it. See
## [signal products_unavailable].
var _unavailable := {}
## entitlement -> {"product", "expires_at"} — expires_at 0 for a permanent one.
var _entitlements := {}
## Store ids of purchases already delivered, so a restore does not re-grant a
## consumable that was already spent.
var _delivered := {}
var _purchase_in_flight := ""
## `Time.get_ticks_msec()` when [member _purchase_in_flight] was set.
var _purchase_started_ms := 0
## Retries spent this session; see [constant PRODUCT_RETRY_SECONDS] and
## [constant FINISH_RETRY_LIMIT].
var _product_retries := 0
var _product_retry_queued := false
var _finish_retries := 0
var _finish_retry_queued := false


func is_enabled() -> bool:
	return config != null and bool(config.iap["enabled"])


func setup() -> void:
	_load_cache()
	if not is_enabled():
		return
	if not is_available():
		return
	for signal_name in [
		"billing_ready", "billing_failed", "products_loaded",
		"products_load_failed", "purchase_updated", "purchase_failed",
		"purchases_queried", "purchase_consumed", "purchase_acknowledged",
	]:
		native.connect_signal(signal_name, Callable(self, "_on_native_" + signal_name))
	# Optional: only newer Android bridges declare these (products_unfetched
	# from 2.2.0, the other two from 2.3.0), and an iOS or an older plugin
	# without them is not something to warn about.
	var plugin := native.get_object()
	for optional in ["products_unfetched", "purchases_query_failed", "purchase_finish_failed"]:
		if plugin != null and plugin.has_signal(optional):
			native.connect_signal(optional, Callable(self, "_on_native_" + optional))
	native.call_method("initializeBilling", [JSON.stringify(_product_manifest())])


## The products, in the form the native side wants them: store id and type,
## nothing logical. Sent once at start-up; the store needs the full list to
## return prices.
func _product_manifest() -> Array:
	var platform := MSConfig.current_platform()
	var manifest := []
	for name in config.products:
		var product: Dictionary = config.products[name]
		var store_id := str(product.get("%s_id" % platform, ""))
		if store_id.is_empty():
			continue
		manifest.append({"id": store_id, "type": str(product["type"])})
	return manifest


# --- Buying -------------------------------------------------------------

## Starts a purchase for a logical product name.
##
## Returns `{}` when the store sheet was opened, which is NOT the same as a
## completed purchase — wait for [signal purchase_completed]. A game that grants
## on this return value grants on a cancelled purchase too.
##
## `offer_token` selects one of a subscription's offers (an introductory price,
## a free trial) from the `offers` array in the catalogue. Leave it empty for
## the base plan, and for everything that is not a subscription.
func purchase(product_name: String, offer_token: String = "") -> Dictionary:
	var problem := guard("buy %s" % product_name)
	if not problem.is_empty():
		return problem
	var product := config.get_product(product_name)
	if product.is_empty():
		return fail(
			MSError.INVALID_CONFIGURATION,
			"there is no [iap.product.%s] section in mobile_services.cfg" % product_name
		)
	var store_id := config.get_store_id(product_name)
	if store_id.is_empty():
		return fail(
			MSError.INVALID_CONFIGURATION,
			(
				"[iap.product.%s] has no %s_id in mobile_services.cfg"
				% [product_name, MSConfig.current_platform()]
			)
		)
	if not _purchase_in_flight.is_empty():
		var waited := (Time.get_ticks_msec() - _purchase_started_ms) / 1000.0
		if waited < PURCHASE_STALE_SECONDS:
			return fail(
				MSError.NOT_READY,
				"a purchase of %s is already in progress" % _purchase_in_flight
			)
		# Play never answered that sheet. Its answer can still arrive and will
		# still be delivered; it just stops blocking this one.
		log.warn(service_name, (
			"the purchase of %s never answered after %d s; starting %s anyway"
			% [_purchase_in_flight, int(waited), product_name]
		))
	# A second purchase of something the player already owns is refused by the
	# store anyway, with an error most games render as "something went wrong".
	# Saying it here gives the game a chance to show the right thing instead.
	var entitlement := str(product["entitlement"])
	if product["type"] == "non_consumable" and not entitlement.is_empty() \
			and has_entitlement(entitlement):
		return fail(MSError.ALREADY_OWNED, "%s is already owned" % product_name)
	_purchase_in_flight = product_name
	_purchase_started_ms = Time.get_ticks_msec()
	purchase_started.emit(product_name)
	native.call_method("purchase", [store_id, str(product["type"]), offer_token])
	return {}


## Re-reads what this account owns from the store and re-grants it.
##
## Called at start-up when `iap/restore_on_start` is on, which is what makes a
## reinstall or a second device keep a player's purchases. Also what an App
## Store review requires a "Restore purchases" button to call.
func restore_purchases() -> Dictionary:
	var problem := guard("restore purchases")
	if not problem.is_empty():
		return problem
	native.call_method("queryPurchases")
	return {}


## Asks the store for prices and titles again. Done once at start-up
## automatically; worth repeating if a store screen is opened much later.
func refresh_products() -> Dictionary:
	var problem := guard("refresh products")
	if not problem.is_empty():
		return problem
	native.call_method("queryProducts")
	return {}


## Connects to the store again if it is not connected — after a setup that
## gave up, or a connection that dropped — and otherwise re-announces
## [signal iap_ready]. Cheap; meant for a store screen to call as it opens, so a
## player who launched the game off-line can still buy once they are back on.
func reconnect() -> Dictionary:
	var problem := guard("reconnect to the store")
	if not problem.is_empty():
		return problem
	if native.has("reconnect"):
		native.call_method("reconnect")
	else:
		# A bridge from before 2.3.0: initializeBilling is idempotent and
		# answers billing_ready when the connection is already up.
		native.call_method("initializeBilling", [JSON.stringify(_product_manifest())])
	return {}


## The product whose purchase sheet is open, or "" when none is.
func get_purchase_in_flight() -> String:
	return _purchase_in_flight


# --- What the player owns -----------------------------------------------

## The question a game asks. True while the entitlement is granted and, for a
## subscription, not expired.
func has_entitlement(entitlement: String) -> bool:
	var record: Dictionary = _entitlements.get(entitlement, {})
	if record.is_empty():
		return false
	var expires := int(record.get("expires_at", 0))
	if expires > 0 and Time.get_unix_time_from_system() > expires:
		return false
	return true


## True only for an entitlement granted by a subscription — a game that wants
## to say "renews on the 4th" rather than "unlocked" needs to tell them apart.
func is_subscribed(entitlement: String) -> bool:
	var record: Dictionary = _entitlements.get(entitlement, {})
	if record.is_empty():
		return false
	var product := config.get_product(str(record.get("product", "")))
	return product.get("type", "") == "subscription" and has_entitlement(entitlement)


## Every entitlement currently held, sorted. The payload of
## [signal entitlements_changed].
func get_entitlements() -> Array:
	var names := []
	for entitlement in _entitlements:
		if has_entitlement(entitlement):
			names.append(entitlement)
	names.sort()
	return names


## Store metadata for one product: `price` (already localised and formatted by
## the store — show this string, do not build your own), `price_micros`,
## `currency`, `title`, `description`, and `offers` for subscriptions.
##
## Empty until [signal products_loaded]. A store screen built before then shows
## no prices, which is why it is worth waiting for the signal.
func get_product_info(product_name: String) -> Dictionary:
	return _catalogue.get(product_name, {}).duplicate()


func get_catalogue() -> Dictionary:
	return _catalogue.duplicate(true)


## Products the store refused to return, with its reason for each — the answer
## to "why does this BUY button never appear". Empty when everything is on sale,
## and always empty on iOS. See [signal products_unavailable].
func get_unavailable_products() -> Dictionary:
	return _unavailable.duplicate()


## Grants an entitlement without a purchase.
##
## For a server that has verified a receipt, for a promo code redeemed outside
## the store, and for testing. `expires_at` is a Unix timestamp, or 0 for
## something permanent.
func grant_entitlement(entitlement: String, product_name: String = "", expires_at: int = 0) -> void:
	if entitlement.is_empty():
		return
	_entitlements[entitlement] = {"product": product_name, "expires_at": expires_at}
	_save_cache()
	_announce_entitlements()


## Takes one back — a refund, a lapsed subscription a server has noticed, a
## test being reset.
func revoke_entitlement(entitlement: String) -> void:
	if not _entitlements.has(entitlement):
		return
	_entitlements.erase(entitlement)
	_save_cache()
	_announce_entitlements()


# --- Native callbacks ---------------------------------------------------

func _on_native_billing_ready() -> void:
	_started = true
	# A fresh connection gets a fresh set of retries for its price list.
	_product_retries = 0
	log.info(service_name, "billing connected")
	iap_ready.emit()
	refresh_products()
	if bool(config.iap["restore_on_start"]):
		restore_purchases()


func _on_native_billing_failed(code: int, message: String) -> void:
	# A failure reported while the native client says it IS connected is a
	# stale or duplicate answer (2.3.0's two reconnect paths produced a stream of
	# DEVELOPER_ERROR "already in the process of connecting" right after billing
	# connected). Believing it closed a store that was working.
	if _started and bool(native.call_method("isReady", [], false)):
		log.warn(service_name, (
			"ignoring a billing failure (%d: %s): billing is connected" % [code, message]
		))
		return
	_started = false
	# Nothing can answer a sheet on a connection that is not there.
	_purchase_in_flight = ""
	var error := record(MSError.make(
		MSError.BILLING_UNAVAILABLE, message, service_name, code
	))
	iap_failed.emit(error)


func _on_native_products_loaded(products_json: String) -> void:
	_catalogue.clear()
	for entry in parse_array(products_json):
		if not (entry is Dictionary):
			continue
		var product := config.get_product_by_store_id(str(entry.get("id", "")))
		if product.is_empty():
			continue
		# Typed explicitly: `entry` is a Variant out of an untyped Array, so `:=`
		# has nothing to infer from and Godot refuses to compile the file.
		var info: Dictionary = entry.duplicate()
		info["product"] = product["name"]
		info["type"] = product["type"]
		_catalogue[str(product["name"])] = info
		# A product that is on sale now is not unavailable, whatever an earlier
		# query said — a refresh that fetches everything sends no unfetched list.
		_unavailable.erase(str(product["name"]))
	log.info(service_name, "%d product(s) priced by the store" % _catalogue.size())
	products_loaded.emit(get_catalogue())


## Billing 8+ names every product Play would not return, and why. Each one is a
## BUY button that will never appear, so each one is a warning: in a release
## build this is the only place a mistyped product id or a product left
## inactive in the Play Console says so.
func _on_native_products_unfetched(products_json: String) -> void:
	_unavailable.clear()
	for entry in parse_array(products_json):
		if not (entry is Dictionary):
			continue
		var store_id := str(entry.get("id", ""))
		var product := config.get_product_by_store_id(store_id)
		var name := str(product.get("name", store_id))
		var reason := str(entry.get("reason", "unknown"))
		_unavailable[name] = reason
		log.warn(service_name, (
			"the store will not sell %s (%s): %s"
			% [name, reason, unavailable_hint(reason)]
		))
	products_unavailable.emit(get_unavailable_products())


## What to check in the store console for each reason the store gives.
static func unavailable_hint(reason: String) -> String:
	match reason:
		"product_not_found":
			return (
				"no ACTIVE product has this id in the Play Console, or this build "
				+ "is not installed from a Play track"
			)
		"invalid_product_id":
			return "the id is not a valid Play product id; check mobile_services.cfg"
		"no_eligible_offer":
			return "the product exists but has no offer this account may buy"
	return "the store gave no reason"


func _on_native_products_load_failed(code: int, message: String) -> void:
	var error := record(MSError.make(
		_translate(code), message, service_name, code
	))
	products_load_failed.emit(error)
	# A price list that failed to load is a store with no BUY buttons. Off-line
	# at launch is the usual cause, so ask again a few times rather than once.
	if bool(error["recoverable"]) and _product_retries < PRODUCT_RETRY_SECONDS.size():
		var delay: float = PRODUCT_RETRY_SECONDS[_product_retries]
		_product_retries += 1
		if _after(delay, _retry_products, _product_retry_queued):
			_product_retry_queued = true
			log.info(service_name, "asking for prices again in %d s" % int(delay))


func _retry_products() -> void:
	_product_retry_queued = false
	refresh_products()


func _on_native_purchase_updated(purchase_json: String) -> void:
	_handle_purchase(parse_object(purchase_json))


## One purchase, in whatever state the store reports it. The single place a
## purchase turns into a grant — reached both from a live purchase and from the
## restore query, which is why it takes a parsed dictionary rather than JSON.
func _handle_purchase(purchase: Dictionary) -> void:
	if purchase.is_empty():
		return
	var store_id := str(purchase.get("product_id", ""))
	var product := config.get_product_by_store_id(store_id)
	if product.is_empty():
		# A product bought by an older build, or one removed from the config.
		# Not something to grant, and not something to hide either.
		log.warn(service_name, (
			"the store reports a purchase of %s, which is not in mobile_services.cfg"
			% store_id
		))
		return
	var name := str(product["name"])
	if name == _purchase_in_flight:
		_purchase_in_flight = ""

	var state := str(purchase.get("state", "purchased"))
	var enriched := purchase.duplicate()
	enriched["product"] = name
	enriched["type"] = product["type"]
	enriched["entitlement"] = product["entitlement"]
	var info: Dictionary = _catalogue.get(name, {})
	enriched["price"] = float(info.get("price_micros", 0)) / 1000000.0
	enriched["currency"] = str(info.get("currency", ""))
	# ALREADY FINISHED WITH THE STORE IN AN EARLIER SESSION. A purchase the
	# store reports as acknowledged was delivered before -- this is a restore
	# (every launch re-reads what the account owns), not a sale. Games grant on
	# it all the same (it is how a reinstall gets its purchase back); analytics
	# must not count it as revenue again. Consumables are consumed rather than
	# acknowledged, so a consumable is never "restored": one the store still
	# reports was never finished, and is owed.
	enriched["restored"] = bool(purchase.get("acknowledged", false))

	if state == "pending":
		log.info(service_name, "%s is pending payment" % name)
		purchase_pending.emit(enriched)
		return
	if state != "purchased":
		return

	# The store can report the same purchase on every launch until it is
	# acknowledged, and `queryPurchases` reports it deliberately. Deliver once.
	var token := str(purchase.get("token", ""))
	var delivery_key := "%s:%s" % [store_id, token]
	var already_delivered: bool = _delivered.has(delivery_key)
	_delivered[delivery_key] = true

	var entitlement := str(product["entitlement"])
	if not entitlement.is_empty():
		var expires := int(purchase.get("expires_at", 0))
		_entitlements[entitlement] = {"product": name, "expires_at": expires}
		_save_cache()
		_announce_entitlements()

	# Finish with the store. A consumable that is never consumed cannot be
	# bought again; a non-consumable that is never acknowledged is REFUNDED
	# automatically after three days. Both are silent until a player complains.
	if product["type"] == "consumable":
		if bool(config.iap["auto_consume"]):
			native.call_method("consume", [token])
	elif not bool(purchase.get("acknowledged", false)) and bool(config.iap["auto_acknowledge"]):
		native.call_method("acknowledge", [token])

	if already_delivered:
		return
	log.info(service_name, "%s purchased" % name)
	purchase_completed.emit(enriched)


func _on_native_purchase_failed(store_id: String, code: int, message: String) -> void:
	if store_id.is_empty():
		# A bridge from before 2.3.0 (or iOS) reports a consume or acknowledge
		# that did not land here, with no product. Not a purchase that failed.
		_on_native_purchase_finish_failed(store_id, code, message)
		return
	var product := config.get_product_by_store_id(store_id)
	var name := str(product.get("name", store_id))
	if name == _purchase_in_flight or store_id == _purchase_in_flight:
		_purchase_in_flight = ""
	var translated := _translate(code)
	if translated == MSError.USER_CANCELLED:
		log.info(service_name, "%s: the player cancelled" % name)
		purchase_cancelled.emit(name)
		return
	var error := record(MSError.make(translated, message, service_name, code))
	purchase_failed.emit(name, error)
	if translated == MSError.ALREADY_OWNED and is_ready():
		# THE STORE SAYS THEY ALREADY PAID FOR IT, so whatever this device
		# believes is out of date: a consumable whose consume never landed (it
		# can never be bought again until it does), or a one-time product bought
		# before a reinstall and not restored yet. Re-reading what the account
		# owns delivers it through `purchase_completed` and finishes it with the
		# store, which is what the player was trying to get.
		log.info(service_name, "%s is already owned; restoring purchases" % name)
		restore_purchases()


func _on_native_purchases_queried(purchases_json: String) -> void:
	var purchases := parse_array(purchases_json)
	var restored := []
	# A subscription cancelled outside the game (Play's own subscription
	# screen, a lapsed card) simply stops appearing here, so the answer has to
	# be rebuilt from what the store says rather than added to what is cached.
	# Entitlements granted by a server through `grant_entitlement` are kept:
	# they were never the store's to report.
	var store_backed := {}
	for entry in purchases:
		if not (entry is Dictionary):
			continue
		var product := config.get_product_by_store_id(str(entry.get("product_id", "")))
		if product.is_empty():
			continue
		restored.append(str(product["name"]))
		var entitlement := str(product["entitlement"])
		if not entitlement.is_empty():
			store_backed[entitlement] = true
		_handle_purchase(entry)
	var revoked := false
	for entitlement in _entitlements.keys():
		var granted_by: String = str(_entitlements[entitlement].get("product", ""))
		var product := config.get_product(granted_by)
		var from_store: bool = not product.is_empty() and product["type"] != "consumable"
		if from_store and not store_backed.has(entitlement):
			log.info(service_name, "%s is no longer owned; revoking" % entitlement)
			_entitlements.erase(entitlement)
			revoked = true
	if revoked:
		_save_cache()
		_announce_entitlements()
	log.info(service_name, "restored %d purchase(s)" % restored.size())
	purchases_restored.emit(restored)


func _on_native_purchases_query_failed(code: int, message: String) -> void:
	var error := record(MSError.make(_translate(code), message, service_name, code))
	restore_failed.emit(error)


## A consume or acknowledge did not land. The player has what they paid for;
## what is at stake is the store's side (see the signal). A restore re-reads the
## unfinished purchase and finishes it, and the delivery key stops it being
## granted twice in this session.
func _on_native_purchase_finish_failed(store_id: String, code: int, message: String) -> void:
	var product := config.get_product_by_store_id(store_id)
	var name := str(product.get("name", store_id))
	var error := record(MSError.make(_translate(code), message, service_name, code))
	purchase_finish_failed.emit(name, error)
	if _finish_retries < FINISH_RETRY_LIMIT:
		if _after(FINISH_RETRY_SECONDS, _retry_finish, _finish_retry_queued):
			_finish_retries += 1
			_finish_retry_queued = true


func _retry_finish() -> void:
	_finish_retry_queued = false
	restore_purchases()


## Runs `callback` after `seconds`, unless one is already queued. Returns
## whether it was scheduled: a service outside the scene tree (a headless test)
## has no timer to use, and simply does not retry.
func _after(seconds: float, callback: Callable, queued: bool) -> bool:
	if queued or not is_inside_tree():
		return false
	get_tree().create_timer(seconds).timeout.connect(callback)
	return true


func _on_native_purchase_consumed(_token: String, store_id: String) -> void:
	log.debug(service_name, "consumed %s" % store_id)


func _on_native_purchase_acknowledged(_token: String, store_id: String) -> void:
	log.debug(service_name, "acknowledged %s" % store_id)


# --- Entitlement cache --------------------------------------------------

func _announce_entitlements() -> void:
	entitlements_changed.emit(get_entitlements())


func _load_cache() -> void:
	var file := ConfigFile.new()
	if file.load(CACHE_PATH) != OK:
		return
	if not file.has_section("entitlements"):
		return
	for entitlement in file.get_section_keys("entitlements"):
		var value = file.get_value("entitlements", entitlement, {})
		if value is Dictionary:
			_entitlements[entitlement] = value
	log.debug(service_name, "%d entitlement(s) restored from cache" % _entitlements.size())


func _save_cache() -> void:
	var file := ConfigFile.new()
	for entitlement in _entitlements:
		file.set_value("entitlements", entitlement, _entitlements[entitlement])
	var err := file.save(CACHE_PATH)
	if err != OK:
		log.warn(service_name, "could not write the entitlement cache (error %d)" % err)


## Google Play Billing's response codes, translated. The numbers are
## `BillingClient.BillingResponseCode`; the iOS side maps StoreKit's errors onto
## the same set before emitting, so this table serves both.
static func _translate(code: int) -> String:
	match code:
		0: return MSError.OK
		1: return MSError.USER_CANCELLED
		2: return MSError.BILLING_UNAVAILABLE      # service disconnected
		3: return MSError.BILLING_UNAVAILABLE      # Play version too old
		4: return MSError.INVALID_CONFIGURATION    # item unavailable
		5: return MSError.INVALID_CONFIGURATION    # developer error
		6: return MSError.UNKNOWN                  # fatal error
		7: return MSError.ALREADY_OWNED
		8: return MSError.NOT_OWNED
		12: return MSError.NETWORK_ERROR
		-1: return MSError.BILLING_UNAVAILABLE     # service disconnected
		-2: return MSError.UNSUPPORTED             # feature not supported
		-3: return MSError.NETWORK_ERROR           # service timeout
	return MSError.UNKNOWN


func diagnostics() -> Dictionary:
	var report := super.diagnostics()
	report["products_configured"] = config.products.size() if config != null else 0
	report["products_priced"] = _catalogue.size()
	var unavailable := []
	for name in _unavailable:
		unavailable.append("%s: %s" % [name, _unavailable[name]])
	unavailable.sort()
	report["products_unavailable"] = unavailable
	report["entitlements"] = get_entitlements()
	report["purchase_in_flight"] = _purchase_in_flight
	report["product_retries"] = _product_retries
	report["finish_retries"] = _finish_retries
	return report
