# Mobile Services for Godot 4

One addon that gives a Godot mobile game analytics, ads, purchases, a player
identity and a consent flow — on **Android and iOS**, from **one GDScript API**,
with the **native sources in this repository** and no downloaded plugin binaries
anywhere in the chain.

Copyright © 2026 Bilal Safdar. MIT — see `LICENSE`.

```gdscript
func _ready() -> void:
    MobileServices.initialized.connect(_on_ready)
    MobileServices.ads.reward_earned.connect(_on_reward)
    MobileServices.initialize()

func _on_ready(_report: Dictionary) -> void:
    MobileServices.analytics.log_event("game_started")
    print(MobileServices.player.get_id())

func watch_ad_for_a_life() -> void:
    MobileServices.ads.show("rewarded_extra_life")

func _on_reward(_placement: String, _type: String, amount: int) -> void:
    give_extra_lives(amount)
```

That is the whole integration. No ad unit ids in your game's source, no
platform branches, no `Engine.has_singleton` guards, and nothing that crashes
when you press play on your PC.

---

## What it does

| | |
|---|---|
| **Analytics** | Firebase Analytics, with Firebase's silent naming rules checked before the SDK drops your event. Events sent before the SDK is ready are queued, not lost. |
| **Crash reporting** | Firebase Crashlytics, plus breadcrumbs and non-fatals from GDScript. |
| **Remote Config** | Change numbers after you have shipped. Reads never block. |
| **Ads** | AdMob or AppLovin MAX behind **one placement-based API**. Banner, interstitial, rewarded, rewarded interstitial, app-open. Retry with backoff, per-impression revenue, and a reward that fires **once**, only when the network says the player earned it. |
| **Purchases** | Google Play Billing and StoreKit. Consumables, non-consumables, subscriptions with offers, pending purchases, restore. Reduced to `has_entitlement("remove_ads")`. |
| **Player identity** | One stable id from first launch, whether or not the player signs in. Play Games on Android, Game Center on iOS. |
| **Achievements, leaderboards, cloud saves** | Play Games Services and Game Center, same API. |
| **Consent** | Google UMP for the EEA/UK form, Apple's ATT prompt, and Consent Mode passed through to Firebase. |
| **Diagnostics** | One dictionary that answers almost every "it does not work on my phone", with no ids, keys or tokens in it. |

Every one of those is **optional**, per game, in one config file. A game that
wants analytics and nothing else ships no ad SDK, no billing library and no Play
Games client.

## Why it exists

Every published Firebase or AdMob plugin for Godot is a third-party binary going
into a signed release build, from a repository that can be archived, retagged or
deleted underneath you — the best-known one already has been. The bridges here
are a few hundred lines of Kotlin and Objective-C++. Owning them costs one CI
step and removes the dependency completely.

It also avoids the fragile part every other Firebase integration shares.
Firebase initialises from Android **string resources**, which Google's
`com.google.gms.google-services` Gradle plugin normally generates — and that
Gradle plugin cannot be added through any Godot export API. The usual workaround
is to string-edit the engine's generated `build.gradle`, anchored on lines that
move between engine versions. **This addon generates those resources itself** and
edits no Gradle file at all. See `docs/architecture.md`.

## The idea: one addon, many games

There is not one ad unit id, product id or API key anywhere in
`addons/mobile_services/`. They all live in **`res://mobile_services.cfg`**,
which each game writes for itself:

```ini
[ads]
enabled = true
provider = "admob"          # ← switch to "applovin_max" and nothing else changes
android_app_id = "ca-app-pub-…~…"

[ads.placement.rewarded_extra_life]
format = "rewarded"
admob_android = "ca-app-pub-…/…"
admob_ios     = "ca-app-pub-…/…"

[iap.product.remove_ads]
type = "non_consumable"
entitlement = "remove_ads"
```

Adding this SDK to a fourth game is copying a folder and writing that file.

## Requirements

| | |
|---|---|
| Godot | 4.3 – 4.5 (developed against 4.4) |
| Android | minSdk 21, compileSdk 34, `arm64-v8a` and `armeabi-v7a` |
| iOS | 14.0+, arm64 |
| To build the Android plugins | JDK 17, an Android SDK, the Godot Android build template |
| To build the iOS plugins | macOS, Xcode, SCons, a Godot source checkout |

Exact dependency versions are in `docs/versions.md`.

## Install

1. Copy `addons/mobile_services/` into your project's `addons/`.
2. Copy `addons/mobile_services/mobile_services.cfg.template` to
   `res://mobile_services.cfg` and edit it.
3. Enable **Mobile Services** in *Project ▸ Project Settings ▸ Plugins*. This
   registers the `MobileServices` autoload for you.
4. Build the native plugins:
   ```
   addons/mobile_services/tools/build_android.sh release
   ```
   (iOS needs a Mac: `tools/build_ios.sh` — see `docs/ios.md`.)
5. Export.

`docs/installation.md` has the full version, including Firebase, AdMob,
AppLovin, Play Billing and Play Games setup. `docs/quick_start.md` is the
five-minute one.

## Documentation

| | |
|---|---|
| [Quick start](docs/quick_start.md) | Five minutes to your first event and your first ad. |
| [Installation](docs/installation.md) | The full setup, per service. |
| [Configuration](docs/configuration.md) | Every key in `mobile_services.cfg`, and environments. |
| [API reference](docs/api.md) | Every method and signal. |
| [Architecture](docs/architecture.md) | How it fits together, and why. |
| [Ads](docs/ads.md) | Placements, rewarded ads, mediation, test ads. |
| [Purchases](docs/iap.md) | Products, entitlements, subscriptions, server validation. |
| [Player identity](docs/player_identity.md) | Ids, sign-in, and what is deliberately not collected. |
| [Play Games & Game Center](docs/play_games.md) | Where the two platforms differ. |
| [Privacy & consent](docs/privacy.md) | UMP, ATT, Consent Mode, Data Safety. |
| [Security](docs/security.md) | What ships in an app and what must never. |
| [iOS](docs/ios.md) | Building the iOS plugins, and their current status. |
| [Testing](docs/testing.md) | The manual matrix, and the headless tests. |
| [Troubleshooting](docs/troubleshooting.md) | Every failure with a known cause. |
| [Release](docs/release.md) | Cutting a version. |
| [Migration](MIGRATION.md) | Upgrading a game from the 1.x Firebase-only addon. |
| [Changelog](CHANGELOG.md) | What changed. |
| [Contributing](CONTRIBUTING.md) | Adding a service or an ad network. |

## Running the demo

This repository **is** a Godot project. Open it, press play, and you get a
screen with a button for every service. On a PC every one of them answers
"unavailable on Linux" and the game keeps running — which is the behaviour the
whole SDK is built around.

## Status

| | |
|---|---|
| GDScript SDK | Complete. Covered by headless tests in CI. |
| Android native | Complete. All six modules built from source by CI on every push, both variants, against the engine's own library. |
| iOS native | **Preview.** Complete sources, not yet built in CI — building them needs macOS and Xcode, which this repository's CI does not have. Build and verify on a Mac before shipping. See [`docs/ios.md`](docs/ios.md). |

## Support

Open an issue. Paste `MobileServices.get_diagnostics_text()` into it — it names
your SDK version, engine version, device, which native plugins are present,
which services started and what the last failure of each was, and it contains no
ids, keys or tokens.
