// Firebase Analytics, Crashlytics and Remote Config.
//
// The SDKs are compileOnly: the export plugin declares them as dependencies of
// the APP being built, so this AAR stays a bridge rather than a second copy of
// anything. Bump these versions and the ones in
// `editor/android_export_plugin.gd` together, or the bridge compiles against an
// SDK the app does not carry.
//
// The versions below are what Firebase BOM 33.7.0 resolves to. The BOM itself
// is not used, because Godot's export API inserts each dependency as
// `implementation '<coordinate>'` and `platform(...)` is Gradle syntax rather
// than a coordinate.
plugins {
	id("com.android.library")
	id("org.jetbrains.kotlin.android")
}

android {
	namespace = "com.bilalsafdar.godot.mobileservices.firebase"
	defaultConfig {
		manifestPlaceholders["godotPluginName"] = "MobileServicesFirebase"
		manifestPlaceholders["godotPluginClass"] =
			"com.bilalsafdar.godot.mobileservices.firebase.MobileServicesFirebasePlugin"
		// The 1.x singleton, kept so games already shipping against it do not
		// have to change a line. See FirebaseAnalyticsCompatPlugin.
		manifestPlaceholders["legacyPluginName"] = "FirebaseAnalyticsBridge"
		manifestPlaceholders["legacyPluginClass"] =
			"com.bilalsafdar.godot.mobileservices.firebase.FirebaseAnalyticsCompatPlugin"
	}
}

dependencies {
	compileOnly(project(":core"))
	compileOnly("com.google.firebase:firebase-analytics:22.1.2")
	// Crashlytics and Remote Config are OPTIONAL in the app. Everything that
	// touches them lives in CrashlyticsBridge / RemoteConfigBridge, which are
	// loaded only after a Class.forName check — so an app that ships neither
	// never loads a class that references them.
	compileOnly("com.google.firebase:firebase-crashlytics:19.3.0")
	compileOnly("com.google.firebase:firebase-config:22.0.1")
}
