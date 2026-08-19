import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The Android half of the `firebase_analytics` Godot addon: one Gradle module
// producing one AAR — the bridge class in src/main/java, plus the manifest
// metadata Godot scans to find it.
//
// Nothing here is project-specific. The addon's export_plugin.gd puts the built
// AAR into whatever app is exporting and declares the Firebase SDK as a remote
// dependency of THAT app's build; this module bundles neither.
//
// TOOLCHAIN VERSIONS match Godot 4.7's own Android build template (its
// config.gradle: AGP 8.6.1, Kotlin 2.1.21, compileSdk 36, Java 17), so the
// plugin compiles with the same toolchain the app around it does — one set of
// downloads, one set of behaviours, no version pair that only exists here.
plugins {
	id("com.android.library") version "8.6.1"
	id("org.jetbrains.kotlin.android") version "2.1.21"
}

/** The singleton name GDScript reaches the plugin by. Must equal
 * `FirebaseAnalyticsBridge.PLUGIN_NAME` and the name the host game's analytics
 * wrapper looks for. */
val godotPluginName = "FirebaseAnalyticsBridge"
val pluginPackage = "com.bilalsafdar.godot.firebase"

// The engine classes this plugin extends (GodotPlugin, Godot, Dictionary,
// @UsedByGodot), taken from THE ENGINE'S OWN library rather than a Maven
// coordinate: `org.godotengine:godot` on Maven Central is published per engine
// release, so pinning a version there is a guess that silently compiles against
// a different engine than the one shipping the app. `tools/build_plugin.sh`
// extracts this jar from the Godot Android build template — the exact library
// the app is built against — before invoking this build.
val godotLib = file("libs/godot-lib.jar")

// Firebase's own SDK version. PAIRED with the coordinates export_plugin.gd adds
// to the app's build: this one is compile-only (the classes to compile
// against), that one is what actually ships in the package. Bump them together
// or the plugin compiles against an SDK the app does not carry.
val firebaseBom = "com.google.firebase:firebase-bom:33.3.0"

android {
	namespace = pluginPackage
	compileSdk = 36

	defaultConfig {
		// At or below the host app's floor — a library that demands more than
		// the app does fails the manifest merge. 24 is Godot 4.7's own default.
		minSdk = 24

		// Filled into src/main/AndroidManifest.xml, so the name Godot scans for
		// and the class it instantiates are both stated once, here.
		manifestPlaceholders["godotPluginName"] = godotPluginName
		manifestPlaceholders["godotPluginClass"] = "$pluginPackage.FirebaseAnalyticsBridge"

		// Names the output `firebase-analytics-bridge-release.aar`, which is
		// what export_plugin.gd looks for.
		setProperty("archivesBaseName", "firebase-analytics-bridge")
	}

	compileOptions {
		sourceCompatibility = JavaVersion.VERSION_17
		targetCompatibility = JavaVersion.VERSION_17
	}

	// No minification of its own: it is a handful of classes, and the app's
	// build is what decides shrinking.
	buildTypes {
		release {
			isMinifyEnabled = false
		}
	}
}

kotlin {
	compilerOptions {
		jvmTarget.set(JvmTarget.JVM_17)
	}
}

dependencies {
	// Both compile-only, for the same reason: the app supplies them at runtime.
	// The engine classes come from the engine itself, and the Firebase SDK is
	// pulled into the app build by export_plugin.gd — so this AAR stays a
	// bridge rather than a second copy of anything.
	compileOnly(files(godotLib))
	compileOnly(platform(firebaseBom))
	compileOnly("com.google.firebase:firebase-analytics")
}

// A missing engine jar otherwise fails deep inside Kotlin compilation as a
// screenful of unresolved `org.godotengine.*` references, which reads as broken
// source rather than a missing input. Say what is actually wrong.
gradle.taskGraph.whenReady {
	if (!godotLib.exists()) {
		throw GradleException(
			"""
			${godotLib.absolutePath} is missing — this build compiles against the
			engine's own Android library, which is not committed.

			Run the addon's build script instead of gradle directly:
			  addons/firebase_analytics/tools/build_plugin.sh

			It extracts the jar from the Godot Android build template first.
			""".trimIndent()
		)
	}
}
