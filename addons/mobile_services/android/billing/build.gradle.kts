// Google Play Billing.
//
// The library is compileOnly here and added to the APP by the export plugin,
// which is what keeps this AAR a bridge rather than a second copy of the billing
// client. Bump this version and the one in editor/android_export_plugin.gd
// together.
//
// `billing`, not `billing-ktx`. The bridge only calls the Java API, and the ktx
// artifact brings kotlinx-coroutines and a Kotlin stdlib newer than the
// engine's pinned compiler (2.1.21) onto this module's classpath -- the
// metadata mismatch docs/versions.md describes, waiting for the next bump.
plugins {
	id("com.android.library")
	id("org.jetbrains.kotlin.android")
}

android {
	namespace = "com.bilalsafdar.godot.mobileservices.billing"
	defaultConfig {
		manifestPlaceholders["godotPluginName"] = "MobileServicesBilling"
		manifestPlaceholders["godotPluginClass"] =
			"com.bilalsafdar.godot.mobileservices.billing.MobileServicesBillingPlugin"
	}
}

dependencies {
	compileOnly(project(":core"))
	compileOnly("com.android.billingclient:billing:9.1.0")
}
