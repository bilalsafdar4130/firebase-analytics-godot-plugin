package com.bilalsafdar.godot.mobileservices.ads

import android.app.Activity
import android.util.Log
import com.google.android.gms.ads.AdError
import com.google.android.gms.ads.AdListener
import com.google.android.gms.ads.AdRequest
import com.google.android.gms.ads.AdSize
import com.google.android.gms.ads.AdValue
import com.google.android.gms.ads.AdView
import com.google.android.gms.ads.FullScreenContentCallback
import com.google.android.gms.ads.LoadAdError
import com.google.android.gms.ads.MobileAds
import com.google.android.gms.ads.OnPaidEventListener
import com.google.android.gms.ads.RequestConfiguration
import com.google.android.gms.ads.appopen.AppOpenAd
import com.google.android.gms.ads.interstitial.InterstitialAd
import com.google.android.gms.ads.interstitial.InterstitialAdLoadCallback
import com.google.android.gms.ads.rewarded.RewardedAd
import com.google.android.gms.ads.rewarded.RewardedAdLoadCallback
import com.google.android.gms.ads.rewardedinterstitial.RewardedInterstitialAd
import com.google.android.gms.ads.rewardedinterstitial.RewardedInterstitialAdLoadCallback
import com.bilalsafdar.godot.mobileservices.core.Json

/**
 * Google AdMob.
 *
 * NOTHING IN HERE KNOWS WHAT A PLACEMENT MEANS. It is handed a name and a unit
 * id and keeps them together in [ads]; the game's own vocabulary stays in
 * `mobile_services.cfg`.
 *
 * EVERY FULL-SCREEN AD IS DISCARDED AFTER ONE SHOW, because AdMob's objects are
 * single-use — showing a second time silently does nothing. The GDScript side
 * reloads on `ad_closed`, which is why a game that shows an interstitial on
 * every game over gets one every time rather than one ever.
 *
 * THIS CLASS IS ONLY LOADED WHEN ADMOB IS THE CONFIGURED PROVIDER. See the
 * module's build file for why that matters.
 */
