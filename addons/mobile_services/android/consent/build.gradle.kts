// Google's User Messaging Platform — the GDPR/EEA consent form.
//
// A MODULE OF ITS OWN, not part of ads, because consent is not only an ads
// question: a game with analytics and no ads still needs a lawful basis in the
// EEA, and a game that shows a form must be able to re-open it from its settings
// whether or not ads are on.
//
// UMP is small and depends on nothing else here.
plugins {
	id("com.android.library")
	id("org.jetbrains.kotlin.android")
}

android {
	namespace = "com.bilalsafdar.godot.mobileservices.consent"
	defaultConfig {
		manifestPlaceholders["godotPluginName"] = "MobileServicesConsent"
		manifestPlaceholders["godotPluginClass"] =
			"com.bilalsafdar.godot.mobileservices.consent.MobileServicesConsentPlugin"
	}
}

dependencies {
	compileOnly(project(":core"))
	compileOnly("com.google.android.ump:user-messaging-platform:3.1.0")
}
