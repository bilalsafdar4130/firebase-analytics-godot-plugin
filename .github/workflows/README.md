# CI

Three workflows, split by what they cost.

| Workflow | Runs when | Proves | Roughly |
|---|---|---|---|
| `gdscript.yml` | any `.gd`, `.cfg`, `project.godot`, or anything under `addons/`, `tests/`, `demo/`, `examples/` | Every script in the project compiles — `examples/` and `demo/` included — and the pure half of the SDK behaves: config parsing and validation, the `google-services.json` reader, Firebase's naming rules, the error vocabulary, and that the five places stating the SDK version agree. | 20 s |
| `android.yml` | only `addons/mobile_services/android/**` or its build script | All six modules compile from source against the engine's own library, both variants. Twelve AARs, each checked to exist. | ~3 min cold, well under 1 min warm |
| `release.yml` | a `v*` tag | Calls `android.yml` and attaches the release AARs to the GitHub release. | |

## Why they are split

The Android build is two orders of magnitude more expensive than the script
check, and nothing outside `android/` can change what it produces. Together in
one workflow, a typo fix in a doc paid for a Gradle build.

The two path filters are deliberately asymmetric:

- **`android.yml` is narrow.** It costs minutes, so it runs only when its own
  inputs change.
- **`gdscript.yml` is wide.** It costs seconds, so running it unnecessarily
  costs nothing, while skipping it when it mattered means a broken SDK reporting
  green — which has already happened once here.

## What is cached, and why it needed to be

The Android job used to spend most of its time on work with no result:

- A **~1 GB export-templates archive**, downloaded every run to extract one file
  from it. Now fetched once per Godot version and kept — the archive is immutable
  for a given release, so it is a cache hit until the engine is upgraded.
- **A Godot editor binary this job never ran.** It was there for
  `--install-android-build-template`, which hung; the unzip that replaced it
  needs no engine binary, so it is gone.
- **A cold Gradle** resolving AGP, Kotlin and six SDKs from scratch, keyed now on
  the build files so a run that changes no dependency re-resolves nothing.

## What is not covered

- **The iOS plugins.** They are static libraries compiled against the engine's
  C++ headers with Xcode, which needs macOS — see [`docs/ios.md`](../../docs/ios.md),
  where they are marked preview for exactly this reason.
- **Anything needing a device**: an AAR actually loading, a rewarded ad paying
  once, a purchase from a Play track, a minified release build. That is the
  manual matrix in [`docs/testing.md`](../../docs/testing.md), and it is the
  list to work before shipping.
