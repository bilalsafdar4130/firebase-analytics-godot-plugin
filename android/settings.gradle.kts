// The Android half of the `firebase_analytics` Godot addon — a single-module
// build producing one AAR. See build.gradle.kts, and ../README.md for how the
// addon is used in a project.
pluginManagement {
	repositories {
		google()
		mavenCentral()
		gradlePluginPortal()
	}
}

dependencyResolutionManagement {
	repositories {
		google()
		mavenCentral()
	}
}

rootProject.name = "firebase-analytics-bridge"
