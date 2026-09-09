# iOS

## Status, stated plainly

| | |
|---|---|
| The GDScript SDK on iOS | **Complete.** Platform detection, singleton names and graceful degradation all work today. A game built for iOS runs; services without their native half answer `SERVICE_UNAVAILABLE`. |
| The iOS export plugin | **Complete.** Info.plist keys, SKAdNetwork, `GoogleService-Info.plist` bundling, and a check that each enabled module's `.gdip` is installed. |
| The native plugins | **Preview.** Complete Objective-C++ sources for all six modules, `.gdip` descriptors, an SConstruct and a build script — **not built by this repository's CI**, because building them needs macOS and Xcode. Build and verify them on a Mac before you ship. |

The Android half is built from source by CI on every push. The iOS half is not,
and this page says so rather than letting you find out at submission time.

## Why an iOS plugin is different

On Android a plugin is a Kotlin class in an AAR that the engine finds through a
manifest entry. On iOS it is a **static library compiled against the engine's own
C++ headers**, packaged as an `.xcframework`, described by a `.gdip`, and linked
into the Xcode project Godot generates.

That means it must be built on macOS, with Xcode, against a checkout of the
**Godot source at the same version as your export templates**. There is no binary
SDK to link against instead, and no way to do it on Linux or Windows.

## Building

```bash
brew install scons
export GODOT_VERSION=4.4-stable        # match your export templates
addons/mobile_services/tools/build_ios.sh release
```

The script clones the Godot source (shallow) if `GODOT_SOURCE_DIR` is not set,
builds a device slice and a simulator slice per module, and combines them into
one `.xcframework` each. An xcframework with only the device slice makes the game
unrunnable in the simulator, which is where most iteration happens.

Then, in your game:

1. Copy `addons/mobile_services/bin/ios/` into `res://ios/plugins/`.
2. Switch each plugin on in the **iOS export preset**.

Miss either step and the singleton simply does not exist: every call to that
service answers `SERVICE_UNAVAILABLE` for the life of the build, which looks
exactly like a game whose players do not buy anything. The export plugin checks
for the `.gdip` files and fails the export by name if one is missing.

## Third-party SDKs

Firebase and Google Mobile Ads are **not** bundled in the xcframeworks — they are
many megabytes and update on their own schedule. Add them to the Xcode project
Godot generates, with CocoaPods:

```ruby
# ios/xcode/Podfile
platform :ios, '14.0'
target 'YourGame' do
  use_frameworks!
  pod 'FirebaseAnalytics'
  pod 'FirebaseCrashlytics'      # only if analytics/crashlytics_enabled
  pod 'FirebaseRemoteConfig'     # only if analytics/remote_config_enabled
  pod 'Google-Mobile-Ads-SDK'    # only if ads/enabled
  pod 'GoogleUserMessagingPlatform'  # only if consent/enabled
end
```

`pod install`, then open the `.xcworkspace` rather than the `.xcodeproj`.

To *compile* the plugins against those headers, point SCons at them:

```
scons -C addons/mobile_services/ios module=ads target=release \
  godot_source=… sdk_includes=/path/to/Pods/Headers/Public
```

StoreKit and GameKit are part of iOS, so the billing and Game Center modules need
nothing extra.

## What the export plugin writes for you

From `mobile_services.cfg`, into Info.plist:

- `GADApplicationIdentifier` — without it AdMob's initialiser throws on launch,
  exactly as on Android
- `AppLovinSdkKey`, for a MAX build
- `NSUserTrackingUsageDescription`, from `consent/att_message` — without it the
  ATT prompt cannot be shown at all, and Apple rejects a build for asking
- `SKAdNetworkItems`
- Firebase's ad-personalisation default, denied

And it bundles `GoogleService-Info.plist` from `res://ios/` or `res://`.

## SKAdNetwork

The default is Google's own identifier and nothing else. A **mediated** waterfall
needs every network's identifier or their installs go unattributed — and the list
runs to a hundred entries and changes whenever a network is added or dropped.

So it is a file your game owns:

```
# res://skadnetwork_ids.txt
cstr6suwn9.skadnetwork
4pfyvq9l8r.skadnetwork
…
```

One identifier per line, `#` for comments. Google and AppLovin both publish the
current list; updating it is then a one-line commit in your game rather than a
change to this addon.

## Adding AppLovin MAX on iOS

The iOS ad plugin is AdMob-only today, and `initializeAds` answers
`ads_initialization_failed` for any other provider rather than pretending.

Adding MAX is the same shape of work `AdMobProvider.kt` was on Android: one class
implementing load / show / isLoaded / showBanner / hideBanner / destroy /
setMuted / setPrivacy, with a `NSClassFromString` guard in
`MobileServicesAds::initialize_ads` so an AdMob build never loads it. Nothing in
GDScript, the export plugin or any game changes.

## Testing on a device

```
# Firebase DebugView
-FIRDebugEnabled          ← add to the scheme's launch arguments
```

Then Firebase console ▸ Analytics ▸ DebugView, which shows events within seconds.

For purchases, use a **Sandbox tester** account and sign the Paid Applications
Agreement first — without it nothing resolves and every product reads as unknown.

## Known gaps

- Not built or run by CI here. Compile errors are possible on first build.
- AppLovin MAX is not implemented (see above).
- Firebase Crashlytics `dSYM` upload is not automated; add Google's run-script
  build phase to the Xcode project if you want symbolicated native crashes.
- StoreKit 1 (`SKPaymentQueue`) rather than StoreKit 2. StoreKit 1 works on iOS
  14+, which is this SDK's floor; StoreKit 2 needs iOS 15 and a Swift interop
  layer that would not buy a small game much.
