package com.bilalsafdar.godot.mobileservices.billing

import android.os.Handler
import android.os.Looper
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ConsumeParams
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.bilalsafdar.godot.mobileservices.core.Json
import com.bilalsafdar.godot.mobileservices.core.MobileServicesPlugin
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONObject

/**
 * Google Play Billing, reduced to what a small game actually needs.
 *
 * THE THREE MISTAKES THIS CLASS EXISTS TO PREVENT, all of them silent:
 *
 * 1. AN UNACKNOWLEDGED PURCHASE IS REFUNDED BY GOOGLE after three days. The
 *    player paid, the game granted, and then the money goes back and the
 *    entitlement stays. The GDScript side acknowledges on delivery; this class
 *    exposes the call and reports whether it landed.
 *
 * 2. AN UNCONSUMED CONSUMABLE CAN NEVER BE BOUGHT AGAIN. Play refuses the second
 *    purchase with ITEM_ALREADY_OWNED, which most games render as "something
 *    went wrong".
 *
 * 3. A PENDING PURCHASE IS NOT A FAILURE. Cash payments and family approval can
 *    leave one pending for days. `enablePendingPurchases` is mandatory in
 *    Billing 7 precisely so an app cannot pretend they do not exist, and the
 *    state travels through to GDScript rather than being flattened.
 *
 * THE CONNECTION DROPS AND MUST BE REBUILT. Play's service is a bound service
 * that goes away when Play updates itself — which happens while games are
 * running. [reconnect] backs off and retries; without it, a game silently loses
 * the ability to sell anything part-way through a session.
 */
class MobileServicesBillingPlugin(godot: Godot) : MobileServicesPlugin(godot) {

	companion object {
		const val PLUGIN_NAME = "MobileServicesBilling"

		/** Play's own reconnect guidance: back off, cap, keep trying. */
		private const val RECONNECT_BASE_MS = 1_000L
		private const val RECONNECT_MAX_MS = 60_000L
	}

	override fun getPluginName(): String = PLUGIN_NAME

	override fun getPluginSignals(): MutableSet<SignalInfo> = mutableSetOf(
		SignalInfo("billing_ready"),
		SignalInfo("billing_failed", Int::class.javaObjectType, String::class.java),
		SignalInfo("products_loaded", String::class.java),
		SignalInfo("products_load_failed", Int::class.javaObjectType, String::class.java),
		SignalInfo("purchase_updated", String::class.java),
		SignalInfo(
			"purchase_failed",
			String::class.java, Int::class.javaObjectType, String::class.java
		),
		SignalInfo("purchases_queried", String::class.java),
		SignalInfo("purchase_consumed", String::class.java, String::class.java),
		SignalInfo("purchase_acknowledged", String::class.java, String::class.java)
	)

	private var client: BillingClient? = null
	private val handler = Handler(Looper.getMainLooper())

	/** Store id -> type, from mobile_services.cfg. Play needs the type on every
	 * call, and the game only ever says the product name. */
	private val productTypes = HashMap<String, String>()

	/** Store id -> details, so a purchase can be started without a second
	 * round trip and a price can be read back for an analytics event. */
	private val details = HashMap<String, ProductDetails>()

	private var reconnectDelayMs = RECONNECT_BASE_MS
	private var purchaseInFlight: String = ""

	@UsedByGodot
	fun initializeBilling(productsJson: String) = onUi("initializeBilling") {
		productTypes.clear()
		for (entry in Json.toList(productsJson)) {
			val id = entry["id"]?.toString().orEmpty()
			val type = entry["type"]?.toString().orEmpty()
			if (id.isNotEmpty()) {
				productTypes[id] = playType(type)
			}
		}
		if (client != null) {
			// Idempotent, like every other initialize in this SDK.
			if (client?.isReady == true) signal("billing_ready")
			return@onUi
		}
		val activity = getActivity() ?: return@onUi
		client = BillingClient.newBuilder(activity)
			.setListener { result, purchases -> onPurchasesUpdated(result, purchases) }
			// Mandatory in Billing 7. Both flavours, because a game with a
			// subscription and a coin pack has both kinds of pending purchase.
			.enablePendingPurchases(
				PendingPurchasesParams.newBuilder()
					.enableOneTimeProducts()
					.build()
			)
			.build()
		connect()
	}

