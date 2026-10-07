package com.bilalsafdar.godot.mobileservices.billing

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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
import com.android.billingclient.api.UnfetchedProduct
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
 * running. [scheduleReconnect] backs off and retries; without it, a game
 * silently loses the ability to sell anything part-way through a session.
 *
 * ONE CONNECTION ATTEMPT AT A TIME, FROM ONE PLACE. 2.3.0 also switched on
 * Billing 8's automatic service reconnection, so two mechanisms reconnected
 * the same client: starting a connection while one was already CONNECTING is
 * answered with DEVELOPER_ERROR "Client is already in the process of
 * connecting", and each of those answers reached the game as billing failing
 * — a store reading OFFLINE seconds after "billing connected". Automatic
 * reconnection is off again, [connect] only starts from DISCONNECTED, and a
 * failed answer that arrives while the client is connected or connecting is
 * not a failure.
 *
 * A CONNECTION THAT NEVER ANSWERS IS ABANDONED. The same device log shows why
 * the duplicate attempts happened at all: the connection dropped seconds after
 * "billing connected" and the attempt to rebuild it stayed CONNECTING for good.
 * 2.3.1 then waited on it for ever -- [connect] refused to start over while it
 * was CONNECTING, every price query was answered SERVICE_DISCONNECTED, and the
 * store read OFFLINE on a phone that was online. An attempt Play has not
 * answered in [CONNECT_TIMEOUT_MS] is now ended, a new client is built, and
 * the game is told billing failed so its store can say so and ask again.
 *
 * NOTHING IS ASKED OF A CLIENT THAT IS NOT CONNECTED. A query sent to a
 * disconnected client is answered SERVICE_DISCONNECTED, and 2.3.1 followed
 * that answer with an EMPTY catalogue, which wiped prices the game already had.
 * A query now waits for the connection (asking for one), a failed query
 * reports only the failure, and a catalogue is only sent when Play answered.
 *
 * A FAILED SETUP IS RETRIED TOO. The first connection fails for reasons that
 * clear up on their own — no network at launch, Play busy updating, the Play
 * account not signed in yet — and a store that gave up on the first answer
 * stayed shut for the rest of the session. It retries a few times with
 * back-off, and the game can ask again at any time with [reconnect] (opening a
 * store screen is the natural moment).
 *
 * FINISHING A PURCHASE HAS ITS OWN FAILURE SIGNAL. A consume or acknowledge
 * that does not land is not a failed purchase — the player paid and has been
 * granted — so it is reported on `purchase_finish_failed`, never on
 * `purchase_failed`, which a game shows to the player.
 */
class MobileServicesBillingPlugin(godot: Godot) : MobileServicesPlugin(godot) {

	companion object {
		const val PLUGIN_NAME = "MobileServicesBilling"

		/** Play's own reconnect guidance: back off, cap, keep trying. */
		private const val RECONNECT_BASE_MS = 1_000L
		private const val RECONNECT_MAX_MS = 60_000L

		/** How many times a setup that Play ANSWERED with an error is retried
		 * before waiting for the game to call [reconnect]. A disconnect is
		 * always retried; a refusal six times in a row (about a minute) is a
		 * device that will not sell anything until something changes. */
		private const val SETUP_RETRY_LIMIT = 6

		/** How long a connection attempt may stay CONNECTING before it is
		 * given up and a new client tried. A healthy bind answers in well under
		 * a second; one that has not answered in this long never does. */
		private const val CONNECT_TIMEOUT_MS = 15_000L

		/** Play's SERVICE_TIMEOUT code, sent to the game when an attempt is
		 * abandoned. Written out: Play Billing has deprecated the constant. */
		private const val SERVICE_TIMEOUT = -3
	}

	override fun getPluginName(): String = PLUGIN_NAME