internal class AdMobProvider(
	private val activity: Activity,
	private val events: AdEvents
) : AdProvider {

	override val name: String = "admob"

	private val banners = BannerHost(activity)
	private val ads = HashMap<String, Entry>()

	private class Entry(
		val format: String,
		val unitId: String,
		var loaded: Any? = null,
		var view: AdView? = null
	)

	override fun initialize(config: AdsConfig, onReady: () -> Unit, onFailed: (String) -> Unit) {
		try {
			val builder = RequestConfiguration.Builder()
			if (config.testDeviceIds.isNotEmpty()) {
				builder.setTestDeviceIds(config.testDeviceIds)
			}
			if (config.maxAdContentRating.isNotEmpty()) {
				builder.setMaxAdContentRating(config.maxAdContentRating)
			}
			if (config.tagForChildDirectedTreatment) {
				builder.setTagForChildDirectedTreatment(
					RequestConfiguration.TAG_FOR_CHILD_DIRECTED_TREATMENT_TRUE
				)
			}
			if (config.tagForUnderAgeOfConsent) {
				builder.setTagForUnderAgeOfConsent(
					RequestConfiguration.TAG_FOR_UNDER_AGE_OF_CONSENT_TRUE
				)
			}
			MobileAds.setRequestConfiguration(builder.build())
			MobileAds.setAppMuted(config.muted)
			// initialize() answers on the main thread once the mediation
			// adapters have reported in. It can take a second or two on a cold
			// start, which is why nothing here is synchronous.
			MobileAds.initialize(activity) { onReady() }
		} catch (error: Throwable) {
			onFailed(error.message ?: error.javaClass.simpleName)
		}
	}

	private fun request(): AdRequest = AdRequest.Builder().build()

	override fun load(placement: String, format: String, unitId: String) {
		val entry = ads.getOrPut(placement) { Entry(format, unitId) }
		if (entry.loaded != null) return
		when (format) {
			AdFormat.INTERSTITIAL -> loadInterstitial(placement, entry)
			AdFormat.REWARDED -> loadRewarded(placement, entry)
			AdFormat.REWARDED_INTERSTITIAL -> loadRewardedInterstitial(placement, entry)
			AdFormat.APP_OPEN -> loadAppOpen(placement, entry)
			AdFormat.BANNER -> Unit // Banners load when they are shown.
			else -> events.loadFailed(placement, format, 1, "unknown ad format $format")
		}
	}

	private fun loadInterstitial(placement: String, entry: Entry) {
		InterstitialAd.load(
			activity, entry.unitId, request(),
			object : InterstitialAdLoadCallback() {
				override fun onAdLoaded(ad: InterstitialAd) {
					ad.fullScreenContentCallback = fullScreenCallback(placement, entry)
					ad.onPaidEventListener = paidListener(placement, entry.format) {
						ad.responseInfo?.mediationAdapterClassName
					}
					entry.loaded = ad
					events.loaded(placement, entry.format)
				}

				override fun onAdFailedToLoad(error: LoadAdError) {
					entry.loaded = null
					events.loadFailed(placement, entry.format, error.code, error.message)
				}
			}
		)
	}

	private fun loadRewarded(placement: String, entry: Entry) {
		RewardedAd.load(
			activity, entry.unitId, request(),
			object : RewardedAdLoadCallback() {
				override fun onAdLoaded(ad: RewardedAd) {
					ad.fullScreenContentCallback = fullScreenCallback(placement, entry)
					ad.onPaidEventListener = paidListener(placement, entry.format) {
						ad.responseInfo?.mediationAdapterClassName
					}
					entry.loaded = ad
					events.loaded(placement, entry.format)
				}

				override fun onAdFailedToLoad(error: LoadAdError) {
					entry.loaded = null
					events.loadFailed(placement, entry.format, error.code, error.message)
				}
			}
		)
	}

	private fun loadRewardedInterstitial(placement: String, entry: Entry) {
		RewardedInterstitialAd.load(
			activity, entry.unitId, request(),
			object : RewardedInterstitialAdLoadCallback() {
				override fun onAdLoaded(ad: RewardedInterstitialAd) {
					ad.fullScreenContentCallback = fullScreenCallback(placement, entry)
					ad.onPaidEventListener = paidListener(placement, entry.format) {
						ad.responseInfo?.mediationAdapterClassName
					}
					entry.loaded = ad
					events.loaded(placement, entry.format)
				}

				override fun onAdFailedToLoad(error: LoadAdError) {
					entry.loaded = null
					events.loadFailed(placement, entry.format, error.code, error.message)
				}
			}
		)
	}

	private fun loadAppOpen(placement: String, entry: Entry) {
		AppOpenAd.load(
			activity, entry.unitId, request(),
			object : AppOpenAd.AppOpenAdLoadCallback() {
				override fun onAdLoaded(ad: AppOpenAd) {
					ad.fullScreenContentCallback = fullScreenCallback(placement, entry)
					ad.onPaidEventListener = paidListener(placement, entry.format) {
						ad.responseInfo?.mediationAdapterClassName
					}
					entry.loaded = ad
					events.loaded(placement, entry.format)
				}

				override fun onAdFailedToLoad(error: LoadAdError) {
					entry.loaded = null
					events.loadFailed(placement, entry.format, error.code, error.message)
				}
			}
		)
	}

	override fun show(placement: String): Boolean {
		val entry = ads[placement] ?: return false
		val ad = entry.loaded ?: return false
		// Cleared BEFORE showing, not after: AdMob's objects are single-use, and
		// a second show() on the same object does nothing at all — no callback,
		// no error, just a game waiting forever for an ad_closed that will not
		// come.
		entry.loaded = null
		return when (ad) {
			is InterstitialAd -> { ad.show(activity); true }
			is RewardedAd -> {
				ad.show(activity) { reward ->
					events.rewarded(placement, reward.type, reward.amount)
				}
				true
			}
			is RewardedInterstitialAd -> {
				ad.show(activity) { reward ->
					events.rewarded(placement, reward.type, reward.amount)
				}
				true
			}
			is AppOpenAd -> { ad.show(activity); true }
			else -> false
		}
	}

	override fun isLoaded(placement: String): Boolean = ads[placement]?.loaded != null

	override fun showBanner(placement: String, unitId: String, position: String) {
		val existing = ads[placement]
		if (existing?.view != null) {
			banners.setVisible(placement, true)
			return
		}
		val entry = Entry(AdFormat.BANNER, unitId)
		val view = AdView(activity)
		view.adUnitId = unitId
		// An ANCHORED ADAPTIVE banner rather than a fixed 320x50: it sizes to the
		// device's width, which is both what Google recommends and what stops a
		// banner looking like a postage stamp on a tablet.
		view.setAdSize(
			AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
				activity, screenWidthDp()
			)
		)
		view.adListener = object : AdListener() {
			override fun onAdLoaded() = events.loaded(placement, AdFormat.BANNER)
			override fun onAdFailedToLoad(error: LoadAdError) =
				events.loadFailed(placement, AdFormat.BANNER, error.code, error.message)
			override fun onAdClicked() = events.clicked(placement, AdFormat.BANNER)
			override fun onAdImpression() = events.shown(placement, AdFormat.BANNER)
		}
		view.onPaidEventListener = paidListener(placement, AdFormat.BANNER) {
			view.responseInfo?.mediationAdapterClassName
		}
		entry.view = view
		ads[placement] = entry
		banners.attach(placement, view, position)
		view.loadAd(request())
	}

	private fun screenWidthDp(): Int {
		val metrics = activity.resources.displayMetrics
		return (metrics.widthPixels / metrics.density).toInt()
	}

	override fun hideBanner(placement: String) = banners.setVisible(placement, false)

	override fun destroy(placement: String) {
		val entry = ads.remove(placement) ?: return
		entry.view?.destroy()
		banners.detach(placement)
		entry.loaded = null
	}

	override fun setMuted(muted: Boolean) {
		MobileAds.setAppMuted(muted)
	}

	/**
	 * AdMob reads consent from the UMP SDK itself, so there is nothing to pass
	 * it here — but a game that has told the SDK the player refused
	 * personalisation still expects non-personalised requests, and the
	 * request-level way to say that is the child-directed/under-age flags, which
	 * are legal declarations rather than preferences and must not be set on that
	 * basis.
	 *
	 * So this deliberately does nothing but record the decision in the log.
	 * See docs/privacy.md.
	 */
	override fun setPrivacy(hasConsent: Boolean, isUnderAge: Boolean, doNotSell: Boolean) {
		Log.i(
			"MobileServicesAds",
			"AdMob reads consent from UMP directly (consent=$hasConsent, " +
				"underAge=$isUnderAge, doNotSell=$doNotSell)"
		)
	}

	override fun teardown() {
		for (placement in ads.keys.toList()) {
			destroy(placement)
		}
		banners.detachAll()
	}

	private fun fullScreenCallback(placement: String, entry: Entry) =
		object : FullScreenContentCallback() {
			override fun onAdShowedFullScreenContent() = events.shown(placement, entry.format)
			override fun onAdClicked() = events.clicked(placement, entry.format)
			override fun onAdDismissedFullScreenContent() = events.closed(placement, entry.format)
			override fun onAdFailedToShowFullScreenContent(error: AdError) =
				events.showFailed(placement, entry.format, error.code, error.message)
		}

	/**
	 * AdMob's per-impression revenue, in the shape Firebase's ad-revenue reports
	 * expect.
	 *
	 * `valueMicros` is millionths of a unit of `currencyCode`, and `precisionType`
	 * says how much to trust it — 0 unknown, 1 an estimate, 2 the publisher's own
	 * floor, 3 the actual amount paid. A game reporting revenue should keep the
	 * precision alongside the figure; averaging estimates and exact values gives
	 * a number that means nothing.
	 */
	private fun paidListener(
		placement: String,
		format: String,
		network: () -> String?
	) = OnPaidEventListener { value: AdValue ->
		events.revenue(
			placement,
			Json.string(
				"format" to format,
				"network" to (network() ?: "admob"),
				"revenue" to value.valueMicros / 1_000_000.0,
				"currency" to value.currencyCode,
				"precision" to value.precisionType
			)
		)
	}
}
