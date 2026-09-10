# Versions and compatibility

## Engine and platforms

| | |
|---|---|
| Godot | 4.3 – 4.6. Developed and built in CI against **4.6**. |
| Android | minSdk **21**, compileSdk **35**, targetSdk whatever your export preset sets (Play requires 34+) |
| Android ABIs | `arm64-v8a` (required), `armeabi-v7a` (works). `x86_64` only for emulators. |
| iOS | **14.0**+, arm64. The floor is set by `AppTrackingTransparency`. |
| JDK | **17** |
| Kotlin | 2.1.20 |
| Android Gradle Plugin | 8.6.1 |
| Gradle | 8.11.1 (the wrapper from the engine's own build template) |

## Why those exact Android versions

**They are copied from the engine, and they are a hard constraint.** Godot's
Android build template pins them in
`platform/android/java/app/config.gradle`; for 4.6 that is AGP 8.6.1, Gradle
8.11.1, Kotlin 2.1.20, compileSdk 35, minSdk 24, Java 17.

Three things break if this addon drifts from them, and the third is the one that
actually broke a build:

1. `tools/build_android.sh` drives these modules with the **wrapper from the
   template**, so Gradle's version is the engine's. An AGP newer than that
   wrapper supports simply refuses to run — *"Minimum supported Gradle version
   is 8.7. Current version is 8.2."*
2. An AAR records the minimum AGP that may consume it. A plugin built with a
   newer AGP than the app's is rejected by **the game's** build, long after this
   one succeeded, with an error naming neither this addon nor the reason.
3. **Kotlin metadata is versioned, and older compilers cannot read newer
   metadata.** Every module compiles against `godot-lib.jar` from the template,
   which the *engine* compiled with *its* Kotlin. Drift the other way and nothing
   compiles at all:

   ```
   Class 'org.godotengine.godot.Godot' was compiled with an incompatible version
   of Kotlin. The actual metadata version is 2.1.0, but the compiler version
   1.9.0 can read versions up to 2.0.0.
   ```

   That is exactly what a game on Godot 4.6 hit while this file still said
   1.9.20 — correct for 4.4.1, and unable to open 4.6's `godot-lib` at all. The
   error names the engine, not this addon.

**On a Godot upgrade:** read that `config.gradle` at the new tag and move
`android/build.gradle.kts` to match. That is the whole procedure.

**minSdk 21** is the engine's floor, and this addon does not raise it. The ad and
billing SDKs have higher floors of their own, but they are dependencies of the
**app**, so a game that enables them raises the Min SDK in its own export preset
— and this number never has to move.

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

These were pinned as **the newest that still built at compileSdk 34**, which is
what Godot 4.4's template used: the next major of each — Google Mobile Ads 24,
Play Billing 8, Firebase BOM 33.10+ — required compileSdk 35 and would have
failed the *game's* export rather than this addon's build.

**That ceiling has lifted** now the toolchain follows Godot 4.6 (compileSdk 35),
but the dependency versions above have deliberately NOT been raised with it. They
work, and a dependency bump is its own change with its own testing — not a rider
on a toolchain fix. These move when somebody moves them on purpose.

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
