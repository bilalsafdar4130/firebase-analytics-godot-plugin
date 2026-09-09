#!/usr/bin/env bash
#
# Builds the iOS plugin xcframeworks into addons/mobile_services/bin/ios/.
#
#   addons/mobile_services/tools/build_ios.sh [release|debug] [modules…]
#
# macOS AND XCODE ONLY. A Godot iOS plugin is a static library compiled against
# the ENGINE'S OWN C++ HEADERS, so this needs a checkout of the Godot source at
# the same version as the export templates the game ships with. There is no way
# around that and no way to do it on Linux or Windows — which is why this
# repository's CI builds the Android half and not this one. See docs/ios.md.
#
# WHAT IT NEEDS:
#   - macOS with Xcode and the command line tools.
#   - scons (brew install scons).
#   - A Godot source checkout at the engine version you export with. Point
#     GODOT_SOURCE_DIR at it, or let this script clone it next to the project.
#   - The Firebase and Google Mobile Ads SDK headers on the include path, for the
#     firebase and ads modules. The simplest way is a CocoaPods install in a
#     scratch project; docs/ios.md has the Podfile.
#
# WHAT IT PRODUCES: one .xcframework per module, next to the .gdip descriptors in
# ios/plugins/. Copy both into a game's res://ios/plugins/ and enable them in the
# iOS export preset.

set -euo pipefail

ALL_MODULES=(core firebase ads billing gamecenter consent)

VARIANT="${1:-release}"
case "$VARIANT" in
	debug|release) shift || true ;;
	*) VARIANT="release" ;;
esac

MODULES=("$@")
if [ ${#MODULES[@]} -eq 0 ]; then
	MODULES=("${ALL_MODULES[@]}")
fi

if [ "$(uname -s)" != "Darwin" ]; then
	echo "error: iOS plugins can only be built on macOS with Xcode." >&2
	echo "       The Android half builds anywhere: tools/build_android.sh" >&2
	exit 1
fi

command -v scons >/dev/null || { echo "error: scons is not installed (brew install scons)" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "error: Xcode is not installed" >&2; exit 1; }

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$ADDON_DIR/ios"
GODOT_SOURCE="${GODOT_SOURCE_DIR:-$ADDON_DIR/.godot-source}"
GODOT_VERSION="${GODOT_VERSION:-4.4-stable}"

if [ ! -d "$GODOT_SOURCE" ]; then
	echo "Cloning Godot $GODOT_VERSION into $GODOT_SOURCE (shallow)…"
	git clone --depth 1 --branch "$GODOT_VERSION" https://github.com/godotengine/godot.git "$GODOT_SOURCE"
fi
if [ ! -f "$GODOT_SOURCE/core/object/object.h" ]; then
	echo "error: $GODOT_SOURCE does not look like a Godot source checkout." >&2
	exit 1
fi

# Two slices, combined into one xcframework: the device build and the simulator
# build. An xcframework with only the device slice makes the game unrunnable in
# the simulator, which is where most iteration happens.
OUT="$IOS_DIR/build"
mkdir -p "$OUT"

for module in "${MODULES[@]}"; do
	echo "=== $module ($VARIANT) ==="
	scons -C "$IOS_DIR" \
		module="$module" \
		target="$VARIANT" \
		godot_source="$GODOT_SOURCE" \
		arch=arm64 simulator=no
	scons -C "$IOS_DIR" \
		module="$module" \
		target="$VARIANT" \
		godot_source="$GODOT_SOURCE" \
		arch=arm64 simulator=yes

	FRAMEWORK="$IOS_DIR/plugins/mobile_services_$module.$VARIANT.xcframework"
	rm -rf "$FRAMEWORK"
	xcodebuild -create-xcframework \
		-library "$OUT/libmobile_services_$module.$VARIANT.arm64.a" \
		-library "$OUT/libmobile_services_$module.$VARIANT.arm64.simulator.a" \
		-output "$FRAMEWORK"
	echo "Built $(basename "$FRAMEWORK")"
done

mkdir -p "$ADDON_DIR/bin/ios"
cp -R "$IOS_DIR/plugins/." "$ADDON_DIR/bin/ios/"
echo "Done. Copy addons/mobile_services/bin/ios/ into your game's res://ios/plugins/."
