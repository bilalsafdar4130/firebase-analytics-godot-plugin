package com.bilalsafdar.godot.mobileservices.ads

import android.app.Activity
import com.applovin.mediation.MaxAd
import com.applovin.mediation.MaxAdListener
import com.applovin.mediation.MaxAdRevenueListener
import com.applovin.mediation.MaxAdViewAdListener
import com.applovin.mediation.MaxError
import com.applovin.mediation.MaxReward
import com.applovin.mediation.MaxRewardedAdListener
import com.applovin.mediation.ads.MaxAdView
import com.applovin.mediation.ads.MaxAppOpenAd
import com.applovin.mediation.ads.MaxInterstitialAd
import com.applovin.mediation.ads.MaxRewardedAd
import com.applovin.sdk.AppLovinMediationProvider
import com.applovin.sdk.AppLovinPrivacySettings
import com.applovin.sdk.AppLovinSdk
import com.applovin.sdk.AppLovinSdkInitializationConfiguration
import com.bilalsafdar.godot.mobileservices.core.Json

/**
 * AppLovin MAX, as a mediation layer rather than as one more ad network.
 *
 * WHAT "MEDIATION" CHANGES, and it is the reason this is not a copy of
 * [AdMobProvider] with different class names. A MAX ad unit is a waterfall over
 * several networks — AdMob among them — so the SDK loads from whichever pays
 * most, and the network that actually filled an impression is only known
 * afterwards, from [MaxAd.getNetworkName]. That name is the interesting part of
 * a revenue event here, where on AdMob it is usually just "admob".
 *
 * PER-NETWORK ADAPTERS ARE THE GAME'S TO ADD. MAX needs an adapter artifact for
 * each network in the waterfall, and which ones a game wants depends on its
 * MAX dashboard. They go in `ads/extra_android_dependencies` in
 * `mobile_services.cfg`; the SDK does not guess.
 *
 * MAX RELOADS ITS OWN ADS after a failure, with its own backoff — the GDScript
 * side's retry is harmless alongside it (a load on an already-loading unit is a
 * no-op) but on this provider it is largely redundant.
 *
 * THIS CLASS IS ONLY LOADED WHEN APPLOVIN IS THE CONFIGURED PROVIDER.
 */