	private fun connect() {
		val current = client ?: return
		current.startConnection(object : BillingClientStateListener {
			override fun onBillingSetupFinished(result: BillingResult) {
				if (result.responseCode == BillingClient.BillingResponseCode.OK) {
					reconnectDelayMs = RECONNECT_BASE_MS
					clearFailure()
					logInfo("billing connected")
					signal("billing_ready")
				} else {
					signal("billing_failed", result.responseCode, result.debugMessage)
				}
			}

			override fun onBillingServiceDisconnected() {
				// Not an error to report to the game: Play updating itself
				// disconnects every bound client on the device. Reconnect
				// quietly, and only tell the game if it never comes back.
				logWarn("billing disconnected; reconnecting in ${reconnectDelayMs}ms")
				reconnect()
			}
		})
	}

	private fun reconnect() {
		handler.postDelayed({ safely("reconnect") { connect() } }, reconnectDelayMs)
		reconnectDelayMs = (reconnectDelayMs * 2).coerceAtMost(RECONNECT_MAX_MS)
	}

	@UsedByGodot
	fun isReady(): Boolean = client?.isReady == true

	@UsedByGodot
	fun lastError(): String = lastFailure

	// --- Catalogue ------------------------------------------------------

	/**
	 * Asks Play for prices and titles.
	 *
	 * TWO QUERIES, NOT ONE. `queryProductDetailsAsync` takes a single product
	 * type per call, so one-time products and subscriptions have to be asked for
	 * separately and the results merged — a detail that has caught out every
	 * billing integration at least once, because asking for a subscription as an
	 * INAPP product simply returns nothing.
	 */
	@UsedByGodot
	fun queryProducts() = onUi("queryProducts") {
		val current = client ?: return@onUi
		val collected = ArrayList<JSONObject>()
		var outstanding = 0
		for (type in listOf(BillingClient.ProductType.INAPP, BillingClient.ProductType.SUBS)) {
			val ids = productTypes.filterValues { it == type }.keys
			if (ids.isEmpty()) continue
			outstanding += 1
			val products = ids.map { id ->
				QueryProductDetailsParams.Product.newBuilder()
					.setProductId(id)
					.setProductType(type)
					.build()
			}
			current.queryProductDetailsAsync(
				QueryProductDetailsParams.newBuilder().setProductList(products).build()
			) { result, list ->
				safely("queryProducts($type)") {
					if (result.responseCode == BillingClient.BillingResponseCode.OK) {
						for (item in list) {
							details[item.productId] = item
							collected.add(describe(item))
						}
					} else {
						signal("products_load_failed", result.responseCode, result.debugMessage)
					}
					outstanding -= 1
					if (outstanding == 0) {
						signal("products_loaded", Json.array(collected))
					}
				}
			}
		}
		if (outstanding == 0) {
			signal("products_loaded", Json.array(collected))
		}
	}

