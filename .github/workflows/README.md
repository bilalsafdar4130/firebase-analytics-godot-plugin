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

Measured, both runs on the same commit range:

| Android step | Cold | Warm |
|---|---:|---:|
| set up job + checkout | 1 s | 4 s |
| `setup-java` (restores the Gradle cache) | 1 s | 7 s |
| `setup-android` | 16 s | **20 s** |
| SDK platform install | 3 s | 1 s |
| restore the build template | 0 s | 2 s |
| fetch the build template | 7 s | *skipped* |
| unpack it | 1 s | 1 s |
| **Gradle build** | **1 m 38 s** | **12 s** |
| check, upload, save caches | 9 s | 2 s |
| **total** | **2 m 19 s** | **52 s** |

**Gradle's dependency cache is the whole story.** Compiling six modules twice
over is irreducible work; re-resolving AGP, Kotlin and six SDKs is not, and not
doing it takes the build step from 98 seconds to 12.

The **template cache** is worth about seven seconds. It is kept because it costs
nothing and the archive is immutable per release — but it is not the saving it
was assumed to be. The first version of this file estimated "roughly a minute";
the measurement said otherwise, and the numbers here are measured.

On a warm run **`setup-android` is now the largest single step**, at 20 of the 52
seconds. The runner image already ships an Android SDK, so it is in principle
removable — but it is what accepts the SDK licences AGP needs, and a build three
shipped games depend on is a poor place to trade robustness for 20 seconds.
Noted here so the next person looking for time knows where it is.

The job also no longer installs Godot at all. It used to, to run
`--install-android-build-template`, which hung; the plain unzip that replaced it
needs no engine binary.

## How much the path filter actually saves, precisely

It depends on the event, and the difference is easy to get wrong:

- **On `push` to `main`,** the filter is evaluated against **that push's diff**.
  A commit touching only documentation does not start the Android job at all.
- **On `pull_request`,** it is evaluated against the **whole PR diff**, not the
  latest commit. So a PR that touched `addons/mobile_services/android/**` at any
  point keeps running the Android job on every subsequent commit, including
  documentation-only ones.

That second rule is why this very PR ran both workflows on a commit that changed
only `android.yml` and this file: the PR's cumulative diff also creates
`gdscript.yml`, which the gdscript filter matches. Working as intended — just
not the same rule as the push case.

## What is not covered

- **The iOS plugins.** They are static libraries compiled against the engine's
  C++ headers with Xcode, which needs macOS — see [`docs/ios.md`](../../docs/ios.md),
  where they are marked preview for exactly this reason.
- **Anything needing a device**: an AAR actually loading, a rewarded ad paying
  once, a purchase from a Play track, a minified release build. That is the
  manual matrix in [`docs/testing.md`](../../docs/testing.md), and it is the
  list to work before shipping.
