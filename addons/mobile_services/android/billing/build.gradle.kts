// Google Play Billing.
//
// The library is compileOnly here and added to the APP by the export plugin,
// which is what keeps this AAR a bridge rather than a second copy of the billing
// client. Bump this version and the one in editor/android_export_plugin.gd
// together.
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
	compileOnly("com.android.billingclient:billing-ktx:7.1.1")
}
