// Google Play Games Services v2.
//
// The iOS counterpart of this module is Game Center, which registers the SAME
// Godot singleton name so GDScript talks to one API on both platforms. See
// docs/play_games.md for where the two genuinely differ.
plugins {
	id("com.android.library")
	id("org.jetbrains.kotlin.android")
}

android {
	namespace = "com.bilalsafdar.godot.mobileservices.playgames"
	defaultConfig {
		manifestPlaceholders["godotPluginName"] = "MobileServicesPlayGames"
		manifestPlaceholders["godotPluginClass"] =
			"com.bilalsafdar.godot.mobileservices.playgames.MobileServicesPlayGamesPlugin"
	}
}

dependencies {
	compileOnly(project(":core"))
	compileOnly("com.google.android.gms:play-services-games-v2:20.1.2")
}
