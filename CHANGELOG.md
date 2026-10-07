# Changelog

Semantic versioning: `MAJOR.MINOR.PATCH`. See
[`docs/release.md`](docs/release.md).

## 2.3.2

### Fixed

- **The store stayed OFFLINE on a phone that was online (2.3.1).** The device
  log behind 2.3.1 had a second half: the connection to Play dropped seconds
  after "billing connected", and the attempt to rebuild it never answered.
  2.3.1 waited on that attempt for the rest of the session -- `connect()`
  refused to start over while it was CONNECTING, `reconnect()` (the store's TRY
  AGAIN) did the same, and every price query was answered SERVICE_DISCONNECTED
  ("Service connection is disconnected."). An attempt Play has not answered in
  15 s is now ended, a new `BillingClient` is built, and `billing_failed` tells
  the game (code -3) so its store can say so and ask again. Retries are the
  same six with back-off, then `reconnect()`.
- **A failed price query wiped the prices.** The bridge followed every failed
  query with an empty `products_loaded`, which `MSIap` took as "Play sells
  nothing": prices a game already showed disappeared after one network blip.
  A failed query now reports `products_load_failed` only, and a catalogue is
  sent only when Play answered.
- **Queries no longer go to a client that is not connected.** Prices, restores
  and purchases asked for while billing is reconnecting answer
  SERVICE_DISCONNECTED straight away and start a connection; `billing_ready`
  asks for prices and restores again once it is up.
- **Both queries are counted before either is sent**, so a Play answer that
  arrives at once cannot report half a catalogue or half of what an account
  owns.
- `reconnect()` now also works when the client was never built (no activity
  yet at start-up) or was closed.
- **A pack is granted before it is consumed.** `MSIap` asked Play to consume a
  pack (or acknowledge a one-time product) and only then emitted
  `purchase_completed`, so the consume could be on its way while the coins
  existed only in memory -- and a consumed purchase is never delivered again.
  The game is now told first; `purchase_completed` is answered synchronously,
  so the grant and its save happen before the store is finished with.

### Tests

- `tests/test_iap.gd`: a failed price query keeps the prices already loaded,
  an abandoned connection closes the store, and `purchase_completed` comes
  before the consume.

## 2.3.1

### Fixed

- **The store read OFFLINE right after billing connected (2.3.0).** 2.3.0 turned
  on Billing 8's automatic service reconnection on top of the bridge's own
  reconnect, so the same client was connected from two places. Starting a
  connection while one is already CONNECTING is answered with DEVELOPER_ERROR
  "Client is already in the process of connecting to billing service", and
  every one of those answers reached the game as `billing_failed` -- seen on a
  device as "billing connected" followed by a stream of failures, a store
  marked offline, and prices that never loaded. Automatic reconnection is off
  again, a connection is only started from DISCONNECTED, a failed setup answer
  that arrives while the client is connected or connecting is ignored, and
  `MSIap` ignores a `billing_failed` while the native client reports itself
  ready.

## 2.3.0

A store that cannot get stuck, and products made from the repository.

### Added

- **`tools/play_products.py`** creates a game's in-app products on Google Play
  from `mobile_services.cfg` and a catalogue file (title, description, USD
  price), through the Play Developer API's one-time products: checks the two
  files agree, creates what is missing, prices every country with Google's own
  conversion, and puts it on sale. Existing products are never changed unless
  asked (`--mode sync`). Standard library only; `tests/test_play_products.py`
  runs it against a fake Play in CI.
- **`MSIap.reconnect()`** connects to Play again after a setup that gave up, or
  re-announces `iap_ready` when connected. Meant for a store screen to call as
  it opens.
- **`restore_failed(error)`**: Play could not say what the account owns.
- **`purchase_finish_failed(product, error)`**: a consume or acknowledge did not
  land after the player was granted. It used to arrive as `purchase_failed`
  with an empty product, which a game could show the player as a failed
  purchase right after a successful one.
- **`purchase["restored"]`** is true for a purchase the store had already
  finished in an earlier session.
- `get_purchase_in_flight()`.

### Fixed

- **A failed billing setup was never retried.** Off-line at launch, Play
  updating, or the Play account not signed in yet left the store shut for the
  whole session. The bridge now retries six times with back-off, uses Billing
  8's automatic service reconnection, and `reconnect()` asks again on demand.
- **A purchase sheet that never answered blocked every later purchase** with
  "already in progress" until the game restarted. After 180 s it no longer
  blocks; a late answer is still delivered. A billing failure clears it too.
- **A restore that half-failed revoked purchases.** If either of Play's two
  purchase queries failed, the other half was taken as everything the account
  owns and the rest was revoked. A failed query now revokes nothing and is
  reported on `restore_failed`.
