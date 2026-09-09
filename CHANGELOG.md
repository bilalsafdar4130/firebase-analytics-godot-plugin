# Changelog

Semantic versioning: `MAJOR.MINOR.PATCH`. See
[`docs/release.md`](docs/release.md).

## 2.0.0

The addon becomes a general mobile services SDK for Godot games, on Android and
iOS, instead of a Firebase Analytics bridge for Android.

**Existing 1.x games keep working without a source change** — the
`FirebaseAnalyticsBridge` singleton and all six of its methods are still there.
See [`MIGRATION.md`](MIGRATION.md).

### Added

- **A GDScript SDK** behind one autoload, `MobileServices`, with a service per
  area: `analytics`, `crash`, `remote_config`, `ads`, `iap`, `player`,
  `play_games`, `consent`.
- **One configuration file per game**, `res://mobile_services.cfg`, with
  environment overlays (`mobile_services.development.cfg`). There is no ad unit
  id, product id or key anywhere in the addon.
- **Ads** behind a placement-based API, with AdMob and AppLovin MAX providers on
  Android. Banner, interstitial, rewarded, rewarded interstitial and app-open;
  retry with backoff; per-impression revenue; a reward that fires at most once
  per impression and only when the network reports one.
- **Purchases** over Google Play Billing 7 and StoreKit: consumables,
  non-consumables, subscriptions with offers, pending purchases, restore, and an
  entitlement model (`has_entitlement("remove_ads")`) that hides the stores'
  vocabulary.
- **Player identity**: one stable anonymous id from first launch that does not
  change when a player signs in, backed by SharedPreferences on Android and the
  keychain on iOS.
- **Play Games Services and Game Center** behind one API — sign-in, achievements,
  leaderboards, cloud saves, and Play Games' server-side auth code.
- **Consent**: Google UMP, Apple's ATT prompt, and Consent Mode flags derived
  from the IAB TCF purposes and passed to Firebase.
- **Crashlytics and Remote Config**, both optional.
- **iOS support**, preview: complete Objective-C++ sources for all six modules,
  `.gdip` descriptors, an SConstruct and a build script — not built by CI, which
  has no macOS. See [`docs/ios.md`](docs/ios.md).
- **Diagnostics**: `MobileServices.get_diagnostics()`, safe to paste into a bug
  report, with every secret-shaped value redacted.
- **Headless tests** in CI, and a demo project that is this repository.
- **Documentation**: a README, seventeen pages under `docs/`, runnable examples,
  and a migration guide.

### Changed

- **Six native modules instead of one.** The export plugin ships only the ones a
  game's config enables, so an analytics-only game contains no ad SDK, no billing
  library and no Play Games client.
- **The native boundary carries primitives and JSON only.** A signal parameter
  type the running engine cannot marshal fails at plugin registration and takes
  the whole plugin down; primitives cannot.
- **Every call is safe everywhere.** `Engine.has_singleton` guards in game code
  are no longer needed: the SDK answers with a failure dictionary in the editor,
  on desktop, and in a build exported without the plugins.
- **Firebase event names are validated** rather than passed through for Firebase
  to drop silently, and events logged before the SDK is ready are queued.
- **The `AD_ID` permission** is now kept or removed based on `ads/enabled` rather
  than on whether a separate ads addon is installed.
- Repository restructured: `addons/mobile_services/`, `docs/`, `demo/`,
  `examples/`, `tests/`. The repository root is itself a working Godot project.
- `tools/build_plugin.sh` → `tools/build_android.sh`, now able to build a subset
  of modules.

### Fixed

- Analytics events logged during start-up were lost; they are queued now.
- A failure inside a native callback could reach the engine across JNI. Every
  entry point and every callback now catches `Throwable`.
- Ad objects and banner views were not released on activity destruction.

### Known limitations

- The iOS native plugins are **unverified**: no macOS in CI. Build and test them
  on a Mac before shipping.
- AppLovin MAX is Android-only; the iOS ad plugin refuses any provider but AdMob
  rather than pretending.
- Crashlytics native symbol upload is not automated on either platform.
- Entitlements are cached on the device and are editable there. Verify on a
  server for anything with meaningful revenue —
  [`docs/iap.md`](docs/iap.md#the-security-limit-stated-plainly).

## 1.0.0

- Firebase Analytics for Godot 4 on Android: a Kotlin bridge built from source,
  an export plugin that injects the SDK and generates Firebase's configuration
  resources from `google-services.json` without editing any Gradle file, and
  privacy defaults written into the manifest.
