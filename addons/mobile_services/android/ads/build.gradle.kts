// The ad abstraction and both providers.
//
// ONE MODULE, TWO SDKs, AND ONLY ONE LOADED. AdMob and AppLovin MAX each live in
// their own provider class, and MobileServicesAdsPlugin builds one of them after
// a Class.forName check — so an AdMob build never loads a class that mentions
// AppLovin, and vice versa. Android resolves a class's references when the class
// is first loaded, which is what makes that work.
//
// Splitting the providers into separate Gradle modules would be the other way to
// get this, at the cost of two more AARs, two more manifests and a build script
// that has to know which pair goes together. The Class.forName check is three
// lines.
plugins {
	id("com.android.library")
	id("org.jetbrains.kotlin.android")
}

android {
	namespace = "com.bilalsafdar.godot.mobileservices.ads"
	defaultConfig {
		manifestPlaceholders["godotPluginName"] = "MobileServicesAds"
		manifestPlaceholders["godotPluginClass"] =
			"com.bilalsafdar.godot.mobileservices.ads.MobileServicesAdsPlugin"
	}
}

dependencies {
	compileOnly(project(":core"))
	compileOnly("com.google.android.gms:play-services-ads:23.6.0")
	compileOnly("com.applovin:applovin-sdk:13.0.1")
}
