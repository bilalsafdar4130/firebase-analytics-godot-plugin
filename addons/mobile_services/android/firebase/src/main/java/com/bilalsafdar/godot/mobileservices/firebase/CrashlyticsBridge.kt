package com.bilalsafdar.godot.mobileservices.firebase

import com.google.firebase.crashlytics.FirebaseCrashlytics

/**
 * Crashlytics, in a class nothing loads unless the app actually ships it.
 *
 * WHY IT IS A SEPARATE CLASS. Android resolves a class's references when the
 * class is first loaded, not when the app starts. Putting these calls in
 * [MobileServicesFirebasePlugin] would make loading that plugin — which every
 * Firebase build does — require `com.google.firebase.crashlytics` to be present,
 * so a game that wants analytics alone would have to ship Crashlytics anyway or
 * crash on launch. Here, [MobileServicesFirebasePlugin] checks for the class by
 * name first and never touches this file if the answer is no.
 *
 * WHAT IT DOES NOT DO. Crashlytics catches native and JVM crashes by itself,
 * with no code here at all — an engine segfault, an ANR, an uncaught exception
 * in another plugin. A GDScript error is none of those: it does not crash the
 * process, so nothing reports it unless the game calls [recordError].
 */
internal class CrashlyticsBridge {

	private val crashlytics: FirebaseCrashlytics = FirebaseCrashlytics.getInstance()

	fun setCollectionEnabled(enabled: Boolean) {
		crashlytics.isCrashlyticsCollectionEnabled = enabled
	}

	fun log(message: String) {
		crashlytics.log(message)
	}

	fun setKey(key: String, value: String) {
		crashlytics.setCustomKey(key, value)
	}

	fun setUserId(userId: String) {
		crashlytics.setUserId(userId)
	}

	/**
	 * Reports something the game recovered from, as a Crashlytics non-fatal.
	 *
	 * The exception is synthesised here rather than thrown: Crashlytics groups
	 * non-fatals by the exception's class and message and by the top of its
	 * stack, and a stack captured at this point names the SDK rather than the
	 * game. So the stack is stripped to a single frame carrying the game's own
	 * name and reason, which is what actually distinguishes one group from
	 * another. The context goes in as breadcrumb text on the same report.
	 */
	fun recordError(name: String, reason: String, contextJson: String) {
		if (contextJson.isNotBlank() && contextJson != "{}") {
			crashlytics.log("$name context: $contextJson")
		}
		val error = RuntimeException("$name: $reason")
		error.stackTrace = arrayOf(
			StackTraceElement("GDScript", name, "game", 0)
		)
		crashlytics.recordException(error)
	}

	/** Crashes on purpose. Guarded by `core/test_mode` on the GDScript side. */
	fun testCrash() {
		throw RuntimeException("MobileServices test crash — this one is deliberate")
	}
}
