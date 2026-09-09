# Architecture

## The shape of it

```
  your game
      │  MobileServices.ads.show("rewarded_extra_life")
      ▼
┌─────────────────────────────────────────────────────────────┐
│  GDScript (addons/mobile_services/runtime/)                 │
│                                                             │
│  MobileServices ── the facade, the start-up order, and the  │
│      │             wiring between services                  │
│      ├── MSAnalytics   MSCrash   MSRemoteConfig             │
│      ├── MSAds ────────── placements, retry, the reward rule│
│      ├── MSIap ────────── entitlements, pending, restore    │
│      ├── MSPlayer  MSPlayGames                              │
│      └── MSConsent                                          │
│                                                             │
│  MSConfig  MSLog  MSError  MSNative  MSService              │
└──────────────────────────┬──────────────────────────────────┘
                           │  strings, ints, bools, floats and JSON
      ┌────────────────────┴────────────────────┐
      ▼                                         ▼
┌──────────────────────┐              ┌──────────────────────┐
│ Android (Kotlin)     │              │ iOS (Objective-C++)  │
│ 6 AARs, one per      │              │ 6 xcframeworks,      │
│ service              │              │ same singleton names │
└──────────────────────┘              └──────────────────────┘
```

The GDScript half is most of the SDK. That is deliberate: it is the half that
can be read, changed and tested without a Gradle build or a Mac, so every rule
that is really a *policy* lives there — the reward rule, the retry backoff, the
entitlement bookkeeping, the placement vocabulary, the error translation. The
native halves do as little as possible: call the SDK, report what happened.

## Four decisions worth explaining

### 1. Six native modules, not one

Each service is its own AAR (and its own xcframework). The export plugin reads
`mobile_services.cfg` and ships **only the modules the game enables**, with only
their Maven coordinates.

A game with analytics and nothing else therefore contains no ad SDK, no billing
library and no Play Games client. That is a couple of megabytes, a shorter
permission list, and one less thing to explain on a Play Data Safety form. It
also means an unused SDK cannot break a build: a missing class can only throw if
something references it, and nothing does when its module is not there.

Within the ads module the two providers are one further step down the same idea —
`AdMobProvider` and `AppLovinProvider` are separate classes reached after a
`Class.forName` check, because Android resolves a class's references when the
class is first loaded. An AdMob build never loads a class that mentions
AppLovin.

### 2. The boundary carries primitives and JSON, nothing else

Godot's Android and iOS plugin bridges marshal a documented handful of types, and
the exact set has moved between engine versions. A signal declared with a
parameter type the running engine cannot marshal fails at plugin **registration**
— which takes the whole plugin down rather than one call.

So every native signal in this SDK carries only strings, integers, booleans and
floats. Anything structured — a purchase, an ad's revenue, the Remote Config
snapshot — travels as a JSON string and is decoded in `MSService.parse_object`.
It costs a parse per event, which is nothing next to the network call that
produced it, and it cannot fail in a way that hides the plugin.

### 3. Nothing can crash a game that is missing a plugin

`MSNative` is the only thing in the SDK that touches an engine singleton. It
checks `Engine.has_singleton`, checks `has_method` before every call, and answers
with a caller-supplied default when either fails.

`MSService.guard()` sits in front of every public method and answers with one of
three failures: the SDK is not initialised, this service is off in the config, or
the native plugin is not in this build. Written once, it is why the whole SDK
runs unchanged on a desktop machine — which is where most of a game is actually
developed — and why a game running last release's AAR against this release's
GDScript gets a named missing method rather than a crash on a player's device.

### 4. Firebase's config resources are generated, not injected

`firebase-common` ships a ContentProvider that runs before the app's first
Activity and calls `FirebaseApp.initializeApp()`, which reads its configuration
out of Android **string resources** — `google_app_id`, `google_api_key` and
friends. Google's `com.google.gms.google-services` Gradle plugin normally
generates those from `google-services.json`, and that Gradle plugin cannot be
added through any Godot export API.

Every other Godot Firebase integration therefore string-edits the engine's
generated `build.gradle`, anchored on lines that move between engine versions.
This addon generates the same resources itself, into the build template's own
`res/` directory — which Godot's `build.gradle` already declares as a resource
root — and edits no Gradle file at all. The whole integration is two documented
export APIs plus one generated XML file, and it is covered by
`tests/test_firebase_resources.gd`.

## Start-up order

`MobileServices.initialize()` is not a loop over services. The order is load
bearing:

1. **Config.** A file with errors in it stops everything: every service would
   otherwise start with wrong ids and report to nothing.
2. **Player identity**, because everything else may want to tag itself with it.
3. **Consent**, because Google requires a decision before the ad SDK's first
   request in the EEA, and Firebase's collection defaults to denied in the
   manifest until something grants it.
4. **Analytics, crash, remote config, purchases, Play Games** — all immediately.
   Analytics starts but collects nothing until consent says it may.
5. **Ads**, only once consent reports the player may see them. On a device that
   never reaches Google's consent servers this never happens, and **the game runs
   without ads** rather than not running.

`initialize()` is idempotent. Calling it again returns immediately.

## What is wired to what

These are the connections every game would otherwise write itself. Each is a
config switch, and each can be turned off and done by hand.

| Wire | Switch |
|---|---|
| player id → Firebase user id and Crashlytics key | `analytics/sync_user_id` |
| consent → Firebase Consent Mode and the ad SDK | always |
| ad impressions → Firebase `ad_impression` (with revenue) | `analytics/auto_ad_events` |
| rewarded completions → `rewarded_ad_completed` | `analytics/auto_ad_events` |
| completed purchases → Firebase `purchase` | `analytics/auto_iap_events` |
| a "remove ads" entitlement → ad serving stops | `ads/suppress_when_entitled` |

The SDK does **not** touch your UI. Suppressing ads stops the SDK serving them;
what to draw in the space is the game's decision.

## Where things live

```
addons/mobile_services/
├── plugin.cfg
├── mobile_services_editor_plugin.gd   editor entry point
├── mobile_services.cfg.template       copy this into a game
├── editor/                            export plugins (editor-only)
├── runtime/                           the SDK a game talks to
│   ├── mobile_services.gd             the MobileServices autoload
│   ├── core/                          config, log, errors, native wrapper
│   ├── services/                      one file per service
│   └── compat/                        the 1.x API, forwarded
├── android/                           six Gradle modules
├── ios/                               six Objective-C++ plugins + SConstruct
├── tools/                             build scripts
└── bin/                               built binaries (generated, not committed)
```

Nothing under `editor/` is needed at runtime, and nothing under `runtime/`
depends on the editor. `mobile_services_editor_plugin.gd` deliberately has no
`class_name`: that would register an editor-only script in the project's global
class list, and an exported game then tries to load it against a release
template that has no `EditorPlugin` in it.
