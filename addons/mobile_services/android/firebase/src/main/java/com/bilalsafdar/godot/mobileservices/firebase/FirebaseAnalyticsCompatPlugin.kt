package com.bilalsafdar.godot.mobileservices.firebase

import android.app.Activity
import android.view.View
import com.bilalsafdar.godot.mobileservices.core.MobileServicesPlugin
import org.godotengine.godot.Dictionary
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.UsedByGodot

/**
 * The 1.x `FirebaseAnalyticsBridge` singleton, kept alive.
 *
 * WHY THIS FILE EXISTS. Version 1.x of this addon registered one Godot singleton
 * called `FirebaseAnalyticsBridge` with six methods, and games reached it
 * directly:
 *
 *     Engine.get_singleton("FirebaseAnalyticsBridge").logEvent("level_end", {…})
 *
 * Three shipped games are written that way. Removing the singleton in 2.0 would
 * mean every one of them stops reporting the day it picks up the new addon —
 * silently, because `Engine.has_singleton` would simply answer false and the
 * guard every one of those call sites has would swallow it. So the name stays,
 * with the same methods and the same signatures, for as long as it costs this
 * little to keep.
 *
 * It shares [AnalyticsBridge] with [MobileServicesFirebasePlugin] rather than
 * holding a second SDK handle, so a game part-way through migration can call
 * both and get one consistent view.
 *
 * Deprecated: new code should use the `MobileServicesFirebase` singleton, or
 * better, `MobileServices.analytics` in GDScript. See MIGRATION.md.
 */
class FirebaseAnalyticsCompatPlugin(godot: Godot) : MobileServicesPlugin(godot) {

	companion object {
		const val PLUGIN_NAME = "FirebaseAnalyticsBridge"
	}

	override fun getPluginName(): String = PLUGIN_NAME

	private val analytics = AnalyticsBridge()

	override fun onMainCreate(activity: Activity?): View? {
		safely("onMainCreate") { analytics.start(activity) }
		return super.onMainCreate(activity)
	}

	@UsedByGodot
	fun logEvent(event: String, params: Dictionary) = safely("logEvent($event)") {
		analytics.logEvent(getActivity(), event, params)
	}

	@UsedByGodot
	fun setUserProperty(name: String, value: String) = safely("setUserProperty($name)") {
		analytics.setUserProperty(getActivity(), name, value)
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

	/** Whether the SDK actually started. A plugin that is PRESENT and a plugin
	 * that is WORKING look identical from GDScript without this. Retries first,
	 * so asking from a diagnostics screen is also a second chance to answer yes. */
	@UsedByGodot
	fun isReady(): Boolean = safelyReturn("isReady", false) {
		analytics.start(getActivity())
	}

	/** The last failure, for a diagnostics screen — "" when there has been none. */
	@UsedByGodot
	fun lastError(): String = if (analytics.failure.isNotEmpty()) analytics.failure else lastFailure
}