	override fun getPluginSignals(): MutableSet<SignalInfo> = mutableSetOf(
		SignalInfo("billing_ready"),
		SignalInfo("billing_failed", Int::class.javaObjectType, String::class.java),
		SignalInfo("products_loaded", String::class.java),
		SignalInfo("products_load_failed", Int::class.javaObjectType, String::class.java),
		SignalInfo("products_unfetched", String::class.java),
		SignalInfo("purchase_updated", String::class.java),
		SignalInfo(
			"purchase_failed",
			String::class.java, Int::class.javaObjectType, String::class.java
		),
		SignalInfo("purchases_queried", String::class.java),
		SignalInfo("purchases_query_failed", Int::class.javaObjectType, String::class.java),
		SignalInfo("purchase_consumed", String::class.java, String::class.java),
		SignalInfo("purchase_acknowledged", String::class.java, String::class.java),
		SignalInfo(
			"purchase_finish_failed",
			String::class.java, Int::class.javaObjectType, String::class.java
		)
	)

	/** Read from the Godot thread by [isReady], written on the UI thread. */
	@Volatile
	private var client: BillingClient? = null
	private val handler = Handler(Looper.getMainLooper())

	/** Bumped for every new client. A listener answers only for the client it
	 * was made for: an abandoned client's late answer is about a connection
	 * nobody is waiting for any more. */
	private var generation = 0

	/** `SystemClock.elapsedRealtime()` when the current attempt started, or 0
	 * when no attempt is outstanding. See [CONNECT_TIMEOUT_MS]. */
	private var connectingSinceMs = 0L

	/** Store id -> type, from mobile_services.cfg. Play needs the type on every
	 * call, and the game only ever says the product name. */
	private val productTypes = HashMap<String, String>()

	/** Store id -> details, so a purchase can be started without a second
	 * round trip and a price can be read back for an analytics event. */
	private val details = HashMap<String, ProductDetails>()

	/** Purchase token -> store id, learned from every purchase this plugin has
	 * seen (a live update or a query), so [consume] and [acknowledge] — which
	 * Play only gives a token to work with — can still report which product a
	 * token belonged to on `purchase_consumed`/`purchase_acknowledged`. */
	private val tokenStoreIds = HashMap<String, String>()

	private var reconnectDelayMs = RECONNECT_BASE_MS
	private var setupFailures = 0
	private var reconnectQueued = false
	private var purchaseInFlight: String = ""

	private val reconnectTask = Runnable {
		safely("reconnect") {
			reconnectQueued = false
			if (client?.isReady != true) connect()
		}
	}

