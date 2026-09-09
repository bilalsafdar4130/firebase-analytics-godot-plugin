#!/usr/bin/env bash
#
# Builds the Android plugin AARs into addons/mobile_services/bin/android/.
#
# Run it from anywhere; it locates the addon from its own path and the Godot
# project from the addon. Used by CI and by hand — one script, so a release build
# and a desk build cannot diverge.
#
#   addons/mobile_services/tools/build_android.sh [debug|release|both] [modules…]
#
# With no module names it builds all six. Naming them builds only those, which is
# what a game with analytics alone wants:
#
#   build_android.sh release core firebase
#
# WHAT IT NEEDS, and why each one:
#   - The Godot Android build template installed in the project (Project ▸
#     Install Android Build Template, or unzipped by CI). The engine's own
#     library is extracted from it, so the plugins compile against exactly the
#     engine that will ship the app rather than a guessed Maven version.
#   - An Android SDK. Point ANDROID_HOME or ANDROID_SDK_ROOT at it.
#   - A JDK 17+ and network access on the first run, for Gradle to fetch AGP,
#     Kotlin and the SDKs.
#
# Gradle itself is NOT required to be installed: the Android build template ships
# a wrapper and this script uses it, rather than committing a second wrapper jar.

set -euo pipefail

ALL_MODULES=(core firebase ads billing playgames consent)

VARIANT="${1:-release}"
case "$VARIANT" in
	debug|release|both) shift || true ;;
	*) VARIANT="release" ;;
esac

MODULES=("$@")
if [ ${#MODULES[@]} -eq 0 ]; then
	MODULES=("${ALL_MODULES[@]}")
fi
for module in "${MODULES[@]}"; do
	found=""
	for known in "${ALL_MODULES[@]}"; do
		[ "$module" = "$known" ] && found=1
	done
	if [ -z "$found" ]; then
		echo "error: unknown module '$module'. Known: ${ALL_MODULES[*]}" >&2
		exit 2
	fi
done

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

# The engine library's exact filename has moved between Godot versions
# (godot-lib.template_release.aar, godot-lib.release.aar, and a debug variant on
# templates installed for debug only). Fall back to whichever one is there
# rather than failing on a path that is right for one version of the engine.
if [ ! -f "$GODOT_LIB_AAR" ]; then
	GODOT_LIB_AAR="$(find "$BUILD_TEMPLATE" -name 'godot-lib*.aar' 2>/dev/null | sort | tail -1)"
fi

if [ -z "$GODOT_LIB_AAR" ] || [ ! -f "$GODOT_LIB_AAR" ]; then
	echo "error: no godot-lib*.aar in $BUILD_TEMPLATE" >&2
	echo "       The plugins compile against the engine's own Android library," >&2
	echo "       which ships inside the Android build template. Reinstall it:" >&2
	echo "       Project ▸ Install Android Build Template." >&2
	echo "       What is actually there:" >&2
	find "$BUILD_TEMPLATE" -maxdepth 3 -name '*.aar' 2>/dev/null | sed 's/^/         /' >&2
	exit 1
fi

# The engine's Java/Kotlin API, straight out of the engine's own library. This is
# the whole reason there is no `org.godotengine:godot` Maven version pinned
# anywhere: there is nothing to pin, and nothing to get wrong on an upgrade.
mkdir -p "$ANDROID_DIR/libs"
unzip -p "$GODOT_LIB_AAR" classes.jar > "$ANDROID_DIR/libs/godot-lib.jar"
echo "Compiling against $(basename "$GODOT_LIB_AAR")"

VARIANTS=()
case "$VARIANT" in
	debug)   VARIANTS=(debug) ;;
	release) VARIANTS=(release) ;;
	both)    VARIANTS=(debug release) ;;
esac

TASKS=()
for module in "${MODULES[@]}"; do
	for v in "${VARIANTS[@]}"; do
		# assembleDebug / assembleRelease, capitalised the way Gradle wants.
		suffix="$(printf '%s' "${v:0:1}" | tr '[:lower:]' '[:upper:]')${v:1}"
		TASKS+=(":$module:assemble$suffix")
	done
done

echo "Building: ${TASKS[*]}"
# `-p` points the template's wrapper at this addon's Gradle project. The wrapper
# only supplies Gradle itself; the build it runs is entirely ours.
sh "$GRADLEW" -p "$ANDROID_DIR" --no-daemon "${TASKS[@]}"

staged=0
for v in "${VARIANTS[@]}"; do
	mkdir -p "$ADDON_DIR/bin/android/$v"
	for module in "${MODULES[@]}"; do
		AAR="$ANDROID_DIR/$module/build/outputs/aar/mobile-services-$module-$v.aar"
		if [ -f "$AAR" ]; then
			cp "$AAR" "$ADDON_DIR/bin/android/$v/"
			echo "Staged $(basename "$AAR") -> bin/android/$v/"
			staged=$((staged + 1))
		else
			echo "warning: expected $AAR but it is not there" >&2
		fi
	done
done

if [ "$staged" -eq 0 ]; then
	echo "error: nothing was staged; the build produced no AARs." >&2
	exit 1
fi
echo "Done — $staged AAR(s)."
