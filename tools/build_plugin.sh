#!/usr/bin/env bash
#
# Builds the Firebase bridge AAR into addons/firebase_analytics/bin/.
#
# Run it from anywhere; it locates the addon from its own path and the Godot
# project from the addon. Used by CI and by hand — one script, so a release
# build and a desk build cannot diverge.
#
#   addons/firebase_analytics/tools/build_plugin.sh [debug|release|both]
#
# WHAT IT NEEDS, and why each one:
#   - The Godot Android build template installed in the project
#     (Project ▸ Install Android Build Template, or unzipped by CI). The
#     engine's own library is extracted from it, so the bridge compiles against
#     exactly the engine that will ship the app rather than a guessed Maven
#     version.
#   - An Android SDK. Point ANDROID_HOME or ANDROID_SDK_ROOT at it.
#   - A JDK 17+ and network access on the first run, for Gradle to fetch AGP,
#     Kotlin and the Firebase SDK.
#
# Gradle itself is NOT required to be installed: the Android build template
# ships a wrapper, and this script uses it rather than committing a second
# wrapper jar to the repository.

set -euo pipefail

VARIANT="${1:-release}"
case "$VARIANT" in
	debug|release|both) ;;
	*) echo "usage: $(basename "$0") [debug|release|both]" >&2; exit 2 ;;
esac

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(cd "$ADDON_DIR/../.." && pwd)"
ANDROID_DIR="$ADDON_DIR/android"

# The Godot Android build template: the wrapper we build with, and the engine
# library we compile against, both live here.
BUILD_TEMPLATE="${GODOT_ANDROID_BUILD_DIR:-$PROJECT_DIR/android/build}"
GRADLEW="$BUILD_TEMPLATE/gradlew"
GODOT_LIB_AAR="$BUILD_TEMPLATE/libs/release/godot-lib.template_release.aar"

if [ ! -f "$GRADLEW" ]; then
	echo "error: no Godot Android build template at $BUILD_TEMPLATE" >&2
	echo "       In the Godot editor: Project ▸ Install Android Build Template." >&2
	echo "       (Or set GODOT_ANDROID_BUILD_DIR to an installed one.)" >&2
	exit 1
fi

if [ ! -f "$GODOT_LIB_AAR" ]; then
	echo "error: $GODOT_LIB_AAR is missing from the build template." >&2
	exit 1
fi

# The engine's Java/Kotlin API, straight out of the engine's own library. This
# is the whole reason there is no `org.godotengine:godot` Maven version pinned
# anywhere: there is nothing to pin, and nothing to get wrong on an upgrade.
mkdir -p "$ANDROID_DIR/libs"
unzip -p "$GODOT_LIB_AAR" classes.jar > "$ANDROID_DIR/libs/godot-lib.jar"
echo "Compiling against $(basename "$GODOT_LIB_AAR")"

TASKS=()
case "$VARIANT" in
	debug)   TASKS=("assembleDebug") ;;
	release) TASKS=("assembleRelease") ;;
	both)    TASKS=("assembleDebug" "assembleRelease") ;;
esac

# `-p` points the template's wrapper at this addon's Gradle project. The
# wrapper only supplies Gradle itself; the build it runs is entirely ours.
sh "$GRADLEW" -p "$ANDROID_DIR" --no-daemon "${TASKS[@]}"

mkdir -p "$ADDON_DIR/bin/debug" "$ADDON_DIR/bin/release"
OUT="$ANDROID_DIR/build/outputs/aar"
for variant in debug release; do
	AAR="$OUT/firebase-analytics-bridge-$variant.aar"
	if [ -f "$AAR" ]; then
		cp "$AAR" "$ADDON_DIR/bin/$variant/"
		echo "Staged $(basename "$AAR") -> addons/firebase_analytics/bin/$variant/"
	fi
done

echo "Done."
