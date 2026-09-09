package com.bilalsafdar.godot.mobileservices.firebase

import android.app.Activity
import android.view.View
import com.bilalsafdar.godot.mobileservices.core.MobileServicesPlugin
import org.godotengine.godot.Dictionary
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot

/**
 * Firebase Analytics, Crashlytics and Remote Config, as one Godot singleton.
 *
 * ANALYTICS IS ALWAYS THERE; THE OTHER TWO MAY NOT BE. `firebase-analytics` is
 * added to the app whenever this module ships, but Crashlytics and Remote Config
 * are separate dependencies the export plugin adds only when the game's config
 * asks for them. So each of those is reached through a bridge class that is
 * loaded lazily, after a `Class.forName` check — see [CrashlyticsBridge]. Asking
 * for a service the app does not carry answers false rather than crashing.
 *
 * IT MUST NEVER TAKE THE GAME DOWN WITH IT. Analytics is the least important
 * thing in the package. Every entry point runs inside the base class's
 * [safely]/[safelyReturn], which record the reason instead of propagating it — a
 * player whose device cannot start Firebase still gets a game, and the failure
 * surfaces on a diagnostics screen rather than as a crash.
 */
class MobileServicesFirebasePlugin(godot: Godot) : MobileServicesPlugin(godot) {

	companion object {
		const val PLUGIN_NAME = "MobileServicesFirebase"

		private const val CRASHLYTICS_CLASS = "com.google.firebase.crashlytics.FirebaseCrashlytics"
		private const val REMOTE_CONFIG_CLASS =
			"com.google.firebase.remoteconfig.FirebaseRemoteConfig"
	}

	override fun getPluginName(): String = PLUGIN_NAME

	override fun getPluginSignals(): MutableSet<SignalInfo> = mutableSetOf(
		SignalInfo("firebase_ready"),
		SignalInfo("firebase_failed", String::class.java),
		SignalInfo("remote_config_fetched", Boolean::class.javaObjectType),
		SignalInfo("remote_config_failed", Int::class.javaObjectType, String::class.java)
	)

	private val analytics = AnalyticsBridge()
	private var crashlytics: CrashlyticsBridge? = null
	private var remoteConfig: RemoteConfigBridge? = null

	/** Grabs the SDK handle on the main thread at activity creation — the
	 * ordinary path, and see [AnalyticsBridge.start] for why it is not the only
	 * one. */
	override fun onMainCreate(activity: Activity?): View? {
		safely("onMainCreate") { analytics.start(activity) }
		return super.onMainCreate(activity)
	}

	/**
	 * Starts what the game asked for, and says whether analytics is live.
	 *
	 * Returns true when Firebase was already up — the usual case, since its
	 * ContentProvider runs before the first scene — so the GDScript side can
	 * proceed immediately. When it was not, `firebase_ready` follows if a later
	 * attempt succeeds, and `firebase_failed` names the reason if none does.
	 */
	@UsedByGodot
	fun initializeFirebase(
		wantAnalytics: Boolean,
		wantCrashlytics: Boolean,
		wantRemoteConfig: Boolean
	): Boolean = safelyReturn("initializeFirebase", false) {
		if (!wantAnalytics) return@safelyReturn false
		val started = analytics.start(getActivity())
		if (!started) {
			signal("firebase_failed", analytics.failure)
			return@safelyReturn false
		}
		clearFailure()
		if (wantCrashlytics) {
			crashlytics = optional(CRASHLYTICS_CLASS, "Crashlytics") { CrashlyticsBridge() }
		}
		if (wantRemoteConfig) {
			remoteConfig = optional(REMOTE_CONFIG_CLASS, "Remote Config") { RemoteConfigBridge() }
		}
		logInfo("Firebase ready (crashlytics=${crashlytics != null}, remoteConfig=${remoteConfig != null})")
		true
	}

