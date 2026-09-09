package com.bilalsafdar.godot.mobileservices.ads

import com.bilalsafdar.godot.mobileservices.core.Json
import com.bilalsafdar.godot.mobileservices.core.MobileServicesPlugin
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot

/**
 * The Godot singleton behind `MobileServices.ads`.
 *
 * ALL IT DOES IS PICK A PROVIDER AND MARSHAL. The ad logic is in [AdMobProvider]
 * and [AppLovinProvider]; the placement vocabulary is in GDScript; this class is
 * the seam. Adding a network means one more branch in [buildProvider] and one
 * more file — nothing here, nothing in GDScript, nothing in any game.
 *
 * EVERY SDK CALL GOES THROUGH `onUi`. Godot invokes plugin methods on the Godot
 * thread; AdMob and AppLovin both require the main thread and misbehave in
 * different ways when they do not get it — AdMob throws, AppLovin fails quietly
 * some time later. Callbacks come back on the main thread and are emitted
 * straight to Godot, which marshals them onto the Godot thread itself.
 */
class MobileServicesAdsPlugin(godot: Godot) : MobileServicesPlugin(godot) {

	companion object {
		const val PLUGIN_NAME = "MobileServicesAds"

		private const val ADMOB_CLASS = "com.google.android.gms.ads.MobileAds"
		private const val APPLOVIN_CLASS = "com.applovin.sdk.AppLovinSdk"
	}

	override fun getPluginName(): String = PLUGIN_NAME

	override fun getPluginSignals(): MutableSet<SignalInfo> = mutableSetOf(
		SignalInfo("ads_initialized", String::class.java),
		SignalInfo("ads_initialization_failed", String::class.java),
		SignalInfo("ad_loaded", String::class.java, String::class.java),
		SignalInfo(
			"ad_load_failed",
			String::class.java, String::class.java,
			Int::class.javaObjectType, String::class.java
		),
		SignalInfo("ad_shown", String::class.java, String::class.java),
		SignalInfo(
			"ad_show_failed",
			String::class.java, String::class.java,
			Int::class.javaObjectType, String::class.java
		),
		SignalInfo("ad_clicked", String::class.java, String::class.java),
		SignalInfo("ad_closed", String::class.java, String::class.java),
		SignalInfo(
			"ad_reward_earned",
			String::class.java, String::class.java, Int::class.javaObjectType
		),
		SignalInfo("ad_revenue_paid", String::class.java, String::class.java)
	)

	private var provider: AdProvider? = null

	/**
	 * Forwards a provider's callbacks to Godot as signals.
	 *
	 * Nothing is filtered or interpreted here. The reward rule, the retry
	 * backoff and the placement bookkeeping all live in GDScript, where they can
	 * be read, changed and tested without a Gradle build — see `MSAds`.
	 */
	private val events = object : AdEvents {
		override fun loaded(placement: String, format: String) =
			signal("ad_loaded", placement, format)

		override fun loadFailed(placement: String, format: String, code: Int, message: String) =
			signal("ad_load_failed", placement, format, code, message)

		override fun shown(placement: String, format: String) =
			signal("ad_shown", placement, format)

		override fun showFailed(placement: String, format: String, code: Int, message: String) =
			signal("ad_show_failed", placement, format, code, message)

		override fun clicked(placement: String, format: String) =
			signal("ad_clicked", placement, format)

		override fun closed(placement: String, format: String) =
			signal("ad_closed", placement, format)

		override fun rewarded(placement: String, rewardType: String, amount: Int) =
			signal("ad_reward_earned", placement, rewardType, amount)

		override fun revenue(placement: String, json: String) =
			signal("ad_revenue_paid", placement, json)
	}

	@UsedByGodot
	fun initializeAds(providerName: String, configJson: String) = onUi("initializeAds") {
		if (provider != null) {
			// Idempotent: MobileServices.initialize() can be called again, and
			// initialising an ad SDK twice is at best wasted work and at worst a
			// second set of listeners on the same ad objects.
			signal("ads_initialized", provider!!.name)
			return@onUi
		}
		val built = buildProvider(providerName)
		if (built == null) {
			signal(
				"ads_initialization_failed",
				"the $providerName SDK is not in this build. Check ads/provider in " +
					"mobile_services.cfg and re-export: the export plugin adds the SDK " +
					"the config names."
			)
			return@onUi
		}
		val config = AdsConfig.from(Json.toMap(configJson))
		if (config.testMode) {
			logWarn(
				"TEST MODE: ads are test ads and earn nothing. " +
					"Set core/test_mode = false before release."
			)
		}
		provider = built
		built.initialize(
			config,
			onReady = {
				clearFailure()
				logInfo("${built.name} initialised")
				signal("ads_initialized", built.name)
			},
			onFailed = { message ->
				provider = null
				signal("ads_initialization_failed", message)
			}
		)
	}

