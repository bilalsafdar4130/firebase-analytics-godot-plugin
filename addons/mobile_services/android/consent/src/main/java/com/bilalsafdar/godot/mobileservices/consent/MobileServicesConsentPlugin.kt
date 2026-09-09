package com.bilalsafdar.godot.mobileservices.consent

import android.content.Context
import com.google.android.ump.ConsentDebugSettings
import com.google.android.ump.ConsentInformation
import com.google.android.ump.ConsentRequestParameters
import com.google.android.ump.UserMessagingPlatform
import com.bilalsafdar.godot.mobileservices.core.Json
import com.bilalsafdar.godot.mobileservices.core.MobileServicesPlugin
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot

/**
 * Google's User Messaging Platform: the EEA consent form, and what it decided.
 *
 * WHAT UMP DOES AND DOES NOT DO FOR YOU. It decides whether a form is required
 * in this player's region, shows Google's own form, and writes the result into
 * the IAB TCF strings in SharedPreferences. The AD SDKs read those themselves.
 * FIREBASE DOES NOT — Google's own guidance is that an app using Consent Mode
 * must call `setConsent` itself, from whatever the form decided. So this class
 * reads the TCF purposes back out and hands GDScript four booleans, which
 * `MobileServices` passes to Firebase.
 *
 * THE PURPOSE MAPPING IS AN APPROXIMATION and is documented as one in
 * docs/privacy.md. TCF purposes do not line up one-for-one with Consent Mode's
 * four storage types, and Google's published mapping has changed more than once.
 * The rule used here errs towards DENY on anything ambiguous, which costs some
 * analytics fidelity and cannot cost a compliance finding.
 *
 * App Tracking Transparency lives here too, and on Android answers
 * NOT_APPLICABLE — the iOS build of this module is where it does something.
 */
class MobileServicesConsentPlugin(godot: Godot) : MobileServicesPlugin(godot) {

	companion object {
		const val PLUGIN_NAME = "MobileServicesConsent"

		/** IAB TCF v2 keys, written into the default SharedPreferences by any
		 * conforming CMP — UMP included. Reading them is the documented way for
		 * an app to find out what the player agreed to. */
		private const val KEY_GDPR_APPLIES = "IABTCF_gdprApplies"
		private const val KEY_PURPOSE_CONSENTS = "IABTCF_PurposeConsents"

		/** ATTrackingManager.AuthorizationStatus, kept in step with the GDScript
		 * enum. 4 is this SDK's own "the question does not arise here". */
		private const val TRACKING_NOT_APPLICABLE = 4
	}

	override fun getPluginName(): String = PLUGIN_NAME

	override fun getPluginSignals(): MutableSet<SignalInfo> = mutableSetOf(
		SignalInfo(
			"consent_updated",
			Int::class.javaObjectType,
			Boolean::class.javaObjectType,
			Boolean::class.javaObjectType
		),
		SignalInfo("consent_form_dismissed", Int::class.javaObjectType, String::class.java),
		SignalInfo("tracking_status", Int::class.javaObjectType)
	)

	private var consentInformation: ConsentInformation? = null

	@UsedByGodot
	fun requestConsentUpdate(
		underAgeOfConsent: Boolean,
		debugGeography: Int,
		testDeviceHashedIds: String
	) = onUi("requestConsentUpdate") {
		val activity = getActivity() ?: return@onUi
		val builder = ConsentRequestParameters.Builder()
			.setTagForUnderAgeOfConsent(underAgeOfConsent)
		if (debugGeography != 0 || testDeviceHashedIds.isNotEmpty()) {
			// Debug settings only take effect on a device whose hashed id is
			// listed. Forcing a geography on an unlisted device does nothing at
			// all, which is the usual reason "the form never appears in testing".
			val debug = ConsentDebugSettings.Builder(activity)
			if (debugGeography != 0) {
				debug.setDebugGeography(debugGeography)
			}
			for (id in testDeviceHashedIds.split(",")) {
				val trimmed = id.trim()
				if (trimmed.isNotEmpty()) {
					debug.addTestDeviceHashedId(trimmed)
				}
			}
			builder.setConsentDebugSettings(debug.build())
		}
		val information = UserMessagingPlatform.getConsentInformation(activity)
		consentInformation = information
		information.requestConsentInfoUpdate(
			activity,
			builder.build(),
			{ safely("consentInfoUpdated") { announce(information) } },
			{ error ->
				safely("consentInfoFailed") {
					// A failure here is usually no network. It must not stop the
					// game: `canRequestAds` still answers from whatever was
					// cached, and the GDScript side holds ads back if that is no.
					logWarn("consent info update failed: ${error.message}")
					announce(information)
				}
			}
		)
	}

	@UsedByGodot
	fun showConsentFormIfRequired() = onUi("showConsentFormIfRequired") {
		val activity = getActivity() ?: return@onUi
		UserMessagingPlatform.loadAndShowConsentFormIfRequired(activity) { error ->
			safely("consentFormDismissed") {
				if (error == null) {
					signal("consent_form_dismissed", 0, "")
				} else {
					signal("consent_form_dismissed", error.errorCode, error.message ?: "")
				}
				consentInformation?.let { announce(it) }
			}
		}
	}