- **A price list that failed to load stayed failed.** It is asked for again
  after 5 s, 20 s and 60 s on each connection.
- **A consume or acknowledge that failed waited for the next launch.** It is
  retried through a restore 15 s later, up to three times a session.
- **Every launch logged each owned non-consumable as a new `purchase`** with
  `analytics/auto_iap_events` on, because the launch-time restore re-delivers
  it. Restored purchases are no longer logged as revenue.

### Tests

- `tests/test_iap.gd`: restored purchases, an unanswered sheet, billing failure
  clearing the sheet, a failed restore revoking nothing, finish failures (both
  bridges), `reconnect()`.

## 2.2.0

The billing side brought up to date for the games' stores going live.

### Changed

- **Play Billing Library 9.1.0** (was 8.0.0), the current release. The plain
  `billing` artifact replaces `billing-ktx` in both places it is declared
  (`android/billing/build.gradle.kts` and `editor/android_export_plugin.gd`):
  the bridge uses no Kotlin extension, and `-ktx` added kotlinx-coroutines to
  every APK and a Kotlin stdlib newer than the engine's pinned compiler to the
  bridge's classpath. Billing 9 requires `targetSdk` 35+; every game sets 36.

### Added

- **Why a product is not on sale.** Billing 8+ reports, per product, why Play
  could not return it. The bridge now forwards that (`products_unfetched`), and
  `MSIap` logs a warning naming the product and what to check, emits
  `products_unavailable(products)`, answers `get_unavailable_products()`, and
  lists them in the diagnostics dump. A mistyped id or an inactive product used
  to be a BUY button that silently never appeared.
- **One-time products with several purchase options** (Billing 8's new model,
  which is what the Play Console creates now). When no option is marked
  backwards compatible, `oneTimePurchaseOfferDetails` is null and the product
  showed no price; the bridge falls back to the first listed offer and buys
  exactly that one. An `offer_token` passed to `purchase()` is honoured for
  one-time products too.
- **Billing 8's sub-response codes** lead the `purchase_failed` message:
  "payment declined: insufficient funds", "this account is not eligible for the
  offer".

### Fixed

- **`ITEM_ALREADY_OWNED` left the player stuck.** A consumable whose consume
  never reached Play (a dropped connection, the app killed in between) cannot
  be bought again, and every retry failed the same way. The refusal is still
  reported, and the SDK now also re-reads what the account owns, which delivers
  and consumes the stuck purchase. Same for a one-time product bought before a
  reinstall and not yet restored.

### Tests

- `tests/test_iap.gd` drives `MSIap` with a double shaped like the Android
  bridge: unavailable products, a later query clearing them, the
  already-owned restore, a cancel, and a consumable re-reported with the same
  token. `MSConfig.platform_override` lets those run on the Linux CI runner.

## 2.1.4

### Fixed

- **AdMob impressions and revenue were counted twice in Firebase.** With
  `analytics/auto_ad_events` on, the SDK logged `ad_impression` (with `value`
  and `currency`) for every AdMob paid event. An AdMob app linked to its
  Firebase project already logs that event itself, so every impression and
  every cent of AdMob revenue appeared twice. New key
  `analytics/admob_linked_to_firebase` (default `true`): the SDK leaves AdMob's
  `ad_impression` to AdMob and still sends it for networks that do not log it
  themselves (AppLovin MAX). `MSAnalytics.sends_ad_impression()` is the rule,
  tested in `tests/test_analytics_rules.gd`.

## 2.1.3

### Fixed

- **Every native call on Android was dropped: no Firebase events, no ads, no
  purchases, no consent.** `MSNative.call_method` asked `Object.has_method`
  whether the plugin had a method before calling it. An Android plugin reaches
  GDScript as a `JNISingleton`, whose `@UsedByGodot` methods live in its JNI
  method map, and `Object.has_method` (not virtual) only looks at ClassDB, an
  attached script and `free`. So it answered false for `initializeFirebase`,
  `logEvent`, `setConsent`, `initializeAds`, `loadAd`, `initializeBilling`,
  `purchase`, `requestConsentUpdate` and every other method, and each one
  returned its fallback with a "missing from the installed native plugin"
  warning. The AABs were complete the whole time, which is why CI's artifact
  checks stayed green. The bridge now asks through `MSNative.answers()`:
  `has_method` first (iOS and GDScript objects), then the engine's own
  `has_java_method` (Android).
- `tests/test_native.gd` drives that decision with a double shaped the way the
  engine hands an Android plugin over, which is the case no desktop run can
  reach.

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