	/**
	 * Builds the configured provider, or null when its SDK is not in the build.
	 *
	 * The `Class.forName` is what keeps this module loadable with only one of
	 * the two SDKs present — see the module's build file. Without it, an AdMob
	 * game would have to ship AppLovin as well or crash the first time anything
	 * touched this class.
	 */
	private fun buildProvider(providerName: String): AdProvider? {
		val activity = getActivity() ?: return null
		return when (providerName) {
			"admob" -> if (hasClass(ADMOB_CLASS)) AdMobProvider(activity, events) else null
			"applovin_max" ->
				if (hasClass(APPLOVIN_CLASS)) AppLovinProvider(activity, events) else null
			else -> null
		}
	}

	private fun hasClass(name: String): Boolean = try {
		Class.forName(name)
		true
	} catch (missing: ClassNotFoundException) {
		false
	}

	@UsedByGodot
	fun isReady(): Boolean = provider != null

	@UsedByGodot
	fun getProvider(): String = provider?.name ?: "none"

	@UsedByGodot
	fun lastError(): String = lastFailure

	@UsedByGodot
	fun loadAd(placement: String, format: String, unitId: String) = onUi("loadAd($placement)") {
		provider?.load(placement, format, unitId)
	}

	/**
	 * Shows a loaded full-screen ad.
	 *
	 * Answers synchronously because the GDScript side needs to know whether an
	 * impression started at all — if it did not, no `ad_closed` is coming and a
	 * game waiting for one would wait forever.
	 */
	@UsedByGodot
	fun showAd(placement: String): Boolean {
		val current = provider ?: return false
		// `show` must run on the UI thread, and its answer is needed here and
		// now. Both are satisfied by asking whether the ad is loaded (safe from
		// any thread) and posting the show, because "loaded" is exactly the
		// condition under which an impression will start.
		if (!safelyReturn("isLoaded($placement)", false) { current.isLoaded(placement) }) {
			return false
		}
		onUi("showAd($placement)") {
			if (!current.show(placement)) {
				signal(
					"ad_show_failed", placement, "", 0,
					"the ad was ready a moment ago and is not any more"
				)
			}
		}
		return true
	}

	@UsedByGodot
	fun isAdLoaded(placement: String): Boolean =
		safelyReturn("isAdLoaded($placement)", false) {
			provider?.isLoaded(placement) ?: false
		}

	@UsedByGodot
	fun showBanner(placement: String, unitId: String, position: String) =
		onUi("showBanner($placement)") {
			provider?.showBanner(placement, unitId, position)
		}

	@UsedByGodot
	fun hideBanner(placement: String) = onUi("hideBanner($placement)") {
		provider?.hideBanner(placement)
	}

	@UsedByGodot
	fun destroyAd(placement: String) = onUi("destroyAd($placement)") {
		provider?.destroy(placement)
	}

	@UsedByGodot
	fun setMuted(muted: Boolean) = onUi("setMuted") {
		provider?.setMuted(muted)
	}

	@UsedByGodot
	fun setPrivacy(hasConsent: Boolean, isUnderAge: Boolean, doNotSell: Boolean) =
		onUi("setPrivacy") {
			provider?.setPrivacy(hasConsent, isUnderAge, doNotSell)
		}

	/**
	 * Releases every ad object and view.
	 *
	 * A banner holds a view attached to the activity and a network connection
	 * that keeps refreshing; an interstitial holds a listener that references the
	 * activity. Neither is collected while the SDK holds them, so an activity
	 * recreation without this leaks the whole previous window.
	 */
	override fun onMainDestroy() {
		safely("onMainDestroy") {
			provider?.teardown()
			provider = null
		}
		super.onMainDestroy()
	}
}
