package com.bilalsafdar.godot.mobileservices.ads

/**
 * What an ad network has to do to be usable by this SDK.
 *
 * DELIBERATELY SMALL. Every method here is something a game asks for; nothing in
 * it is shaped by how AdMob or AppLovin happen to work. Adding a third network
 * means writing this interface once more and adding a branch to
 * [MobileServicesAdsPlugin.buildProvider] — nothing in GDScript, nothing in the
 * export plugin, nothing in any game.
 *
 * PLACEMENTS, NOT AD UNITS. Everything is addressed by the game's own logical
 * placement name; the unit id is passed in on [load] and [showBanner] and the
 * provider is free to forget it afterwards. That is what keeps ad unit ids out
 * of native code and inside each game's `mobile_services.cfg`.
 */
internal interface AdProvider {

	val name: String

	fun initialize(config: AdsConfig, onReady: () -> Unit, onFailed: (String) -> Unit)

	fun load(placement: String, format: String, unitId: String)

	/** True if the ad was handed to the network to display. NOT "an ad was
	 * watched" — that arrives on the events listener. */
	fun show(placement: String): Boolean

	fun isLoaded(placement: String): Boolean

	fun showBanner(placement: String, unitId: String, position: String)

	fun hideBanner(placement: String)

	fun destroy(placement: String)

	fun setMuted(muted: Boolean)

	fun setPrivacy(hasConsent: Boolean, isUnderAge: Boolean, doNotSell: Boolean)

	/** Releases every ad object and view. Called when the SDK shuts down. */
	fun teardown()
}

/**
 * Everything a provider needs that is not per-call, parsed from the JSON the
 * GDScript side sends at initialisation.
 */
internal data class AdsConfig(
	val appId: String,
	val appLovinSdkKey: String,
	val testMode: Boolean,
	val testDeviceIds: List<String>,
	val muted: Boolean,
	val maxAdContentRating: String,
	val tagForChildDirectedTreatment: Boolean,
	val tagForUnderAgeOfConsent: Boolean
) {
	companion object {
		fun from(values: Map<String, Any>): AdsConfig {
			val devices = ArrayList<String>()
			(values["test_device_ids"] as? org.json.JSONArray)?.let { array ->
				for (index in 0 until array.length()) {
					devices.add(array.optString(index))
				}
			}
			return AdsConfig(
				appId = values["app_id"]?.toString().orEmpty(),
				appLovinSdkKey = values["applovin_sdk_key"]?.toString().orEmpty(),
				testMode = values["test_mode"] == true,
				testDeviceIds = devices,
				muted = values["muted"] == true,
				maxAdContentRating = values["max_ad_content_rating"]?.toString().orEmpty(),
				tagForChildDirectedTreatment =
					values["tag_for_child_directed_treatment"] == true,
				tagForUnderAgeOfConsent = values["tag_for_under_age_of_consent"] == true
			)
		}
	}
}

/**
 * How a provider reports back.
 *
 * ONE LISTENER RATHER THAN CALLBACKS PER CALL, because the networks do not offer
 * callbacks per call either: an ad closing, a reward being earned and a revenue
 * figure arriving are three separate events from the SDK's own listener objects,
 * often on different threads and sometimes long after the call that started them.
 *
 * [rewarded] is the only one that can pay a player, and the GDScript side treats
 * it accordingly — see `MSAds`'s reward rule.
 */
internal interface AdEvents {
	fun loaded(placement: String, format: String)
	fun loadFailed(placement: String, format: String, code: Int, message: String)
	fun shown(placement: String, format: String)
	fun showFailed(placement: String, format: String, code: Int, message: String)
	fun clicked(placement: String, format: String)
	fun closed(placement: String, format: String)
	fun rewarded(placement: String, rewardType: String, amount: Int)
	fun revenue(placement: String, json: String)
}

internal object AdFormat {
	const val BANNER = "banner"
	const val INTERSTITIAL = "interstitial"
	const val REWARDED = "rewarded"
	const val REWARDED_INTERSTITIAL = "rewarded_interstitial"
	const val APP_OPEN = "app_open"
}
