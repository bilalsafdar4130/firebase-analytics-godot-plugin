package com.bilalsafdar.godot.mobileservices.core

import android.app.Activity
import android.util.Log
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin

/**
 * What every plugin in this SDK is built on.
 *
 * THREE RULES, ENFORCED HERE RATHER THAN REMEMBERED AT EACH CALL SITE.
 *
 * 1. NOTHING THROWN BY AN SDK REACHES THE ENGINE. Godot calls `@UsedByGodot`
 *    methods across JNI; an exception escaping one of them does not become a
 *    GDScript error a game can catch — it takes the process down or leaves the
 *    engine in a state nobody has debugged. So every entry point body runs
 *    inside [safely] or [safelyReturn], which catches [Throwable], records it
 *    and carries on. Ads are worth less than a running game, and so is
 *    everything else here.
 *
 * 2. SDK CALLS HAPPEN ON THE UI THREAD. Godot invokes plugin methods on the
 *    Godot thread, and the ad SDKs, the billing client and the Play Games
 *    client all require the main thread — some of them by throwing, some by
 *    failing silently later. [onUi] is the only way this SDK touches them.
 *
 * 3. SIGNALS ARE EMITTED WITH PRIMITIVES ONLY. Strings, ints, booleans and
 *    floats, with anything structured serialised as JSON by [Json]. A signal
 *    declared with a parameter type the running engine cannot marshal fails at
 *    plugin REGISTRATION, which takes the whole plugin down rather than one
 *    call; primitives cannot do that. See the GDScript side's
 *    "The native boundary" note for the same argument from the other end.
 */
abstract class MobileServicesPlugin(godot: Godot) : GodotPlugin(godot) {

	/** Why this plugin is not working, in words — "" while all is well. */
	@Volatile
	protected var lastFailure: String = ""
		private set

	protected val tag: String get() = getPluginName()

	/** Runs [block] on the Android UI thread, catching anything it throws. */
	protected fun onUi(operation: String, block: () -> Unit) {
		val host: Activity? = getActivity()
		if (host == null) {
			fail(operation, IllegalStateException("the plugin has no activity yet"))
			return
		}
		host.runOnUiThread {
			safely(operation, block)
		}
	}

	/** Runs [block] here and now, catching anything it throws. */
	protected inline fun safely(operation: String, block: () -> Unit) {
		try {
			block()
		} catch (error: Throwable) {
			recordFailure(operation, error)
		}
	}

	/** The same, for something with a result. Answers [fallback] on failure. */
	protected inline fun <T> safelyReturn(operation: String, fallback: T, block: () -> T): T {
		return try {
			block()
		} catch (error: Throwable) {
			recordFailure(operation, error)
			fallback
		}
	}

	/**
	 * Records a failure without throwing.
	 *
	 * Public because [safely] and [safelyReturn] are inline — Kotlin requires
	 * what an inline function body touches to be at least as visible as the
	 * function itself. Not part of the plugin's GDScript surface: it carries no
	 * `@UsedByGodot`.
	 */
	fun recordFailure(operation: String, error: Throwable) {
		val message = error.message
		lastFailure = if (message.isNullOrBlank()) {
			"${error.javaClass.simpleName} in $operation"
		} else {
			"${error.javaClass.simpleName} in $operation: $message"
		}
		Log.e(getPluginName(), "$operation failed", error)
	}

	protected fun fail(operation: String, error: Throwable) = recordFailure(operation, error)

	/** Clears the recorded failure after something works again. */
	protected fun clearFailure() {
		lastFailure = ""
	}

	protected fun logInfo(message: String) = Log.i(getPluginName(), message)

	protected fun logWarn(message: String) = Log.w(getPluginName(), message)

	/**
	 * Emits a signal, never throwing if the signal was mis-declared.
	 *
	 * `GodotPlugin.emitSignal` validates the argument types against the
	 * declared [org.godotengine.godot.plugin.SignalInfo] and throws on a
	 * mismatch. A throw here would propagate out of an SDK's callback thread —
	 * AdMob's, Play Billing's — and crash the app inside somebody else's code,
	 * where the stack trace names none of ours.
	 */
	protected fun signal(name: String, vararg args: Any) {
		try {
			emitSignal(name, *args)
		} catch (error: Throwable) {
			Log.e(getPluginName(), "could not emit $name", error)
		}
	}
}
