import com.android.build.gradle.LibraryExtension
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

// Shared configuration for every module, stated once.
//
// EVERY VERSION BELOW IS COPIED FROM THE ENGINE'S OWN ANDROID TEMPLATE
// (platform/android/java/app/config.gradle at the Godot tag this addon targets:
// GODOT 4.6 — AGP 8.6.1, Kotlin 2.1.20, compileSdk 35, Java 17,
// and a Gradle 8.11.1 wrapper).
//
// THIS IS A HARD CONSTRAINT, NOT A PREFERENCE. Three reasons, and the third is
// the one that actually broke a build:
//
//  1. The build script drives these modules with the WRAPPER FROM THE TEMPLATE,
//     so Gradle's version is the engine's. An AGP newer than that wrapper
//     supports refuses to run — "Minimum supported Gradle version is …" — and
//     the build stops there. 4.6 ships a wrapper new enough for AGP 8.6.1
//     because the engine's own build uses it.
//
//  2. An AAR records the minimum AGP that may consume it. A plugin built with a
//     newer AGP than the app's is rejected by the APP'S build, long after this
//     one succeeded, with an error that names neither this addon nor the reason.
//
//  3. KOTLIN METADATA IS VERSIONED AND IT IS NOT FORGIVING. Every module here
//     compiles against `godot-lib.jar` from the template, and that jar is
//     compiled by whatever Kotlin the ENGINE used. A compiler older than the
//     metadata cannot read the class at all:
//
//       Class 'org.godotengine.godot.Godot' was compiled with an incompatible
//       version of Kotlin. The actual metadata version is 2.1.0, but the
//       compiler version 1.9.0 can read versions up to 2.0.0.
//
//     That is what these numbers being a release behind cost: Godot 4.6's
//     godot-lib carries Kotlin 2.1.0 metadata, and Kotlin 1.9.20 — correct for
//     4.4.1, which is what this file used to target — cannot open it. Every
//     module fails to compile, and the error names the engine rather than this
//     file.
//
// So on a Godot upgrade: read that config.gradle for the new version and move
// these to match. docs/versions.md says the same thing in prose.
buildscript {
	repositories {
		google()
		mavenCentral()
	}
	dependencies {
		classpath("com.android.tools.build:gradle:8.6.1")
		classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.1.20")
	}
}

// The engine classes every module compiles against (GodotPlugin, Godot,
// Dictionary, @UsedByGodot), taken from THE ENGINE'S OWN library rather than a
// Maven coordinate.
//
// `org.godotengine:godot` on Maven Central is published per engine release, so
// pinning a version there is a guess that silently compiles against a different
// engine than the one shipping the app. `tools/build_android.sh` extracts this
// jar from the Godot Android build template — the exact library the app is
// built against — before invoking this build.
val godotLib: File = rootProject.file("libs/godot-lib.jar")

subprojects {
	apply(plugin = "com.android.library")
	apply(plugin = "org.jetbrains.kotlin.android")

	extensions.configure<LibraryExtension>("android") {
		compileSdk = 35
		defaultConfig {
			// AT OR BELOW THE HOST APP'S FLOOR. A library that demands more than
			// the app does fails the app's manifest merge, and 21 is what Godot's
			// template defaults to. The ad and billing SDKs have floors of their
			// own, but they arrive as dependencies of the APP — so a game that
			// enables them raises its own export preset's Min SDK, and this
			// number never has to move. See docs/versions.md.
			minSdk = 21
			// Names the output mobile-services-<module>-<variant>.aar, which is
			// exactly what the export plugin looks for.
			setProperty("archivesBaseName", "mobile-services-${project.name}")
			consumerProguardFiles("consumer-rules.pro")
		}
		compileOptions {
			sourceCompatibility = JavaVersion.VERSION_17
			targetCompatibility = JavaVersion.VERSION_17
		}
		buildTypes {
			// No minification here: these are a few dozen small classes, and the
			// app's own build is what decides shrinking. Each module ships
			// consumer-rules.pro so the app's R8 keeps what Godot reaches by
			// reflection.
			getByName("release") { isMinifyEnabled = false }
		}
		buildFeatures { buildConfig = false }
		lint {
			// A plugin that fails a lint rule the host app does not run is a
			// build that fails for no reason a game developer can act on.
			abortOnError = false
		}
	}

	// Set on the TASKS rather than through the `kotlin { compilerOptions { } }`
	// extension, which only arrived in Kotlin 2.0. This form works on 1.9 and on
	// 2.x, so following the engine's Kotlin version needs no change here.
	tasks.withType<KotlinCompile>().configureEach {
		compilerOptions {
			jvmTarget.set(JvmTarget.JVM_17)
		}
	}

	dependencies {
		// The engine supplies these at runtime; the AAR must not carry a copy.
		add("compileOnly", files(godotLib))
	}
}

// A missing engine jar otherwise fails deep inside Kotlin compilation as a
// screenful of unresolved `org.godotengine.*` references, which reads as broken
// source rather than a missing input. Say what is actually wrong.
gradle.taskGraph.whenReady {
	if (!godotLib.exists()) {
		throw GradleException(
			"""
			${godotLib.absolutePath} is missing — these plugins compile against
			the engine's own Android library, which is not committed.

			Run the addon's build script instead of gradle directly:
			  addons/mobile_services/tools/build_android.sh

			It extracts the jar from the Godot Android build template first.
			""".trimIndent()
		)
	}
}
