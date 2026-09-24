# Changelog

Semantic versioning: `MAJOR.MINOR.PATCH`. See
[`docs/release.md`](docs/release.md).

## 2.1.2

### Fixed

- **Google Play rejects every release that carries IAP.** Play now refuses
  bundles built with Play Billing Library 7 ("Artifact … uses Play Billing
  Library version 7.1.1 and must update to at least version 8.0.0") — the
  publish step of SparkLogic's release pipeline failed on it. `billing-ktx` is
  now `8.0.0`, in both places it is declared (`android/billing/build.gradle.kts`
  and `editor/android_export_plugin.gd`).
- The one API Billing 8 changed that the bridge uses:
  `queryProductDetailsAsync` now hands the listener a `QueryProductDetailsResult`
  instead of a bare list. The bridge reads `productDetailsList` from it; the
  catalogue it signals to GDScript is unchanged, so games need no code change.

## 2.1.1

CI was red on every run, and a second audit pass on top of 2.1.0's found
more real bugs — some of them in code CI's own breakage had been hiding.

### Fixed

- **The Android CI workflow has failed on every run.** `android-actions/
  setup-android@v3` defaults to installing the legacy `tools` SDK package,
  which Google has removed from its repository entirely — `sdkmanager`
  failed immediately, before the job built anything. Pinned the action's
  `packages` input to `platform-tools`, which is all that step needs; the
  real platform/build-tools are installed explicitly in the next step.
- **`android/build.gradle.kts` still declared `minSdk = 21`**, left over
  from when this repo targeted Godot 4.4.1. Godot 4.6's own template
  requires `minSdk 24`. Fixed, along with every doc that quoted the old
  number.
- **`tools/build_ios.sh` defaulted `GODOT_VERSION` to `4.4-stable`**, so
  following `docs/ios.md`'s own example would build the iOS native plugins
  against a Godot source checkout that no longer matches the 4.6 toolchain
  the rest of the repo targets. Moved the default and the doc example to
  `4.6-stable`.
- **iOS `show_banner()` ignored a changed banner position** on a banner
  already on screen, contradicting the documented "idempotent, moves the
  banner" contract — the same class of bug already fixed for Android in
  2.1.0, just not carried over to iOS.
- **iOS banners never fired `ad_shown` or `ad_clicked`.** `MSAdSlot`
  declared `GADBannerViewDelegate` conformance but never implemented
  `bannerViewDidRecordImpression:`/`bannerViewDidRecordClick:` — an
  unimplemented optional protocol method is a silent no-op in Objective-C,
  not a compile error, so this shipped and ran fine while quietly dropping
  both signals for every banner.
- **iOS Remote Config could return unreliable values.**
  `remote_config_get_all()` called `-allKeysFromSource:` — which takes a
  plain `NSInteger`, not an object — through `performSelector:withObject:`,
  which can only ever pass an `id`. Boxing `0` as `@(0)` handed the method a
  pointer where it expected a raw integer: undefined behaviour, not a
  merely-wrong-but-safe value. Fixed with `NSInvocation`, the same pattern
  this file already used correctly for `setCrashlyticsCollectionEnabled:`.
- **iOS subscriptions never expired.** StoreKit 1 gives no receipt-free way
  to ask whether a subscription is still active, and `expires_at` was left
  at `0` — which `MSIap.has_entitlement()` treats as "never expires" — so a
  subscription entitlement stayed granted forever even after the player
  cancelled and it lapsed. Estimated now from the product's own
  `subscriptionPeriod` plus the transaction date; server-side receipt
  verification remains the exact answer for a game that needs one.
- **iOS double-delivered a restored purchase.** A transaction restored
  while `queryPurchases()` was in flight was reported once immediately via
  `purchase_updated` and again batched into `purchases_queried`, running
  the GDScript purchase handler — and `consume()`/`acknowledge()` — twice
  for the same purchase on every restore, including the automatic one at
  every launch.
- **iOS `consume()`/`acknowledge()` on an unknown token silently did
  nothing**, leaving the caller waiting on a signal that would never
  arrive. Now reports `purchase_failed`, matching Android.
- **iOS `increment_achievement()` swallowed Game Center failures** — its
  completion handler was `nil`. Now reports the same way
  `unlock_achievement()` already does.
- **Android `purchase_consumed`/`purchase_acknowledged` always reported an
  empty store id**, because Play's `consume`/`acknowledge` callbacks only
  ever hand back a bare token. Now remembered per-token from every purchase
  the plugin has seen.
- **Two `BillingClientStateListener` callbacks could crash the app on an
  uncaught exception** — `onBillingSetupFinished` and
  `onBillingServiceDisconnected` were the only two SDK callbacks in the
  Android billing bridge not wrapped in the file's own exception-safety
  helper.

## 2.1.0

Bug fixes found by an audit of every native module, plus one small addition
they turned up a gap next to.

### Fixed

- **iOS shipped every purchase as already acknowledged.** The StoreKit bridge
  reported `"acknowledged": true` on every transaction, which is exactly the
  value that makes the GDScript purchase handler skip calling `acknowledge()`
  — the only thing that reaches `finishTransaction:` for a non-consumable or
  a subscription. The result: those purchases were never finished, and
  StoreKit redelivered them on every launch. Consumables were unaffected —
  they finish through `consume()` unconditionally. Now reported as `false`,
  which is what makes the existing GDScript logic finish them as designed.
- **iOS Consent Mode only denied one of four defaults.** The Android manifest
  has always defaulted all four Consent Mode flags (`analytics_storage`,
  `ad_storage`, `ad_user_data`, `ad_personalization_signals`) to denied until
  a consent decision is made; the iOS Info.plist was only writing the last of
  the four, so an EEA build on iOS collected analytics and ad data before
  the UMP form ever ran. All four are now written.
- **A re-shown banner ignored its new position on Android.** `show_banner()`
  is documented as idempotent — calling it again just moves the banner if the
  position changed — but the reuse path (the ad view already exists) only
  toggled visibility, on both the AdMob and AppLovin MAX providers. Fixed by
  giving `BannerHost` a `reposition()` that updates the container's gravity.
- **A real Play Games / Game Center sign-in failure was always reported as
  the player cancelling.** A misconfigured `play_games_app_id`, a
  `DEVELOPER_ERROR`, or no network all produced `MSError.USER_CANCELLED`
  rather than `MSError.INITIALIZATION_FAILED`, hiding genuine integration
  bugs behind a code games are told to ignore. Both platforms now classify
  the failure the same way `operation_failed` already did for every other
  call.
- **Two of five ad formats never reported revenue on iOS.**
  `rewarded_interstitial` and `app_open` loaded without a `paidEventHandler`,
  so `ad_revenue_paid` — and the Firebase `ad_impression` event auto-sent
  from it — silently never fired for them, while all five formats reported
  correctly on Android.
- **Every full-screen ad and every banner leaked on iOS.** Each one's
  `paidEventHandler` block was stored on the ad object itself and captured
  that same object strongly, a self-retain cycle that kept it alive forever
  regardless of `destroy_ad()`. All five ad objects now capture weakly.
- **Remote Config throttling was always reported as a network error on
  iOS.** Android already told throttling (you already have the cached
  values — not a fault) apart from an actual network failure; the iOS
  bridge reported both as `NETWORK_ERROR`, which can turn an ordinary
  "already fetched recently" into a bogus "check your connection" in a
  game's UI.

### Added

- **`MobileServices.play_games.load_achievements()`**, on both platforms.
  The signal it answers on (`achievements_loaded`) and its GDScript handler
  already existed on both native sides but nothing ever emitted it; games
  connecting to it waited forever. Answers with each achievement's id,
  unlock state and progress, for a custom achievements screen instead of
  `show_achievements()`'s platform UI.

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
