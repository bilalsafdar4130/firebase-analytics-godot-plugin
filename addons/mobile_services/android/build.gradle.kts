import com.android.build.gradle.LibraryExtension
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension

// Shared configuration for every module, stated once.
//
// TOOLCHAIN VERSIONS MATCH GODOT'S OWN ANDROID BUILD TEMPLATE (its
// config.gradle: AGP 8.6.1, Kotlin 2.1.21, compileSdk 36, Java 17), so these
// plugins compile with the same toolchain the app around them does — one set of
// downloads, one set of behaviours, no version pair that exists only here.
//
// The plugins are put on the buildscript classpath rather than declared with
// versions in each module, so a version can only be stated once. Modules then
// say `id("com.android.library")` with no version and get this one.
buildscript {
	repositories {
		google()
		mavenCentral()
	}
	dependencies {
		classpath("com.android.tools.build:gradle:8.6.1")
		classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.1.21")
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
		compileSdk = 36
		defaultConfig {
			// At or below the host app's floor — a library that demands more
			// than the app does fails the manifest merge. 24 is Godot 4.x's own
			// default and the floor for Play Billing 7 and Play Games v2.
			minSdk = 24
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
			// No minification here: these are a few dozen small classes, and
			// the app's own build is what decides shrinking. Each module ships
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

	extensions.configure<KotlinAndroidProjectExtension>("kotlin") {
		compilerOptions {
			jvmTarget.set(JvmTarget.JVM_17)
			// The bridge deals in nullable values from three different SDKs;
			// warnings here are signal, not noise.
			allWarningsAsErrors.set(false)
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
