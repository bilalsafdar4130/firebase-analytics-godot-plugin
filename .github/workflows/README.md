# CI

Three workflows, split by what they cost.

| Workflow | Runs when | Proves | Roughly |
|---|---|---|---|
| `gdscript.yml` | any `.gd`, `.cfg`, `project.godot`, or anything under `addons/`, `tests/`, `demo/`, `examples/` | Every script in the project compiles — `examples/` and `demo/` included — and the pure half of the SDK behaves: config parsing and validation, the `google-services.json` reader, Firebase's naming rules, the error vocabulary, and that the five places stating the SDK version agree. | 20 s |
| `android.yml` | only `addons/mobile_services/android/**` or its build script | All six modules compile from source against the engine's own library, both variants. Twelve AARs, each checked to exist. | 2 m 19 s cold |
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

## Where the time actually goes

Measured on a cold Android run totalling **2 m 19 s**:

| | |
|---|---|
| setup-android | 16 s |
| SDK platform install | 3 s |
| fetch the build template | 7 s |
| unpack it | 1 s |
| **Gradle build** | **1 m 38 s** |
| save the caches | 8 s |

So **the path filter is the real saving** — it is worth the entire 2 m 19 s on
every commit that does not touch `android/`, which is most of them.

Second is **Gradle's cache**, keyed on the build files: compiling six modules
twice over is irreducible work, but re-resolving AGP, Kotlin and six SDKs is not.

The **template cache** is worth about seven seconds. It is kept because it costs
nothing and the archive is immutable per release — but it is not the saving it
was assumed to be before anyone timed it. The estimate in the first version of
this file said "roughly a minute"; the measurement said otherwise, and the
comments now carry the measured figures rather than the guess.

The job also no longer installs Godot at all. It used to, to run
`--install-android-build-template`, which hung; the plain unzip that replaced it
needs no engine binary.

## What is not covered

- **The iOS plugins.** They are static libraries compiled against the engine's
  C++ headers with Xcode, which needs macOS — see [`docs/ios.md`](../../docs/ios.md),
  where they are marked preview for exactly this reason.
- **Anything needing a device**: an AAR actually loading, a rewarded ad paying
  once, a purchase from a Play track, a minified release build. That is the
  manual matrix in [`docs/testing.md`](../../docs/testing.md), and it is the
  list to work before shipping.