internal class AppLovinProvider(
	private val activity: Activity,
	private val events: AdEvents
) : AdProvider {

	override val name: String = "applovin_max"

	private val banners = BannerHost(activity)
	private val interstitials = HashMap<String, MaxInterstitialAd>()
	private val rewarded = HashMap<String, MaxRewardedAd>()
	private val appOpen = HashMap<String, MaxAppOpenAd>()
	private val bannerViews = HashMap<String, MaxAdView>()
	private val formats = HashMap<String, String>()

	override fun initialize(config: AdsConfig, onReady: () -> Unit, onFailed: (String) -> Unit) {
		try {
			if (config.appLovinSdkKey.isEmpty()) {
				onFailed("ads/applovin_sdk_key is empty in mobile_services.cfg")
				return
			}
			val builder = AppLovinSdkInitializationConfiguration
				.builder(config.appLovinSdkKey, activity)
				.setMediationProvider(AppLovinMediationProvider.MAX)
			if (config.testDeviceIds.isNotEmpty()) {
				builder.setTestDeviceAdvertisingIds(config.testDeviceIds)
			}
			val sdk = AppLovinSdk.getInstance(activity)
			sdk.settings.isMuted = config.muted
			sdk.initialize(builder.build()) { onReady() }
		} catch (error: Throwable) {
			onFailed(error.message ?: error.javaClass.simpleName)
		}
	}

	override fun load(placement: String, format: String, unitId: String) {
		formats[placement] = format
		when (format) {
			AdFormat.INTERSTITIAL -> {
				val ad = interstitials.getOrPut(placement) {
					MaxInterstitialAd(unitId, activity).also { attach(placement, format, it) }
				}
				ad.loadAd()
			}
			// MAX has no separate rewarded-interstitial type; its rewarded unit
			// covers both, and which one the player sees is decided in the MAX
			// dashboard rather than in the app.
			AdFormat.REWARDED, AdFormat.REWARDED_INTERSTITIAL -> {
				val ad = rewarded.getOrPut(placement) {
					MaxRewardedAd.getInstance(unitId, activity)
						.also { attachRewarded(placement, format, it) }
				}
				ad.loadAd()
			}
			AdFormat.APP_OPEN -> {
				val ad = appOpen.getOrPut(placement) {
					MaxAppOpenAd(unitId, activity).also { attachAppOpen(placement, format, it) }
				}
				ad.loadAd()
			}
			AdFormat.BANNER -> Unit // Banners load when they are shown.
			else -> events.loadFailed(placement, format, 1, "unknown ad format $format")
		}
	}

	override fun show(placement: String): Boolean {
		interstitials[placement]?.let {
			if (!it.isReady) return false
			it.showAd()
			return true
		}
		rewarded[placement]?.let {
			if (!it.isReady) return false
			it.showAd()
			return true
		}
		appOpen[placement]?.let {
			if (!it.isReady) return false
			it.showAd()
			return true
		}
		return false
	}

	override fun isLoaded(placement: String): Boolean {
		interstitials[placement]?.let { return it.isReady }
		rewarded[placement]?.let { return it.isReady }
		appOpen[placement]?.let { return it.isReady }
		return false
	}

	override fun showBanner(placement: String, unitId: String, position: String) {
		val existing = bannerViews[placement]
		if (existing != null) {
			banners.setVisible(placement, true)
			existing.startAutoRefresh()
			return
		}
		formats[placement] = AdFormat.BANNER
		val view = MaxAdView(unitId, activity)
		view.setListener(object : MaxAdViewAdListener {
			override fun onAdLoaded(ad: MaxAd) {
				events.loaded(placement, AdFormat.BANNER)
			}

			override fun onAdLoadFailed(unit: String, error: MaxError) {
				events.loadFailed(placement, AdFormat.BANNER, error.code, error.message)
			}

			override fun onAdDisplayed(ad: MaxAd) = events.shown(placement, AdFormat.BANNER)
			override fun onAdHidden(ad: MaxAd) = events.closed(placement, AdFormat.BANNER)
			override fun onAdClicked(ad: MaxAd) = events.clicked(placement, AdFormat.BANNER)
			override fun onAdDisplayFailed(ad: MaxAd, error: MaxError) {
				events.showFailed(placement, AdFormat.BANNER, error.code, error.message)
			}

			override fun onAdExpanded(ad: MaxAd) = Unit
			override fun onAdCollapsed(ad: MaxAd) = Unit
		})
		view.setRevenueListener(revenueListener(placement, AdFormat.BANNER))
		bannerViews[placement] = view
		banners.attach(placement, view, position)
		view.loadAd()
	}

	override fun hideBanner(placement: String) {
		bannerViews[placement]?.stopAutoRefresh()
		banners.setVisible(placement, false)
	}

	override fun destroy(placement: String) {
		interstitials.remove(placement)?.destroy()
		rewarded.remove(placement)?.destroy()
		appOpen.remove(placement)?.destroy()
		bannerViews.remove(placement)?.destroy()
		banners.detach(placement)
		formats.remove(placement)
	}

	override fun setMuted(muted: Boolean) {
		AppLovinSdk.getInstance(activity).settings.isMuted = muted
	}

	/**
	 * MAX needs the consent decision passed to it explicitly — unlike AdMob, it
	 * does not read the UMP SDK itself.
	 *
	 * `isUnderAge` is deliberately not forwarded: AppLovin removed the
	 * age-restricted-user flag in SDK 13, and COPPA status is now declared per
	 * app in the MAX dashboard rather than per session in code. Sending it here
	 * would be a no-op that looked like a setting.
	 */
	override fun setPrivacy(hasConsent: Boolean, isUnderAge: Boolean, doNotSell: Boolean) {
		AppLovinPrivacySettings.setHasUserConsent(hasConsent, activity)
		AppLovinPrivacySettings.setDoNotSell(doNotSell, activity)
	}

	override fun teardown() {
		for (placement in formats.keys.toList()) {
			destroy(placement)
		}
		banners.detachAll()
	}

	private fun attach(placement: String, format: String, ad: MaxInterstitialAd) {
		ad.setListener(fullScreenListener(placement, format))
		ad.setRevenueListener(revenueListener(placement, format))
	}

	private fun attachAppOpen(placement: String, format: String, ad: MaxAppOpenAd) {
		ad.setListener(fullScreenListener(placement, format))
		ad.setRevenueListener(revenueListener(placement, format))
	}

	private fun attachRewarded(placement: String, format: String, ad: MaxRewardedAd) {
		ad.setListener(object : MaxRewardedAdListener {
			override fun onAdLoaded(ad: MaxAd) = events.loaded(placement, format)
			override fun onAdLoadFailed(unit: String, error: MaxError) =
				events.loadFailed(placement, format, error.code, error.message)
			override fun onAdDisplayed(ad: MaxAd) = events.shown(placement, format)
			override fun onAdHidden(ad: MaxAd) = events.closed(placement, format)
			override fun onAdClicked(ad: MaxAd) = events.clicked(placement, format)
			override fun onAdDisplayFailed(ad: MaxAd, error: MaxError) =
				events.showFailed(placement, format, error.code, error.message)

			/** The only callback that may pay a player. MAX delivers it before
			 * `onAdHidden`, and can deliver it more than once after a network
			 * switch — the GDScript side drops the duplicate. */
			override fun onUserRewarded(ad: MaxAd, reward: MaxReward) {
				events.rewarded(placement, reward.label ?: "", reward.amount)
			}
		})
		ad.setRevenueListener(revenueListener(placement, format))
	}

	private fun fullScreenListener(placement: String, format: String) = object : MaxAdListener {
		override fun onAdLoaded(ad: MaxAd) = events.loaded(placement, format)
		override fun onAdLoadFailed(unit: String, error: MaxError) =
			events.loadFailed(placement, format, error.code, error.message)
		override fun onAdDisplayed(ad: MaxAd) = events.shown(placement, format)
		override fun onAdHidden(ad: MaxAd) = events.closed(placement, format)
		override fun onAdClicked(ad: MaxAd) = events.clicked(placement, format)
		override fun onAdDisplayFailed(ad: MaxAd, error: MaxError) =
			events.showFailed(placement, format, error.code, error.message)
	}

	/**
	 * MAX reports revenue for every impression, already in USD.
	 *
	 * `networkName` is the point of it: on a mediated waterfall this is the only
	 * way to know which network actually filled, and it is what makes a Firebase
	 * `ad_impression` event worth sending.
	 */
	private fun revenueListener(placement: String, format: String) =
		MaxAdRevenueListener { ad: MaxAd ->
			events.revenue(
				placement,
				Json.string(
					"format" to format,
					"network" to (ad.networkName ?: "applovin"),
					"revenue" to ad.revenue,
					"currency" to "USD",
					"precision" to (ad.revenuePrecision ?: "")
				)
			)
		}
}
