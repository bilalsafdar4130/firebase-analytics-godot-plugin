package com.bilalsafdar.godot.mobileservices.core

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.UsedByGodot
import java.util.UUID

/**
 * The one plugin every build carries: identity, device facts, and nothing else.
 *
 * IT DEPENDS ON NO THIRD-PARTY SDK, which is what lets it be unconditional. A
 * game that ships only this one has added no ad library, no billing client and
 * no Firebase — and still gets a stable player id and a diagnostics screen.
 *
 * THE INSTALLATION ID IS THE POINT. It is a random UUID made on first launch and
 * kept in this app's own SharedPreferences. It is NOT derived from any hardware
 * identifier: not the advertising id, not the ANDROID_ID, not the IMEI. Two
 * installs on one phone get two ids and neither can be traced to the device,
 * which is what makes it usable without a consent prompt and safe to put in a
 * bug report. It dies with the app's data, which is exactly the behaviour a
 * "delete my data" button wants.
 */
class MobileServicesCorePlugin(godot: Godot) : MobileServicesPlugin(godot) {

	companion object {
		const val PLUGIN_NAME = "MobileServicesCore"

		private const val PREFS_NAME = "mobile_services"
		private const val KEY_INSTALLATION_ID = "installation_id"
	}

	override fun getPluginName(): String = PLUGIN_NAME

	private fun prefs(): SharedPreferences? =
		getActivity()?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

	/**
	 * The stable anonymous id, made on first call and kept afterwards.
	 *
	 * Answers "" when there is no activity to reach preferences through, and the
	 * GDScript side then falls back to its own `user://` copy — which is the
	 * same value, written there on the first successful call.
	 */
	@UsedByGodot
	fun getInstallationId(): String = safelyReturn("getInstallationId", "") {
		val store = prefs() ?: return@safelyReturn ""
		val existing = store.getString(KEY_INSTALLATION_ID, null)
		if (!existing.isNullOrEmpty()) {
			return@safelyReturn existing
		}
		val fresh = UUID.randomUUID().toString()
		store.edit().putString(KEY_INSTALLATION_ID, fresh).apply()
		fresh
	}

	/** Overwrites it — used by the GDScript side's `reset_id()`. */
	@UsedByGodot
	fun setInstallationId(id: String) = safely("setInstallationId") {
		prefs()?.edit()?.putString(KEY_INSTALLATION_ID, id)?.apply()
	}

	/**
	 * Device facts for the diagnostics screen, as JSON.
	 *
	 * Model, manufacturer, Android version and locale — the things that turn "it
	 * crashes for one player" into "it crashes on Android 8 on that one
	 * manufacturer's skin". No identifier of any kind is in here.
	 */
	@UsedByGodot
	fun getDeviceInfo(): String = safelyReturn("getDeviceInfo", "{}") {
		Json.string(
			"manufacturer" to Build.MANUFACTURER,
			"model" to Build.MODEL,
			"device" to Build.DEVICE,
			"android_release" to Build.VERSION.RELEASE,
			"sdk_int" to Build.VERSION.SDK_INT,
			"abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"),
			"package" to (getActivity()?.packageName ?: "")
		)
	}

	/**
	 * Whether the device believes it has usable internet.
	 *
	 * Advisory only — a captive portal reports connected and a lift reports
	 * connected on the way down. Everything in this SDK still has to handle a
	 * request that fails; this exists so a game can say "you appear to be
	 * offline" instead of "error 2".
	 */
	@UsedByGodot
	fun isNetworkAvailable(): Boolean = safelyReturn("isNetworkAvailable", false) {
		// `activeNetwork` is API 23. The modules build at the engine's floor of
		// 21, so the two versions below that would throw NoSuchMethodError at
		// runtime rather than fail at compile time — the worst way round.
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
			return@safelyReturn false
		}
		val manager = getActivity()
			?.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
			?: return@safelyReturn false
		val network = manager.activeNetwork ?: return@safelyReturn false
		val capabilities = manager.getNetworkCapabilities(network) ?: return@safelyReturn false
		capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
			capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
	}

	/** The native half's own version, so a diagnostics dump can show a GDScript
	 * and an AAR that have drifted apart. */
	@UsedByGodot
	fun getNativeVersion(): String = BuildInfo.VERSION

	@UsedByGodot
	fun lastError(): String = lastFailure
}
