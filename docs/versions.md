# Versions and compatibility

## Engine and platforms

| | |
|---|---|
| Godot | 4.3 – 4.5. Developed against **4.4**. |
| Android | minSdk **24**, compileSdk 36, targetSdk whatever your export preset sets (Play requires 34+) |
| Android ABIs | `arm64-v8a` (required), `armeabi-v7a` (works). `x86_64` only for emulators. |
| iOS | **14.0**+, arm64. The floor is set by `AppTrackingTransparency`. |
| JDK | **17** |
| Kotlin | 2.1.21 |
| Android Gradle Plugin | 8.6.1 |

The Android toolchain versions match Godot's own Android build template
(`config.gradle`), so the plugins compile with the same toolchain the app around
them does — one set of downloads, one set of behaviours, no version pair that
exists only here. If you upgrade Godot and its template moves, move
`android/build.gradle.kts` with it.

## SDK dependencies

Added to the app by the export plugin, only for the modules a game enables.

| | Android | iOS |
|---|---|---|
| Firebase Analytics | `com.google.firebase:firebase-analytics:22.1.2` | `FirebaseAnalytics` (CocoaPods) |
| Firebase Crashlytics | `com.google.firebase:firebase-crashlytics:19.3.0` | `FirebaseCrashlytics` |
| Firebase Remote Config | `com.google.firebase:firebase-config:22.0.1` | `FirebaseRemoteConfig` |
| Google Mobile Ads | `com.google.android.gms:play-services-ads:23.6.0` | `Google-Mobile-Ads-SDK` |
| AppLovin MAX | `com.applovin:applovin-sdk:13.0.1` | *(not implemented — see [`ios.md`](ios.md))* |
| Play Billing / StoreKit | `com.android.billingclient:billing-ktx:7.1.1` | StoreKit (system) |
| Play Games / Game Center | `com.google.android.gms:play-services-games-v2:20.1.2` | GameKit (system) |
| UMP consent | `com.google.android.ump:user-messaging-platform:3.1.0` | `GoogleUserMessagingPlatform` |

The Firebase versions are what **BOM 33.7.0** resolves to. The BOM itself is not
used: Godot's export API inserts each dependency as `implementation
'<coordinate>'`, and `platform(...)` is Gradle syntax rather than a coordinate.

### Bumping one

Two places must move together, or the bridge compiles against an SDK the app
does not carry:

1. `DEPENDENCIES` in `addons/mobile_services/editor/android_export_plugin.gd`
   — what the **app** ships
2. the matching `compileOnly` in that module's `android/*/build.gradle.kts`
   — what the **bridge** compiles against

Then rebuild the AARs and run the demo on a device.

## This SDK's own version

Stated in five places, which `tests/test_versions.gd` checks agree:

- `addons/mobile_services/plugin.cfg`
- `MobileServices.VERSION` (GDScript)
- `MobileServicesEditorConfig.VERSION` (the export plugins)
- `BuildInfo.VERSION` (Android)
- `MobileServicesCore::get_native_version()` (iOS)

A mismatch means an AAR from one release running under GDScript from another,
which `MSNative` reports as "this method is missing from the installed native
plugin" — a message that is only useful if the version numbers can be trusted.

## Semantic versioning

`MAJOR.MINOR.PATCH`.

- **MAJOR** — a breaking change to the GDScript API or the config file format.
  Documented in `MIGRATION.md`.
- **MINOR** — new services, new methods, new config keys with safe defaults.
- **PATCH** — fixes, and dependency bumps that do not change behaviour.

A game should pin a **released tag**, not `main`. See [`release.md`](release.md).

## Upgrading Godot

1. Upgrade the editor and export templates.
2. *Project ▸ Install Android Build Template* again.
3. Rebuild: `tools/build_android.sh both`. The script re-extracts the engine
   library, so the plugins follow the engine automatically — there is no
   `org.godotengine:godot` Maven version to pin or get wrong.
4. On iOS, rebuild against the matching Godot **source** checkout.
