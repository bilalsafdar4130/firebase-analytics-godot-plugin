> **Archived.** This is the README of version 1.x, the Firebase-Analytics-only
> addon this repository used to be. It is kept because three shipped games were
> written against it and its reasoning still explains half of what version 2 does.
>
> For the current SDK start at [the README](../README.md); to upgrade a 1.x game
> read [MIGRATION.md](../MIGRATION.md) — the short answer is that your existing
> code keeps working.

# Firebase Analytics for Godot 4 (Android)

A self-contained Godot addon that gives GDScript a Firebase Analytics call, and
puts the SDK into your Android build. Kotlin source included; **no downloaded
plugin binary anywhere in the chain.**

Copyright © 2026 Bilal Safdar. See `LICENSE`.

> **Portable by design.** This folder is the whole addon: GDScript, Kotlin,
> Gradle project and build script. Copy `firebase_analytics/` into any Godot 4
> project's `addons/` and it behaves identically — it reads the package name and
> build directory from that project's export preset and hardcodes nothing about
> the game around it. It is kept in one folder precisely so it can be lifted out
> into its own repository and shared between projects.

## Why this exists

Every published Firebase plugin for Godot is a third-party binary going into a
signed release build, from a repository that can be archived, retagged or
deleted underneath you — the best-known one already has been. The bridge itself
is about 150 lines of Kotlin. Owning it costs one CI step and removes the
dependency completely.

It also avoids the fragile part every other integration shares. Firebase
initialises itself from Android **string resources** (`google_app_id`,
`google_api_key`, …), which Google's `com.google.gms.google-services` Gradle
plugin normally generates from `google-services.json`. That Gradle plugin cannot
be added through any Godot export API, so the usual approach is to string-edit
the engine's generated `build.gradle`, anchored on lines that move between
engine versions. **This addon generates those resources itself**, into the build
template's own `res/` directory, and edits no Gradle file at all.

## What it does at export time

When the target is Android, the Gradle build is on, **and**
`android/build/google-services.json` exists:

1. adds `firebase-analytics` (via the Firebase BOM) to the app's dependencies,
   through Godot's own `_get_android_dependencies` API;
2. adds this addon's `bin/release/firebase-analytics-bridge-release.aar`;
3. writes `android/build/res/values/firebase_analytics_bridge.xml` with the
   Firebase configuration read out of `google-services.json` — picking the
   client block that matches **your** package name, and refusing loudly if there
   isn't one.

Without `google-services.json` it stands down entirely: no SDK, no AAR, no
resources. A project can carry the addon permanently and still ship ordinary
builds — which is what makes "Firebase on/off" a single secret in CI rather
than a branch.

## Using it in a project

1. Copy this folder to `res://addons/firebase_analytics/`.
2. Enable **Firebase Analytics** in Project ▸ Project Settings ▸ Plugins.
3. Install the Android build template (Project ▸ Install Android Build
   Template) — Firebase needs the Gradle build.
4. Put `google-services.json` from the Firebase console into `android/build/`.
5. Build the bridge AAR:
   ```
   addons/firebase_analytics/tools/build_plugin.sh release
   ```
   Needs an Android SDK (`ANDROID_HOME`/`ANDROID_SDK_ROOT`), a JDK 17+, and
   network access on the first run. It uses the Gradle wrapper that ships in the
   Godot build template, so Gradle itself does not have to be installed, and it
   compiles against the **engine's own** `godot-lib` from that template — there
   is no `org.godotengine:godot` Maven version to pin or get wrong.
6. Export as usual.

### Calling it

The plugin registers the singleton `FirebaseAnalyticsBridge`:

```gdscript
if Engine.has_singleton("FirebaseAnalyticsBridge"):
    var firebase := Engine.get_singleton("FirebaseAnalyticsBridge")
    firebase.logEvent("level_end", {"level_name": "grid_012", "success": 1})
    firebase.setUserProperty("play_style", "methodical")
    if not firebase.isReady():
        print(firebase.lastError())
```

