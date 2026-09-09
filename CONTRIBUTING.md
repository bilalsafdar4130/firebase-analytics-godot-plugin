# Contributing

## Layout

```
addons/mobile_services/
├── editor/     export plugins — editor only, never exported
├── runtime/    the SDK a game talks to — pure GDScript
├── android/    six Gradle modules
├── ios/        six Objective-C++ plugins
└── tools/      build scripts
docs/  demo/  examples/  tests/
```

The repository root is itself a Godot project, so the demo runs from a clone and
the headless tests have a project to import.

## Building

```bash
addons/mobile_services/tools/build_android.sh both            # all six modules
addons/mobile_services/tools/build_android.sh release core firebase
addons/mobile_services/tools/build_ios.sh release             # macOS only
```

Needs the Godot Android build template installed in the project
(*Project ▸ Install Android Build Template*), a JDK 17 and an Android SDK. Do not
run Gradle directly — the script extracts the engine's own library from the build
template first, which is what the modules compile against.

## Testing

```bash
godot --headless --import
godot --headless --script res://tests/run_tests.gd
```

Add a test for anything **pure**: config parsing, validation, name rules, error
translation. Those are the parts where a mistake is silent in a shipped game.

Anything that needs a device goes in the manual matrix in
[`docs/testing.md`](docs/testing.md) instead. A test double for Google Play
Billing tests the double.

## The rules this codebase holds to

1. **Nothing crashes a game that is missing a plugin.** Every public method
   starts with `guard()`; every native call goes through `MSNative`. The whole
   SDK runs on a desktop machine with no native half, and that is not an
   accident to be broken casually.
2. **The native boundary carries primitives and JSON.** Strings, ints, bools,
   floats. A signal declared with a type the running engine cannot marshal fails
   at plugin *registration* and takes the whole plugin down.
3. **Policy lives in GDScript.** The reward rule, the retry backoff, the
   entitlement bookkeeping, the error translation. The native halves call the SDK
   and report what happened, nothing more — because GDScript can be read, changed
   and tested without a Gradle build or a Mac.
4. **Nothing game-specific.** No `if game == …`, no hardcoded ids. If a game
   needs something the SDK cannot express, that is a config key.
5. **Every native entry point catches `Throwable`.** An exception escaping across
   JNI does not become a GDScript error a game can catch.
6. **Every SDK call happens on the UI thread.** Godot invokes plugin methods on
   the Godot thread; AdMob, the billing client and Play Games all require the main
   thread, and each misbehaves differently when they do not get it.
7. **Comments explain *why*.** The what is in the code. A comment earns its place
   by recording a decision, a constraint somebody else's SDK imposes, or a failure
   that is otherwise invisible.

## Adding an ad network

1. Write a class implementing `AdProvider` in
   `android/ads/src/main/java/…/ads/`. Eight methods.
2. Add a branch to `MobileServicesAdsPlugin.buildProvider()`, guarded by
   `Class.forName` on one of the SDK's own classes — that guard is what lets one
   AAR carry two providers while only one SDK is in the app.
3. Add the SDK's coordinate to `DEPENDENCIES` in
   `editor/android_export_plugin.gd`, and `compileOnly` it in
   `android/ads/build.gradle.kts`.
4. Add `-dontwarn` for it in `android/ads/consumer-rules.pro`.
5. Add the name to `MSConfig.AD_PROVIDERS` and the placement key pattern
   (`<provider>_android` / `<provider>_ios`) in `_apply_placement`.
6. Document it in [`docs/ads.md`](docs/ads.md).

Nothing in GDScript's public API, the config format or any game changes.

## Adding a service

1. A new Gradle module under `android/`, with its own `.gdip` counterpart under
   `ios/`. Copy the smallest existing one.
2. A `MSService` subclass under `runtime/services/`.
3. Register it in `MobileServices._build()` and `SINGLETONS`.
4. Add it to `MobileServicesEditorConfig.required_modules()` so the export plugin
   ships it only when it is enabled.
5. Add its config section to `MSConfig`, the template, and
   [`docs/configuration.md`](docs/configuration.md).
6. Add whatever is pure to `tests/`.

## Bumping a dependency

Two places, together, or the bridge compiles against an SDK the app does not
carry:

1. `DEPENDENCIES` in `editor/android_export_plugin.gd` — what the app ships
2. the `compileOnly` in that module's `build.gradle.kts` — what the bridge
   compiles against

Then rebuild and run the demo on a device.

## Versioning

The SDK version is stated in five places and `tests/test_versions.gd` checks they
agree. See [`docs/versions.md`](docs/versions.md).

## Style

- GDScript: tabs, `snake_case`, static typing where it helps, `##` doc comments
  on anything public.
- Kotlin: tabs, official style, `internal` for everything a game cannot reach.
- Objective-C++: Godot's own style, tabs.
- Do not commit built binaries. `bin/` is git-ignored on purpose.

## Commits and pull requests

Say what changed and why in the body, especially why. Reference the failure a
change prevents where there is one — most of the code here exists because
something was silently wrong in a shipped build, and that is worth writing down.