	/**
	 * One product as the GDScript side wants it.
	 *
	 * `formattedPrice` is Play's own localised string — "£2.99", "¥300" — and is
	 * what a store screen must show. Building a price from `priceAmountMicros`
	 * and a currency code gets the symbol, the separator or the position wrong in
	 * some locale, and the store screen is where that is least forgivable.
	 */
	private fun describe(product: ProductDetails): JSONObject {
		val oneTime = product.oneTimePurchaseOfferDetails
		val json = Json.obj(
			"id" to product.productId,
			"title" to product.title,
			"name" to product.name,
			"description" to product.description,
			"price" to (oneTime?.formattedPrice ?: ""),
			"price_micros" to (oneTime?.priceAmountMicros ?: 0L),
			"currency" to (oneTime?.priceCurrencyCode ?: "")
		)
		val offers = org.json.JSONArray()
		for (offer in product.subscriptionOfferDetails.orEmpty()) {
			// The FIRST pricing phase is what the player is charged now — a free
			// trial or an introductory price if there is one, the base plan
			// otherwise. That is the figure a store screen should lead with.
			val phase = offer.pricingPhases.pricingPhaseList.firstOrNull()
			offers.put(
				Json.obj(
					"offer_token" to offer.offerToken,
					"base_plan_id" to offer.basePlanId,
					"offer_id" to (offer.offerId ?: ""),
					"price" to (phase?.formattedPrice ?: ""),
					"price_micros" to (phase?.priceAmountMicros ?: 0L),
					"currency" to (phase?.priceCurrencyCode ?: ""),
					"billing_period" to (phase?.billingPeriod ?: "")
				)
			)
		}
		if (offers.length() > 0) {
			json.put("offers", offers)
			// A subscription has no one-time price; surface the first offer's so
			// a store screen has something to show without special-casing.
			val first = offers.getJSONObject(0)
			json.put("price", first.optString("price"))
			json.put("price_micros", first.optLong("price_micros"))
			json.put("currency", first.optString("currency"))
		}
		return json
	}

	// --- Buying ---------------------------------------------------------

	@UsedByGodot
	fun purchase(storeId: String, productType: String, offerToken: String) =
		onUi("purchase($storeId)") {
			val current = client
			val activity = getActivity()
			if (current == null || activity == null) {
				signal("purchase_failed", storeId, -1, "billing is not connected")
				return@onUi
			}
			val product = details[storeId]
			if (product == null) {
				signal(
					"purchase_failed", storeId, 4,
					"Play does not know $storeId. Check the id in mobile_services.cfg " +
						"matches the Play Console, that the product is ACTIVE, and that " +
						"this build is signed with the same key as an uploaded release."
				)
				return@onUi
			}
			val builder = BillingFlowParams.ProductDetailsParams.newBuilder()
				.setProductDetails(product)
			// A subscription REQUIRES an offer token; a one-time product must not
			// have one. Getting this wrong is a DEVELOPER_ERROR with no
			// explanation, so pick the base plan when the game did not choose.
			if (productType == "subscription") {
				val token = offerToken.ifEmpty {
					product.subscriptionOfferDetails?.firstOrNull()?.offerToken.orEmpty()
				}
				if (token.isEmpty()) {
					signal(
						"purchase_failed", storeId, 5,
						"$storeId is a subscription with no offer. Add a base plan in " +
							"the Play Console and make sure it is active."
					)
					return@onUi
				}
				builder.setOfferToken(token)
			}
			purchaseInFlight = storeId
			val result = current.launchBillingFlow(
				activity,
				BillingFlowParams.newBuilder()
					.setProductDetailsParamsList(listOf(builder.build()))
					.build()
			)
			if (result.responseCode != BillingClient.BillingResponseCode.OK) {
				purchaseInFlight = ""
				signal("purchase_failed", storeId, result.responseCode, result.debugMessage)
			}
		}

	/**
	 * Play's answer to a purchase attempt, and to anything bought outside the
	 * game — a promo code redeemed in the Play app arrives here too.
	 */
	private fun onPurchasesUpdated(result: BillingResult, purchases: List<Purchase>?) {
		safely("onPurchasesUpdated") {
			if (result.responseCode != BillingClient.BillingResponseCode.OK) {
				val product = purchaseInFlight
				purchaseInFlight = ""
				signal("purchase_failed", product, result.responseCode, result.debugMessage)
				return@safely
			}
			purchaseInFlight = ""
			for (purchase in purchases.orEmpty()) {
				signal("purchase_updated", describe(purchase))
			}
		}
	}