	/**
	 * Builds an optional bridge, or explains why it could not.
	 *
	 * The `Class.forName` is what keeps this module loadable in an app that
	 * ships analytics alone; the message is what turns "Crashlytics reports
	 * nothing" into something a developer can act on, because the cause is
	 * always the same and always invisible.
	 */
	private fun <T> optional(className: String, label: String, build: () -> T): T? {
		return try {
			Class.forName(className)
			build()
		} catch (missing: ClassNotFoundException) {
			logWarn(
				"$label is switched on in mobile_services.cfg but its SDK is not in " +
					"this build. Re-export: the export plugin adds it only when the " +
					"config asks for it."
			)
			null
		} catch (error: Throwable) {
			recordFailure("start $label", error)
			null
		}
	}

	@UsedByGodot
	fun isReady(): Boolean = analytics.isReady

	@UsedByGodot
	fun lastError(): String = if (analytics.failure.isNotEmpty()) analytics.failure else lastFailure

	// --- Analytics ------------------------------------------------------

	@UsedByGodot
	fun logEvent(event: String, params: Dictionary) = safely("logEvent($event)") {
		analytics.logEvent(getActivity(), event, params)
	}

	@UsedByGodot
	fun logScreenView(screenName: String, screenClass: String) = safely("logScreenView") {
		analytics.logScreenView(getActivity(), screenName, screenClass)
	}

	@UsedByGodot
	fun setUserProperty(name: String, value: String) = safely("setUserProperty($name)") {
		analytics.setUserProperty(getActivity(), name, value)
	}

	@UsedByGodot
	fun setUserId(userId: String) = safely("setUserId") {
		analytics.setUserId(getActivity(), userId)
		crashlytics?.setUserId(userId)
	}

	@UsedByGodot
	fun setAnalyticsCollectionEnabled(enabled: Boolean) =
		safely("setAnalyticsCollectionEnabled") {
			analytics.setCollectionEnabled(getActivity(), enabled)
		}

	@UsedByGodot
	fun setConsent(
		analyticsStorage: Boolean,
		adStorage: Boolean,
		adUserData: Boolean,
		adPersonalization: Boolean
	) = safely("setConsent") {
		analytics.setConsent(
			getActivity(), analyticsStorage, adStorage, adUserData, adPersonalization
		)
	}

	@UsedByGodot
	fun resetAnalyticsData() = safely("resetAnalyticsData") {
		analytics.resetData(getActivity())
	}

	// --- Crashlytics ----------------------------------------------------

	@UsedByGodot
	fun setCrashlyticsCollectionEnabled(enabled: Boolean) =
		safely("setCrashlyticsCollectionEnabled") {
			crashlytics?.setCollectionEnabled(enabled)
		}

	@UsedByGodot
	fun crashlyticsLog(message: String) = safely("crashlyticsLog") {
		crashlytics?.log(message)
	}

	@UsedByGodot
	fun crashlyticsSetKey(key: String, value: String) = safely("crashlyticsSetKey") {
		crashlytics?.setKey(key, value)
	}

	@UsedByGodot
	fun crashlyticsRecordError(name: String, reason: String, contextJson: String) =
		safely("crashlyticsRecordError") {
			crashlytics?.recordError(name, reason, contextJson)
		}

	/** Deliberately NOT wrapped in [safely]: the whole point is that it crashes.
	 * The GDScript side refuses to call it outside `core/test_mode`. */
	@UsedByGodot
	fun crashlyticsTestCrash() {
		crashlytics?.testCrash()
	}

	// --- Remote Config --------------------------------------------------

	@UsedByGodot
	fun remoteConfigSetDefaults(defaultsJson: String) = safely("remoteConfigSetDefaults") {
		remoteConfig?.setDefaults(defaultsJson)
	}

	@UsedByGodot
	fun remoteConfigFetch(minimumIntervalSeconds: Int) = safely("remoteConfigFetch") {
		val bridge = remoteConfig
		if (bridge == null) {
			signal("remote_config_failed", 3, "Remote Config is not in this build")
			return@safely
		}
		bridge.fetch(
			minimumIntervalSeconds.toLong(),
			{ updated -> signal("remote_config_fetched", updated) },
			{ code, message -> signal("remote_config_failed", code, message) }
		)
	}

	@UsedByGodot
	fun remoteConfigGetAll(): String = safelyReturn("remoteConfigGetAll", "{}") {
		remoteConfig?.getAllAsJson() ?: "{}"
	}
}
