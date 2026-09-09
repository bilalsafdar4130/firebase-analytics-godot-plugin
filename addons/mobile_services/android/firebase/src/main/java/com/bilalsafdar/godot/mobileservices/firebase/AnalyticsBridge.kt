package com.bilalsafdar.godot.mobileservices.firebase

import android.content.Context
import android.os.Bundle
import com.google.firebase.analytics.FirebaseAnalytics
import org.godotengine.godot.Dictionary

/**
 * The Firebase Analytics calls themselves, with nothing Godot-shaped in them.
 *
 * Split out from [MobileServicesFirebasePlugin] so the same code serves both
 * that plugin and the 1.x compatibility singleton next door — two plugin
 * objects, one SDK handle, no chance of them disagreeing about whether the SDK
 * started.
 */
internal class AnalyticsBridge {

	private var analytics: FirebaseAnalytics? = null

	/** Why analytics is unavailable, in words — "" while all is well. */
	var failure: String = ""
		private set

	val isReady: Boolean get() = analytics != null

	/**
	 * Takes the SDK handle if it does not already have one, and records why not.
	 *
	 * RETRIES ON EVERY USE, which is the point. `onMainCreate` is an engine
	 * callback, and a plugin whose only chance to initialise is a callback that
	 * did not fire — or fired before the app's Firebase ContentProvider had run
	 * — is a plugin that reports nothing for the life of the process with no way
	 * back. Retrying costs one null check per event and removes that whole
	 * failure mode.
	 *
	 * `FirebaseAnalytics.getInstance` is what fails when the app carries the SDK
	 * but no configuration: `google_app_id` and `google_api_key` come from string
	 * resources the export plugin generates out of google-services.json, and
	 * without them `FirebaseApp` never initialises. That is a real shipping
	 * mistake rather than a hypothetical.
	 */
	fun start(context: Context?): Boolean {
		if (analytics != null) return true
		if (context == null) {
			failure = "no activity to initialise against"
			return false
		}
		return try {
			analytics = FirebaseAnalytics.getInstance(context)
			failure = ""
			true
		} catch (error: Throwable) {
			failure = describe(error)
			false
		}
	}

	fun logEvent(context: Context?, event: String, params: Dictionary) {
		val sdk = handle(context) ?: return
		sdk.logEvent(event, toBundle(params))
	}

	fun logScreenView(context: Context?, screenName: String, screenClass: String) {
		val sdk = handle(context) ?: return
		val bundle = Bundle()
		bundle.putString(FirebaseAnalytics.Param.SCREEN_NAME, screenName)
		bundle.putString(FirebaseAnalytics.Param.SCREEN_CLASS, screenClass)
		sdk.logEvent(FirebaseAnalytics.Event.SCREEN_VIEW, bundle)
	}

	fun setUserProperty(context: Context?, name: String, value: String) {
		handle(context)?.setUserProperty(name, value.take(MAX_PARAM_CHARS))
	}

	fun setUserId(context: Context?, userId: String) {
		handle(context)?.setUserId(userId.ifEmpty { null })
	}

	fun setCollectionEnabled(context: Context?, enabled: Boolean) {
		handle(context)?.setAnalyticsCollectionEnabled(enabled)
	}

	fun resetData(context: Context?) {
		handle(context)?.resetAnalyticsData()
	}

	/**
	 * Google Consent Mode: which storage the SDK may use, one flag per type.
	 *
	 * Both of the calls this class makes for consent PERSIST across launches —
	 * the SDK stores them — which is why the manifest can default everything to
	 * denied without costing analytics anything beyond a first session.
	 */
	fun setConsent(
		context: Context?,
		analyticsStorage: Boolean,
		adStorage: Boolean,
		adUserData: Boolean,
		adPersonalization: Boolean
	) {
		val sdk = handle(context) ?: return
		sdk.setConsent(
			mapOf(
				FirebaseAnalytics.ConsentType.ANALYTICS_STORAGE to status(analyticsStorage),
				FirebaseAnalytics.ConsentType.AD_STORAGE to status(adStorage),
				FirebaseAnalytics.ConsentType.AD_USER_DATA to status(adUserData),
				FirebaseAnalytics.ConsentType.AD_PERSONALIZATION to status(adPersonalization)
			)
		)
	}

	private fun handle(context: Context?): FirebaseAnalytics? {
		if (analytics == null) start(context)
		return analytics
	}

	private fun status(granted: Boolean): FirebaseAnalytics.ConsentStatus =
		if (granted) {
			FirebaseAnalytics.ConsentStatus.GRANTED
		} else {
			FirebaseAnalytics.ConsentStatus.DENIED
		}

	/**
	 * Godot's `Dictionary` is a `HashMap<String, Object>` carrying whatever
	 * Variant types the caller put in it; Firebase takes a `Bundle` of longs,
	 * doubles and strings.
	 *
	 * Ints widen to long and floats to double because Firebase registers a
	 * number's type from the first event it sees, and a parameter that arrives as
	 * an int on one build and a float on the next is a column that stops
	 * aggregating. Booleans become 1/0 for the same reason, and anything
	 * unexpected is stringified rather than dropped — a parameter with a
	 * surprising value is still evidence.
	 */
	private fun toBundle(params: Dictionary): Bundle {
		val bundle = Bundle()
		for ((key, value) in params) {
			when (value) {
				is Long -> bundle.putLong(key, value)
				is Int -> bundle.putLong(key, value.toLong())
				is Short -> bundle.putLong(key, value.toLong())
				is Byte -> bundle.putLong(key, value.toLong())
				is Double -> bundle.putDouble(key, value)
				is Float -> bundle.putDouble(key, value.toDouble())
				is Boolean -> bundle.putLong(key, if (value) 1L else 0L)
				is String -> bundle.putString(key, value.take(MAX_PARAM_CHARS))
				else -> bundle.putString(key, value.toString().take(MAX_PARAM_CHARS))
			}
		}
		return bundle
	}

	companion object {
		/** Firebase truncates string parameters past this; done here so the
		 * console never shows a value cut off mid-word without explanation. */
		const val MAX_PARAM_CHARS = 100

		fun describe(error: Throwable): String {
			val message = error.message
			return if (message.isNullOrBlank()) {
				error.javaClass.simpleName
			} else {
				"${error.javaClass.simpleName}: $message"
			}
		}
	}
}
