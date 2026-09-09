// Always shipped. Carries no third-party SDK at all: the shared plugin base
// class, the anonymous installation id, and device facts for the diagnostics
// screen. Every other module compiles against this one and finds it at runtime
// because it is always in the app.
plugins {
	id("com.android.library")
	id("org.jetbrains.kotlin.android")
}

android {
	namespace = "com.bilalsafdar.godot.mobileservices.core"
	defaultConfig {
		manifestPlaceholders["godotPluginName"] = "MobileServicesCore"
		manifestPlaceholders["godotPluginClass"] =
			"com.bilalsafdar.godot.mobileservices.core.MobileServicesCorePlugin"
	}
}
