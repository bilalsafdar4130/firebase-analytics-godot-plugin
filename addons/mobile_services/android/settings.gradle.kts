// The Android half of the `mobile_services` Godot addon.
//
// SIX MODULES, NOT ONE. Each produces its own AAR, and the export plugin ships
// only the ones a game's mobile_services.cfg actually enables. A game with
// analytics and nothing else therefore contains no ad SDK, no billing library
// and no Play Games client — which is a couple of megabytes, a shorter
// permission list, and one less thing to declare on a Play Data Safety form.
//
// It also means an unused SDK cannot break a build: a missing class can only
// throw if something references it, and nothing does when its module is not
// there.
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

rootProject.name = "mobile-services"

include(":core")
include(":firebase")
include(":ads")
include(":billing")
include(":playgames")
include(":consent")