	private val connectTimeoutTask = Runnable {
		safely("connectTimeout") { onConnectTimeout() }
	}

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
		val current = client
		if (current != null && current.connectionState != BillingClient.ConnectionState.CLOSED) {
			// Idempotent, like every other initialize in this SDK.
			if (current.isReady) signal("billing_ready") else connect()
			return@onUi
		}
		newClient() ?: return@onUi
		connect()
	}

	/**
	 * Builds a new client and makes it the current one, closing the old one.
	 *
	 * Only ever replaces a client that is CLOSED or whose attempt to connect
	 * Play never answered -- neither can have a purchase sheet open.
	 */
	private fun newClient(): BillingClient? {
		val activity = getActivity() ?: return null
		val old = client
		generation += 1
		connectingSinceMs = 0L
		handler.removeCallbacks(connectTimeoutTask)
		if (old != null) {
			safely("endConnection") { old.endConnection() }
		}
		val fresh = BillingClient.newBuilder(activity)
			.setListener { result, purchases -> onPurchasesUpdated(result, purchases) }
			// Mandatory since Billing 7. Both flavours, because a game with a
			// subscription and a coin pack has both kinds of pending purchase.
			.enablePendingPurchases(
				PendingPurchasesParams.newBuilder()
					.enableOneTimeProducts()
					.build()
			)
			// NOT .enableAutoServiceReconnection(): see "ONE CONNECTION ATTEMPT
			// AT A TIME" above. Reconnecting is this class's job alone.
			.build()
		client = fresh
		return fresh
	}

	/**
	 * Connects if a connection is needed, and never starts a second attempt
	 * while one is under way.
	 *
	 * CONNECTED needs nothing. DISCONNECTED starts an attempt. CLOSED cannot be
	 * reused, so it gets a new client. CONNECTING is left to answer by itself
	 * -- unless it has been CONNECTING for [CONNECT_TIMEOUT_MS], which is an
	 * attempt Play is never going to answer, and that gets a new client too.
	 */
	private fun connect() {
		var current = client ?: newClient() ?: return
		when (current.connectionState) {
			BillingClient.ConnectionState.CONNECTED -> return
			BillingClient.ConnectionState.CLOSED -> current = newClient() ?: return
			BillingClient.ConnectionState.CONNECTING -> {
				if (connectingSinceMs == 0L) {
					// Not an attempt this class started: give it the same time.
					armConnectTimeout()
					return
				}
				val waited = SystemClock.elapsedRealtime() - connectingSinceMs
				if (waited < CONNECT_TIMEOUT_MS) return
				logWarn("billing has been connecting for ${waited}ms; starting again with a new client")
				current = newClient() ?: return
			}
		}
		armConnectTimeout()
		current.startConnection(listenerFor(generation))
	}

	private fun armConnectTimeout() {
		connectingSinceMs = SystemClock.elapsedRealtime()
		handler.removeCallbacks(connectTimeoutTask)
		handler.postDelayed(connectTimeoutTask, CONNECT_TIMEOUT_MS)
	}

	private fun settleConnectTimeout() {
		connectingSinceMs = 0L
		handler.removeCallbacks(connectTimeoutTask)
	}

	/** Play has not answered the current attempt in [CONNECT_TIMEOUT_MS]. */
	private fun onConnectTimeout() {
		val current = client ?: return
		if (current.isReady ||
			current.connectionState != BillingClient.ConnectionState.CONNECTING
		) {
			return
		}
		logWarn("billing did not connect in ${CONNECT_TIMEOUT_MS}ms; abandoning the attempt")
		newClient() ?: return
		setupFailed(
			SERVICE_TIMEOUT,
			"Google Play did not answer the billing connection in ${CONNECT_TIMEOUT_MS / 1000} s"
		)
	}

	/** Reports a setup that did not connect, and retries it with back-off. */
	private fun setupFailed(code: Int, message: String) {
		setupFailures += 1
		signal("billing_failed", code, message)
		if (setupFailures < SETUP_RETRY_LIMIT) {
			logWarn(
				"billing setup failed ($code); retry " +
					"$setupFailures of ${SETUP_RETRY_LIMIT - 1} in ${reconnectDelayMs}ms"
			)
			scheduleReconnect()
		} else {
			logWarn("billing setup failed ($code); waiting for reconnect()")
		}
	}

	/** The listener for one client. An answer for any other client is ignored. */
	private fun listenerFor(owner: Int) = object : BillingClientStateListener {
		override fun onBillingSetupFinished(result: BillingResult) = safely("onBillingSetupFinished") {
			if (owner != generation) {
				logWarn("ignoring a setup answer (${result.responseCode}) for a replaced client")
				return@safely
			}
			val current = client
			if (result.responseCode == BillingClient.BillingResponseCode.OK) {
				settleConnectTimeout()
				reconnectDelayMs = RECONNECT_BASE_MS
				setupFailures = 0
				clearFailure()
				logInfo("billing connected")
				signal("billing_ready")
			} else if (current != null && (
					current.isReady ||
						current.connectionState == BillingClient.ConnectionState.CONNECTING
				)) {
				// A late or duplicate answer: the client is connected, or an
				// attempt is on its way and will answer itself (the timeout
				// bounds how long that is believed). Telling the game that
				// billing failed would close a working store.
				logWarn(
					"ignoring a setup answer (${result.responseCode}: " +
						"${result.debugMessage}); the client is connected or connecting"
				)
			} else {
				settleConnectTimeout()
				setupFailed(result.responseCode, result.debugMessage)
			}
		}

		override fun onBillingServiceDisconnected() = safely("onBillingServiceDisconnected") {
			if (owner != generation) return@safely
			// Not an error to report to the game: Play updating itself
			// disconnects every bound client on the device. Reconnect
			// quietly, and only tell the game if it never comes back.
			logWarn("billing disconnected; reconnecting in ${reconnectDelayMs}ms")
			scheduleReconnect()
		}
	}

	private fun scheduleReconnect() {
		if (reconnectQueued) return
		reconnectQueued = true
		handler.postDelayed(reconnectTask, reconnectDelayMs)
		reconnectDelayMs = (reconnectDelayMs * 2).coerceAtMost(RECONNECT_MAX_MS)
	}

	/** Asks for a connection from a Play callback, which may not be on the UI
	 * thread. */
	private fun connectSoon() {
		handler.post { safely("connect") { connect() } }
	}

	/**
	 * Tries to connect again now, whatever happened before.
	 *
	 * For the game to call when it is about to need the store — a store screen
	 * opening — after a setup that gave up. Already connected: answers
	 * `billing_ready` again, so the caller has one signal to wait for either way.
	 */
	@UsedByGodot
	fun reconnect() = onUi("reconnect") {
		if (client?.isReady == true) {
			signal("billing_ready")
			return@onUi
		}
		setupFailures = 0
		reconnectDelayMs = RECONNECT_BASE_MS
		handler.removeCallbacks(reconnectTask)
		reconnectQueued = false
		connect()
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
		val current = client
		if (current == null || !current.isReady) {
			// Play would answer SERVICE_DISCONNECTED. Say so, and get the
			// connection going: `billing_ready` asks for prices again.
			signal(
				"products_load_failed", BillingClient.BillingResponseCode.SERVICE_DISCONNECTED,
				"billing is not connected yet; connecting"
			)
			connect()
			return@onUi
		}
		val requests = listOf(BillingClient.ProductType.INAPP, BillingClient.ProductType.SUBS)
			.map { type -> type to productTypes.filterValues { it == type }.keys }
			.filter { it.second.isNotEmpty() }
		if (requests.isEmpty()) {
			finishCatalogue(emptyList(), emptyList())
			return@onUi
		}
		val collected = ArrayList<JSONObject>()
		val unfetched = ArrayList<JSONObject>()
		var failure: BillingResult? = null
		var answered = 0
		// Counted before the first query, so an answer that arrives at once
		// cannot finish the catalogue while the other query is still out.
		var outstanding = requests.size
		for ((type, ids) in requests) {
			val products = ids.map { id ->
				QueryProductDetailsParams.Product.newBuilder()
					.setProductId(id)
					.setProductType(type)
					.build()
			}
			// Billing 8+: the listener receives a QueryProductDetailsResult, not a
			// bare list, and says per product why Play could NOT return one.
			current.queryProductDetailsAsync(
				QueryProductDetailsParams.newBuilder().setProductList(products).build()
			) { result, queried ->
				safely("queryProducts($type)") {
					if (result.responseCode == BillingClient.BillingResponseCode.OK) {
						answered += 1
						for (item in queried.productDetailsList) {
							details[item.productId] = item
							collected.add(describe(item))
						}
						for (missing in queried.unfetchedProductList) {
							unfetched.add(
								Json.obj(
									"id" to missing.productId,
									"reason" to unfetchedReason(missing.statusCode)
								)
							)
						}
					} else if (failure == null) {
						failure = result
					}
					outstanding -= 1
					if (outstanding == 0) {
						val failed = failure
						if (failed != null) {
							signal("products_load_failed", failed.responseCode, failed.debugMessage)
							if (failed.responseCode == BillingClient.BillingResponseCode.SERVICE_DISCONNECTED) {
								connectSoon()
							}
						}
						// An empty list here would read as "Play sells nothing"
						// and wipe the prices the game already has. Only an
						// answer from Play is a catalogue.
						if (answered > 0) {
							finishCatalogue(collected, unfetched)
						}
					}
				}
			}
		}
	}

	/**
	 * Reports the catalogue, and before it every product Play would not sell.
	 * Only ever called with an answer Play actually gave: see [queryProducts].
	 *
	 * THE UNFETCHED LIST IS THE ANSWER TO "MY BUY BUTTON NEVER APPEARS". A
	 * product id that does not match the Play Console, a product left inactive,
	 * or one with no offer this player may buy all used to vanish silently from
	 * the catalogue. Play now says which and why, so the game's diagnostics can
	 * too. Sent first, so the GDScript side knows it when `products_loaded`
	 * arrives.
	 */
	private fun finishCatalogue(collected: List<JSONObject>, unfetched: List<JSONObject>) {
		if (unfetched.isNotEmpty()) {
			signal("products_unfetched", Json.array(unfetched))
		}
		signal("products_loaded", Json.array(collected))
	}

	private fun unfetchedReason(code: Int): String = when (code) {
		UnfetchedProduct.StatusCode.PRODUCT_NOT_FOUND -> "product_not_found"
		UnfetchedProduct.StatusCode.INVALID_PRODUCT_ID_FORMAT -> "invalid_product_id"
		UnfetchedProduct.StatusCode.NO_ELIGIBLE_OFFER -> "no_eligible_offer"
		else -> "unknown"
	}

	/**
	 * The purchase option a one-time product is sold through.
	 *
	 * Billing 8 gave one-time products several purchase options and offers.
	 * `oneTimePurchaseOfferDetails` is the one the Play Console marks backwards
	 * compatible, and is null when none is -- which, read alone, would show a
	 * product Play is happily selling as having no price. The first listed offer
	 * is the fallback, and [purchase] buys exactly what this showed.
	 */
	private fun oneTimeOffer(product: ProductDetails): ProductDetails.OneTimePurchaseOfferDetails? =
		product.oneTimePurchaseOfferDetails
			?: product.oneTimePurchaseOfferDetailsList?.firstOrNull()

	/**
	 * One product as the GDScript side wants it.
	 *
	 * `formattedPrice` is Play's own localised string — "£2.99", "¥300" — and is
	 * what a store screen must show. Building a price from `priceAmountMicros`
	 * and a currency code gets the symbol, the separator or the position wrong in
	 * some locale, and the store screen is where that is least forgivable.
	 */
	private fun describe(product: ProductDetails): JSONObject {
		val oneTime = oneTimeOffer(product)
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
			if (current == null || activity == null || !current.isReady) {
				signal(
					"purchase_failed", storeId,
					BillingClient.BillingResponseCode.SERVICE_DISCONNECTED,
					"billing is not connected; connecting"
				)
				connect()
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
			// A subscription REQUIRES an offer token. Getting this wrong is a
			// DEVELOPER_ERROR with no explanation, so pick the base plan when the
			// game did not choose.
			//
			// A one-time product takes one only since Billing 8, to pick one of
			// several purchase options. Left out, Play sells the backwards-
			// compatible option -- so a token is only set when the game chose an
			// offer, or when there is no such option and [describe] priced the
			// first listed one instead.
			if (productType != "subscription") {
				val token = offerToken.ifEmpty {
					if (product.oneTimePurchaseOfferDetails != null) ""
					else oneTimeOffer(product)?.offerToken.orEmpty()
				}
				if (token.isNotEmpty()) {
					builder.setOfferToken(token)
				}
			} else {
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
				signal("purchase_failed", product, result.responseCode, failureMessage(result))
				return@safely
			}
			purchaseInFlight = ""
			for (purchase in purchases.orEmpty()) {
				signal("purchase_updated", describe(purchase))
			}
		}
	}

	/**
	 * Play's debug message, led by the Billing 8 sub-response code when there
	 * is one -- the only place "the card was declined for insufficient funds"
	 * is distinguishable from any other ERROR.
	 */
	private fun failureMessage(result: BillingResult): String {
		val reason = when (result.onPurchasesUpdatedSubResponseCode) {
			BillingClient.OnPurchasesUpdatedSubResponseCode.PAYMENT_DECLINED_DUE_TO_INSUFFICIENT_FUNDS ->
				"payment declined: insufficient funds"
			BillingClient.OnPurchasesUpdatedSubResponseCode.USER_INELIGIBLE ->
				"this account is not eligible for the offer"
			else -> ""
		}
		val debug = result.debugMessage.orEmpty()
		return when {
			reason.isEmpty() -> debug
			debug.isEmpty() -> reason
			else -> "$reason ($debug)"
		}
	}

	/**
	 * Everything this account currently owns.
	 *
	 * This is what makes a reinstall or a second device keep a player's
	 * purchases, and what the App Store's "Restore purchases" equivalent calls.
	 * Two queries again, for the reason in [queryProducts].
	 *
	 * ALL OR NOTHING. The GDScript side treats the answer as the complete list
	 * of what the account owns and revokes anything missing from it, so a list
	 * with one half missing (a query that timed out) would take a paying
	 * player's purchase away. If either query fails, `purchases_query_failed`
	 * is sent instead and nothing is revoked.
	 */
	@UsedByGodot
	fun queryPurchases() = onUi("queryPurchases") {
		val current = client
		if (current == null || !current.isReady) {
			// Nothing is revoked on a failed restore, and `billing_ready`
			// restores again once connected.
			signal(
				"purchases_query_failed", BillingClient.BillingResponseCode.SERVICE_DISCONNECTED,
				"billing is not connected yet; connecting"
			)
			connect()
			return@onUi
		}
		val types = listOf(BillingClient.ProductType.INAPP, BillingClient.ProductType.SUBS)
			.filter { type -> productTypes.any { it.value == type } }
		if (types.isEmpty()) {
			signal("purchases_queried", Json.array(emptyList()))
			return@onUi
		}
		val collected = ArrayList<JSONObject>()
		var failure: BillingResult? = null
		// Counted before the first query, for the reason in [queryProducts]:
		// an early answer must not report half of what the account owns.
		var outstanding = types.size
		for (type in types) {
			current.queryPurchasesAsync(
				QueryPurchasesParams.newBuilder().setProductType(type).build()
			) { result, purchases ->
				safely("queryPurchases($type)") {
					if (result.responseCode == BillingClient.BillingResponseCode.OK) {
						for (purchase in purchases) {
							collected.add(JSONObject(describe(purchase)))
						}
					} else if (failure == null) {
						failure = result
					}
					outstanding -= 1
					if (outstanding == 0) {
						val failed = failure
						if (failed != null) {
							signal("purchases_query_failed", failed.responseCode, failed.debugMessage)
							if (failed.responseCode == BillingClient.BillingResponseCode.SERVICE_DISCONNECTED) {
								connectSoon()
							}
						} else {
							signal("purchases_queried", Json.array(collected))
						}
					}
				}
			}
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
					signal("purchase_consumed", token, tokenStoreIds[token] ?: "")
				} else {
					// Worth reporting: an unconsumed consumable cannot be bought
					// again, and the player's next attempt fails with a message
					// about already owning it. Not on `purchase_failed`: the
					// player paid and was granted, so there is nothing to show
					// them. The GDScript side retries it through a restore.
					signal(
						"purchase_finish_failed", tokenStoreIds[token] ?: "", result.responseCode,
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
					signal("purchase_acknowledged", purchaseToken, tokenStoreIds[purchaseToken] ?: "")
				} else {
					// The expensive one: Play refunds an unacknowledged purchase
					// after three days, and the player keeps whatever the game
					// granted. Retried through a restore, like a consume.
					signal(
						"purchase_finish_failed", tokenStoreIds[purchaseToken] ?: "",
						result.responseCode, "could not acknowledge: ${result.debugMessage}"
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
		val storeId = purchase.products.firstOrNull().orEmpty()
		if (storeId.isNotEmpty()) {
			tokenStoreIds[purchase.purchaseToken] = storeId
		}
		return Json.string(
			"product_id" to storeId,
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
			reconnectQueued = false
			connectingSinceMs = 0L
			generation += 1
			client?.endConnection()
			client = null
		}
		super.onMainDestroy()
	}
}
