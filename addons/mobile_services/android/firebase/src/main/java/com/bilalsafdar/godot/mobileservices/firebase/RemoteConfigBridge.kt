package com.bilalsafdar.godot.mobileservices.firebase

import com.google.firebase.remoteconfig.FirebaseRemoteConfig
import com.google.firebase.remoteconfig.FirebaseRemoteConfigSettings
import com.bilalsafdar.godot.mobileservices.core.Json

/**
 * Remote Config, in a class nothing loads unless the app ships it — same
 * reasoning as [CrashlyticsBridge].
 *
 * FETCHING IS THROTTLED BY FIREBASE, HARD. The default minimum interval is 12
 * hours in production and the SDK simply refuses more often, answering with a
 * cached result rather than an error. That is why [fetch] takes the interval as
 * an argument: a development overlay sets it to 0 and every launch fetches,
 * while a release build leaves it alone.
 */
internal class RemoteConfigBridge {

	private val remoteConfig: FirebaseRemoteConfig = FirebaseRemoteConfig.getInstance()

	fun setDefaults(defaultsJson: String) {
		val defaults = Json.toMap(defaultsJson)
		if (defaults.isEmpty()) return
		remoteConfig.setDefaultsAsync(defaults)
	}

	/**
	 * Fetches and activates in one step, reporting through [onResult].
	 *
	 * `fetchAndActivate` answers true when new values were activated and false
	 * when the fetch succeeded but changed nothing — both are successes, and the
	 * GDScript side passes the distinction on so a game can skip re-reading
	 * everything for nothing.
	 */
	fun fetch(minimumIntervalSeconds: Long, onResult: (Boolean) -> Unit, onError: (Int, String) -> Unit) {
		val settings = FirebaseRemoteConfigSettings.Builder()
			.setMinimumFetchIntervalInSeconds(minimumIntervalSeconds)
			.build()
		remoteConfig.setConfigSettingsAsync(settings).addOnCompleteListener {
			remoteConfig.fetchAndActivate()
				.addOnSuccessListener { updated -> onResult(updated) }
				.addOnFailureListener { error ->
					// Firebase reports a throttle as an ordinary failure, and
					// the two need different handling: a throttle means "you
					// already have the values", a network error means "you do
					// not". The class name is the only reliable way to tell.
					val throttled = error.javaClass.simpleName.contains("Throttled", true)
					onError(
						if (throttled) 1 else 2,
						error.message ?: error.javaClass.simpleName
					)
				}
		}
	}

	/**
	 * Every key currently in effect, as JSON.
	 *
	 * Remote Config stores everything as a string internally and its typed
	 * getters coerce; the GDScript side coerces too, against the type of the
	 * fallback the caller passed. So strings go over and both ends agree.
	 */
	fun getAllAsJson(): String {
		val values = LinkedHashMap<String, Any?>()
		for ((key, value) in remoteConfig.all) {
			values[key] = value.asString()
		}
		return Json.fromMap(values)
	}
}