| Method | Purpose |
|---|---|
| `logEvent(event: String, params: Dictionary)` | Log an event. Ints/floats/bools/strings are converted to what Firebase accepts; strings are truncated at 100 chars. |
| `setUserProperty(name: String, value: String)` | Set a user property. |
| `isReady() -> bool` | Whether the SDK actually started. **A plugin that is present and one that is working look identical without this.** |
| `lastError() -> String` | The last failure in words, `""` when there has been none. |

Guard every call behind `Engine.has_singleton`, or wrap it once — a build
without the plugin (the editor, CI, iOS, desktop) must keep working. SparkLogic
does this in `scripts/autoload/analytics.gd`, which is a reasonable thing to
copy: it queues events until the plugin appears, retries detection, and reports
the whole pipeline's state on a diagnostics screen.

### Event and parameter rules Firebase imposes

Event names: ≤ 40 characters, letters/digits/underscores, not starting with a
digit, and not one of Google's reserved prefixes (`firebase_`, `google_`,
`ga_`). Parameter names: ≤ 40 characters. String values: 100 characters, which
this plugin truncates for you. A number's type is registered from the first
event that carries it, so a parameter must not arrive as an int on one build and
a float on the next — the bridge widens ints to long and floats to double for
exactly that reason.

## Layout

```
firebase_analytics/
├── plugin.cfg              Godot addon manifest
├── export_plugin.gd        Editor-only: injects AAR + SDK, generates config resources
├── tools/build_plugin.sh   Builds the AAR (used by CI and by hand)
├── android/                The bridge itself
│   ├── build.gradle.kts    AGP/Kotlin/SDK versions matched to Godot 4.7's template
│   ├── settings.gradle.kts
│   ├── .gdignore           Keeps the Godot editor out of the build sources
│   └── src/main/…/FirebaseAnalyticsBridge.kt
└── bin/                    Built AARs (generated; not committed)
```

`export_plugin.gd` has no `class_name` on purpose: that would register an
editor-only script in the project's global class list, and an exported game then
tries to load it against a release template that has no `EditorPlugin` in it.
Exclude `addons/*` from the export preset's PCK filter too — nothing in here
belongs inside the game package.

## Keeping it working

- **The singleton name is stated in three places and they must agree**:
  `FirebaseAnalyticsBridge.PLUGIN_NAME` (Kotlin), `godotPluginName`
  (`android/build.gradle.kts`, which stamps it into the manifest metadata Godot
  scans), and whatever your game looks for. Change one, change all three.
- **The Firebase version is stated in two places and they must agree**:
  `firebaseBom` in `android/build.gradle.kts` (what the bridge compiles
  against) and `FIREBASE_DEPENDENCIES` in `export_plugin.gd` (what the app
  ships). Bump them together.
- **On a Godot upgrade**, rebuild the AAR after installing the new Android build
  template. The build script re-extracts the engine library from it, so the
  bridge follows the engine automatically.
- **If `google-services.json` is removed** from a build directory you have
  already exported once, delete the generated
  `android/build/res/values/firebase_analytics_bridge.xml` as well (or
  reinstall the build template, which regenerates the directory). The addon
  stands down when the config is gone but does not reach into a build it is no
  longer part of.

## Testing

`export_plugin.gd`'s config parsing is pure and covered by a headless test in
the host project (`tools/verify_firebase_config.gd` in SparkLogic): the happy
path, multi-app configs, five rejection cases, and the generated XML's
well-formedness. The AAR build itself is verified by actually building it in CI.

Verify events end to end on a device with:

```
adb shell setprop debug.firebase.analytics.app <your.package.name>
```

then watch Firebase console ▸ Analytics ▸ **DebugView**, which shows events
within seconds. The standard reports take hours, and an empty report is not
evidence of anything for most of a day.
