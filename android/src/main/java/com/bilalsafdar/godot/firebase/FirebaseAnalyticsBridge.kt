package com.bilalsafdar.godot.firebase

import android.app.Activity
import android.os.Bundle
import android.util.Log
import android.view.View
import com.google.firebase.analytics.FirebaseAnalytics
import org.godotengine.godot.Dictionary
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.UsedByGodot

/**
 * A Godot Android plugin bridging GDScript to the Firebase Analytics SDK.
 *
 * Game-agnostic on purpose: it knows nothing about the project that embeds it,
 * takes no configuration, and exposes four methods. Drop the containing
 * `firebase_analytics` folder into any Godot project's `addons/` and it works
 * the same way.
 *
 * WHY THIS EXISTS RATHER THAN A COMMUNITY PLUGIN. Every published Firebase
 * plugin for Godot is a third-party binary going into a signed release build,
 * from a repository that can be archived, retagged or deleted underneath you —
 * the best-known one already has been. The bridge itself is this small, so it
 * is owned outright: source in the repository, built from that source by CI,
 * no downloaded artifact anywhere in the chain.
 *
 * IT MUST NEVER TAKE THE GAME DOWN WITH IT. Analytics is the least important
 * thing in the package: every entry point catches [Throwable] and records the
 * reason instead of propagating it. A player whose device cannot start the
 * Firebase SDK still gets a game, and the failure surfaces through [lastError]
 * as a sentence on a diagnostics screen rather than as a crash.
 */
class FirebaseAnalyticsBridge(godot: Godot) : GodotPlugin(godot) {

	companion object {
		/**
		 * The singleton name GDScript reaches this plugin by. Stated in exactly
		 * two other places, and all three must agree or the plugin is invisible:
		 * `godotPluginName` in `android/build.gradle.kts` (which stamps it into
		 * the manifest metadata Godot scans), and the name the game's own
		 * analytics wrapper looks for.
		 */
		const val PLUGIN_NAME = "FirebaseAnalyticsBridge"

		private const val TAG = PLUGIN_NAME

		/** Firebase truncates string parameters past this; do it here so the
		 * console never shows a value cut off mid-word without explanation. */
		private const val MAX_PARAM_CHARS = 100
	}

	private var analytics: FirebaseAnalytics? = null

	/** Why analytics is unavailable, in words — "" while all is well. */
	private var failure: String = ""

	override fun getPluginName(): String = PLUGIN_NAME

	/**
	 * Grabs the SDK handle once, on the main thread, at activity creation.
	 *
	 * `FirebaseAnalytics.getInstance` is what fails when the app carries the SDK
	 * but no configuration — `google_app_id` and `google_api_key` come from
	 * string resources generated out of google-services.json, and without them
	 * `FirebaseApp` never initialises. That is a real shipping mistake rather
	 * than a hypothetical, so it is caught and named here instead of thrown
	 * through the engine's activity callback.
	 */
	override fun onMainCreate(activity: Activity?): View? {
		try {
			val context = activity ?: getActivity()
			if (context == null) {
				failure = "no activity to initialise against"
			} else {
				analytics = FirebaseAnalytics.getInstance(context)
			}
		} catch (error: Throwable) {
			failure = describe(error)
			Log.e(TAG, "Firebase Analytics could not start", error)
		}
		return super.onMainCreate(activity)
	}

	/**
	 * Logs one event with its parameters.
	 *
	 * Does nothing when the SDK never started: the GDScript side counts what it
	 * sent and reports the pipeline's state, so a second failure report from
	 * here would only be noise.
	 */
	@UsedByGodot
	fun logEvent(event: String, params: Dictionary) {
		val sdk = analytics ?: return
		try {
			sdk.logEvent(event, toBundle(params))
		} catch (error: Throwable) {
			failure = describe(error)
			Log.e(TAG, "logEvent($event) failed", error)
		}
	}

	@UsedByGodot
	fun setUserProperty(name: String, value: String) {
		val sdk = analytics ?: return
		try {
			sdk.setUserProperty(name, value.take(MAX_PARAM_CHARS))
		} catch (error: Throwable) {
			failure = describe(error)
			Log.e(TAG, "setUserProperty($name) failed", error)
		}
	}

	/** Whether the SDK actually started. A plugin that is PRESENT and a plugin
	 * that is WORKING look identical from GDScript without this. */
	@UsedByGodot
	fun isReady(): Boolean = analytics != null

	/** The last failure, for a diagnostics screen — "" when there has been none. */
	@UsedByGodot
	fun lastError(): String = failure

	/**
	 * Godot's `Dictionary` is a `HashMap<String, Object>` carrying whatever
	 * Variant types the caller put in it; Firebase takes a `Bundle` of longs,
	 * doubles and strings.
	 *
	 * Ints widen to long and floats to double because Firebase registers a
	 * number's type from the first event it sees, and a parameter that arrives
	 * as an int on one build and a float on the next is a column that stops
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

	/** One short line naming a failure, for a screen rather than a log reader. */
	private fun describe(error: Throwable): String {
		val message = error.message
		return if (message.isNullOrBlank()) {
			error.javaClass.simpleName
		} else {
			"${error.javaClass.simpleName}: $message"
		}
	}
}