	/**
	 * Everything this account currently owns.
	 *
	 * This is what makes a reinstall or a second device keep a player's
	 * purchases, and what the App Store's "Restore purchases" equivalent calls.
	 * Two queries again, for the reason in [queryProducts].
	 */
	@UsedByGodot
	fun queryPurchases() = onUi("queryPurchases") {
		val current = client ?: return@onUi
		val collected = ArrayList<JSONObject>()
		var outstanding = 0
		for (type in listOf(BillingClient.ProductType.INAPP, BillingClient.ProductType.SUBS)) {
			if (productTypes.none { it.value == type }) continue
			outstanding += 1
			current.queryPurchasesAsync(
				QueryPurchasesParams.newBuilder().setProductType(type).build()
			) { result, purchases ->
				safely("queryPurchases($type)") {
					if (result.responseCode == BillingClient.BillingResponseCode.OK) {
						for (purchase in purchases) {
							collected.add(JSONObject(describe(purchase)))
						}
					}
					outstanding -= 1
					if (outstanding == 0) {
						signal("purchases_queried", Json.array(collected))
					}
				}
			}
		}
		if (outstanding == 0) {
			signal("purchases_queried", Json.array(collected))
		}
	}

	@UsedByGodot
	fun consume(purchaseToken: String) = onUi("consume") {
		val current = client ?: return@onUi
		current.consumeAsync(
			ConsumeParams.newBuilder().setPurchaseToken(purchaseToken).build()
		) { result, token ->
			safely("consume") {
				if (result.responseCode == BillingClient.BillingResponseCode.OK) {
					signal("purchase_consumed", token, "")
				} else {
					// Worth reporting: an unconsumed consumable cannot be bought
					// again, and the player's next attempt fails with a message
					// about already owning it.
					signal(
						"purchase_failed", "", result.responseCode,
						"could not consume: ${result.debugMessage}"
					)
				}
			}
		}
	}

	@UsedByGodot
	fun acknowledge(purchaseToken: String) = onUi("acknowledge") {
		val current = client ?: return@onUi
		current.acknowledgePurchase(
			AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchaseToken).build()
		) { result ->
			safely("acknowledge") {
				if (result.responseCode == BillingClient.BillingResponseCode.OK) {
					signal("purchase_acknowledged", purchaseToken, "")
				} else {
					// The expensive one: Play refunds an unacknowledged purchase
					// after three days, and the player keeps whatever the game
					// granted.
					signal(
						"purchase_failed", "", result.responseCode,
						"could not acknowledge: ${result.debugMessage}"
					)
				}
			}
		}
	}

	/**
	 * One purchase as JSON.
	 *
	 * `token` is in here on purpose: a game with a server verifies it there, and
	 * that is the only way to be sure a purchase is real. The GDScript side
	 * never logs it — see `MSLog.redact` — and neither should a game.
	 */
	private fun describe(purchase: Purchase): String {
		val state = when (purchase.purchaseState) {
			Purchase.PurchaseState.PURCHASED -> "purchased"
			Purchase.PurchaseState.PENDING -> "pending"
			else -> "unspecified"
		}
		return Json.string(
			"product_id" to purchase.products.firstOrNull().orEmpty(),
			"state" to state,
			"token" to purchase.purchaseToken,
			"order_id" to (purchase.orderId ?: ""),
			"quantity" to purchase.quantity,
			"acknowledged" to purchase.isAcknowledged,
			"auto_renewing" to purchase.isAutoRenewing,
			"purchase_time" to purchase.purchaseTime
		)
	}

	private fun playType(type: String): String =
		if (type == "subscription") BillingClient.ProductType.SUBS
		else BillingClient.ProductType.INAPP

	/** Play's client holds a bound service connection; leaving it open across an
	 * activity teardown leaks it and logs a warning on every subsequent launch. */
	override fun onMainDestroy() {
		safely("onMainDestroy") {
			handler.removeCallbacksAndMessages(null)
			client?.endConnection()
			client = null
		}
		super.onMainDestroy()
	}
}