	/**
	 * Re-opens the form so a player can change their mind.
	 *
	 * Google REQUIRES an app that showed a form to keep this reachable — a
	 * settings entry, a privacy button. [isPrivacyOptionsRequired] says whether
	 * to show it.
	 */
	@UsedByGodot
	fun showPrivacyOptionsForm() = onUi("showPrivacyOptionsForm") {
		val activity = getActivity() ?: return@onUi
		UserMessagingPlatform.showPrivacyOptionsForm(activity) { error ->
			safely("privacyOptionsDismissed") {
				if (error == null) {
					signal("consent_form_dismissed", 0, "")
				} else {
					signal("consent_form_dismissed", error.errorCode, error.message ?: "")
				}
				consentInformation?.let { announce(it) }
			}
		}
	}

	@UsedByGodot
	fun canRequestAds(): Boolean =
		safelyReturn("canRequestAds", false) { consentInformation?.canRequestAds() ?: false }

	@UsedByGodot
	fun isPrivacyOptionsRequired(): Boolean = safelyReturn("isPrivacyOptionsRequired", false) {
		consentInformation?.privacyOptionsRequirementStatus ==
			ConsentInformation.PrivacyOptionsRequirementStatus.REQUIRED
	}

	@UsedByGodot
	fun getConsentStatus(): Int =
		safelyReturn("getConsentStatus", 0) { consentInformation?.consentStatus ?: 0 }

	/** Clears the stored decision so the form appears again. Test only; the
	 * GDScript side refuses outside `core/test_mode`. */
	@UsedByGodot
	fun resetConsent() = onUi("resetConsent") {
		consentInformation?.reset()
	}

	/**
	 * The four Google Consent Mode flags, derived from the TCF purposes.
	 *
	 * See the class comment: this is an approximation that errs towards deny.
	 * When GDPR does not apply — outside the EEA and the UK — everything is
	 * granted, which is what UMP itself assumes when it decides no form is
	 * needed.
	 */
	@UsedByGodot
	fun getConsentFlags(): String = safelyReturn("getConsentFlags", "") {
		val activity = getActivity() ?: return@safelyReturn ""
		// The DEFAULT SharedPreferences file, by name rather than through
		// android.preference.PreferenceManager — that class is deprecated and its
		// AndroidX replacement would be a dependency this module has no other use
		// for. The file name is part of the platform's contract and is what every
		// TCF-conforming CMP, UMP included, writes to.
		val context = activity.applicationContext
		val prefs = context.getSharedPreferences(
			"${context.packageName}_preferences", Context.MODE_PRIVATE
		)
		// -1 means "no TCF string has been written", which happens before the
		// first requestConsentInfoUpdate and on a device where GDPR never
		// applied. Both mean: nothing is being withheld.
		val gdprApplies = prefs.getInt(KEY_GDPR_APPLIES, -1)
		if (gdprApplies != 1) {
			return@safelyReturn Json.string(
				"analytics_storage" to true,
				"ad_storage" to true,
				"ad_user_data" to true,
				"ad_personalization" to true
			)
		}
		val purposes = prefs.getString(KEY_PURPOSE_CONSENTS, "").orEmpty()
		// Purpose 1: store and access information on the device — the
		// prerequisite for any storage at all.
		val storage = purpose(purposes, 1)
		Json.string(
			// 8, 9 and 10 are measurement, market research and product
			// development: the analytics purposes.
			"analytics_storage" to (
				storage && (purpose(purposes, 8) || purpose(purposes, 9) || purpose(purposes, 10))
				),
			"ad_storage" to (storage && purpose(purposes, 2)),
			// 7 is measuring ad performance, which is what ad_user_data covers.
			"ad_user_data" to (storage && purpose(purposes, 7)),
			// 3 and 4 are building and using a personalised ad profile. Both are
			// needed; either alone is not personalisation consent.
			"ad_personalization" to (storage && purpose(purposes, 3) && purpose(purposes, 4))
		)
	}

	/** TCF purposes are a string of '0'/'1', one per purpose, 1-indexed. */
	private fun purpose(consents: String, number: Int): Boolean {
		val index = number - 1
		return index in consents.indices && consents[index] == '1'
	}

	/** App Tracking Transparency is an Apple mechanism; there is nothing to ask
	 * for on Android, and saying so is better than silence. */
	@UsedByGodot
	fun requestTrackingAuthorization() = safely("requestTrackingAuthorization") {
		signal("tracking_status", TRACKING_NOT_APPLICABLE)
	}

	@UsedByGodot
	fun lastError(): String = lastFailure

	private fun announce(information: ConsentInformation) {
		signal(
			"consent_updated",
			information.consentStatus,
			information.canRequestAds(),
			information.privacyOptionsRequirementStatus ==
				ConsentInformation.PrivacyOptionsRequirementStatus.REQUIRED
		)
	}
}
