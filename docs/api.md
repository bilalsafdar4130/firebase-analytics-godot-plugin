# API reference

Everything a game touches. All of it is on the `MobileServices` autoload.

**Every method that can fail returns a Dictionary** — `{}` on success, or a
failure carrying `code`, `message`, `source`, `native_code` and `recoverable`.
It is always safe to ignore the return value; nothing here throws, and nothing
here crashes when the native plugin is missing.

```gdscript
var problem := MobileServices.ads.show("interstitial_game_over")
if not problem.is_empty():
    print(MSError.describe(problem))
```

---

## MobileServices

| | |
|---|---|
| `initialize(overrides := {}) -> void` | Starts every enabled service. Idempotent. `overrides` merges over the config file for this run: `initialize({"core": {"test_mode": true}})`. |
| `is_initialized() -> bool` | |
| `get_state() -> State` | `NOT_INITIALIZED`, `INITIALIZING`, `INITIALIZED`, `FAILED`. |
| `shutdown() -> void` | Stops everything and releases native resources. |
| `get_diagnostics() -> Dictionary` | Everything the SDK knows about itself. No ids, keys or tokens. |
| `get_diagnostics_text() -> String` | The same, formatted for a label. |
| `VERSION` | `"2.0.0"`. |

**Signals**

| | |
|---|---|
| `initialized(report: Dictionary)` | Start-up finished. Individual services may still have failed; the report says which. |
| `initialization_failed(error: Dictionary)` | Only ever a config the SDK could not read. |
| `service_ready(service: String)` | |
| `service_failed(service: String, error: Dictionary)` | |

---

## MobileServices.analytics — `MSAnalytics`

| | |
|---|---|
| `log_event(name, params := {})` | Firebase's naming rules are checked first; a name Firebase would drop is refused with a log line rather than silently discarded. Events sent before the SDK is ready are queued. |
| `set_user_property(name, value)` | Not for anything identifying a person. |
| `set_user_id(id)` | Called for you when `analytics/sync_user_id` is on. |
| `log_screen_view(name, class := "")` | |
| `set_collection_enabled(enabled)` | Turns the SDK's own automatic events on and off too. Persists across launches. |
| `is_collection_enabled() -> bool` | |
| `apply_consent(analytics_storage, ad_storage, ad_user_data, ad_personalization)` | Called for you by `MSConsent`. |
| `reset_data()` | Throws away the app instance id. What a "delete my data" button calls. |

Helpers for the events Firebase's own reports understand — ordinary `log_event`
calls, ignore them if you have your own scheme: `log_level_start(level)`,
`log_level_end(level, success)`, `log_tutorial_begin()`,
`log_tutorial_complete()`, `log_unlock_achievement(id)`,
`log_post_score(score, level := "")`, `log_ad_impression(info)`,
`log_purchase(purchase)`.

**Signals:** `analytics_ready()`, `analytics_failed(error)`,
`event_logged(name, params)`.

**Firebase's limits, applied here:** event names ≤ 40 characters,
letters/digits/underscore, not starting with a digit, not prefixed `firebase_`,
`google_` or `ga_`; parameter names ≤ 40; string values truncated at 100; at most
25 parameters. Booleans go over as `1`/`0`, because Firebase registers a
parameter's type from the first event carrying it.

---

## MobileServices.ads — `MSAds`

Placements are named in `mobile_services.cfg`. Game code never sees a unit id.

| | |
|---|---|
| `load_ad(placement)` | Ask the network for an ad. Do this a screen ahead. |
| `show(placement) -> Dictionary` | Show a loaded interstitial / rewarded / rewarded interstitial / app-open. `{}` means it was handed to the network, **not** that it was watched. |
| `is_loaded(placement) -> bool` | |
| `show_banner(placement, position := "")` | Idempotent. `position` is `"top"` or `"bottom"`; defaults to `ads/banner_position`. |
| `hide_banner(placement)` | Keeps refreshing; use `destroy` to release it. |
| `destroy(placement)` | |
| `preload_format(format)` | Load every placement of a format at once. |
| `show_interstitial(placement := "")` | Convenience for a game with exactly one. |
| `show_rewarded(placement := "")` | |
| `show_app_open(placement := "")` | |
| `set_suppressed(bool)` | Stop serving without tearing down. What a "remove ads" purchase turns on. |
| `is_suppressed() -> bool` | |
| `set_muted(bool)` | |
| `apply_privacy(has_consent, is_under_age, do_not_sell)` | Called for you by `MSConsent`. |
| `get_provider() -> String` | |

**Signals**

| | |
|---|---|
| `ads_ready(provider)` / `ads_failed(error)` | |
| `ad_loaded(placement, format)` | |
| `ad_load_failed(placement, format, error)` | `NO_FILL` and `NETWORK_ERROR` are ordinary. |
| `ad_shown(placement, format)` | |
| `ad_show_failed(placement, format, error)` | |
| `ad_clicked(placement, format)` | |
| `ad_closed(placement, format)` | The SDK reloads the placement automatically. |
| **`reward_earned(placement, reward_type, amount)`** | **The only signal that may pay a player.** Fires at most once per impression, only when the network reports a reward, and never for an ad that is not the one on screen. |
| `ad_impression(placement, info)` | Per-impression revenue: `provider`, `network`, `format`, `revenue`, `currency`, `precision`. |

---

## MobileServices.iap — `MSIap`

| | |
|---|---|
| `purchase(product, offer_token := "") -> Dictionary` | Opens the store sheet. **Not** a completed purchase — wait for `purchase_completed`. |
| `restore_purchases()` | Re-reads what the account owns. Apple requires a button for this. |
| `refresh_products()` | |
| `has_entitlement(name) -> bool` | The question a game asks. |
| `is_subscribed(name) -> bool` | True only when a *subscription* grants it. |
| `get_entitlements() -> Array` | |
| `get_product_info(product) -> Dictionary` | `price` (the store's own localised string — show this, never build your own), `price_micros`, `currency`, `title`, `description`, `offers`. |
| `get_catalogue() -> Dictionary` | |
| `grant_entitlement(name, product := "", expires_at := 0)` | For a server that verified a receipt, a promo code, or testing. |
| `revoke_entitlement(name)` | |

**Signals:** `iap_ready()`, `iap_failed(error)`, `products_loaded(products)`,
`products_load_failed(error)`, `purchase_started(product)`,
**`purchase_completed(purchase)`** — grant here, once —
`purchase_pending(purchase)`, `purchase_failed(product, error)`,
`purchase_cancelled(product)`, `purchases_restored(products)`,
`entitlements_changed(entitlements)`.

---

## MobileServices.player — `MSPlayer`

| | |
|---|---|
| `get_id() -> String` | Never empty, never changes for the life of an install, survives signing in and out. |
| `get_provider() -> String` | `"anonymous"`, `"play_games"` or `"game_center"`. |
| `get_provider_id() -> String` | The platform's own id, once signed in. |
| `get_display_name() -> String` | Display only. |
| `is_authenticated() -> bool` | |
| `sign_in()` | |
| `sign_out()` | The *game* forgetting. Neither platform offers a real sign-out. |
| `request_server_side_access(force := false)` | A one-time code for a server to exchange with Google. Android only. |
| `reset_id() -> String` | |

**Signals:** `player_ready(player_id, provider)`,
`signed_in(provider_id, display_name)`, `sign_in_failed(error)`.

---

## MobileServices.play_games — `MSPlayGames`

Play Games Services on Android, Game Center on iOS, same names.

| | |
|---|---|
| `sign_in()` | |
| `is_authenticated() -> bool` | |
| `is_supported(feature) -> bool` | `"achievements"`, `"leaderboards"`, `"saved_games"`, `"server_access"`. |
| `unlock_achievement(id)` | |
| `increment_achievement(id, steps)` | |
| `show_achievements()` | |
| `submit_score(leaderboard_id, score)` | |
| `show_leaderboard(id := "")` | |
| `save_game(slot, data, description := "")` | |
| `load_game(slot)` | |

**Signals:** `signed_in`, `sign_in_failed`, `achievement_unlocked`,
`achievements_loaded`, `score_submitted`, `server_access_granted`, `game_saved`,
`game_loaded(slot, data)`, `operation_failed(operation, error)`.

See `docs/play_games.md` for where the platforms genuinely differ.

---

## MobileServices.consent — `MSConsent`

| | |
|---|---|
| `request_update()` | Asks Google whether a form is required here. |
| `show_form_if_required()` | No-op outside the EEA/UK, and for a player who already decided. |
| `show_privacy_options()` | Re-open the form. Google requires this to be reachable. |
| `is_privacy_options_required() -> bool` | Whether to show that button. |
| `can_request_ads() -> bool` | |
| `get_status() -> Status` | `UNKNOWN`, `REQUIRED`, `NOT_REQUIRED`, `OBTAINED`. |
| `get_flags() -> Dictionary` | The four Consent Mode flags. |
| `set_manual_consent(analytics, ad_storage, ad_user_data, ad_personalization)` | For a game with its own privacy screen. |
| `request_tracking_authorization()` | Apple's ATT prompt. iOS only, once per install ever. |
| `get_tracking_status() -> Tracking` | |
| `reset()` | Test mode only. |

**Signals:** `consent_updated(status, can_request_ads)`,
`consent_form_dismissed(error)`, `tracking_authorization_updated(status)`,
`consent_flags_changed(flags)`.

---

## MobileServices.crash — `MSCrash`

| | |
|---|---|
| `log_breadcrumb(message)` | Cheap. Leave one at every scene change. |
| `set_key(key, value)` | |
| `record_error(name, reason, context := {})` | A non-fatal. Keep `name` and `reason` stable so they group. |
| `set_collection_enabled(bool)` | |
| `force_test_crash()` | Test mode only. |

## MobileServices.remote_config — `MSRemoteConfig`

| | |
|---|---|
| `set_defaults(dict)` | Call once, before `fetch`. |
| `fetch(min_interval := -1)` | |
| `get_value(key, fallback)` | Never blocks. `fallback`'s type decides how the value is read. |
| `get_json(key, fallback := {})` | |
| `get_all() -> Dictionary` | |
| `has_key(key) -> bool` | |

**Signals:** `fetched(updated)`, `fetch_failed(error)`.

---

## MSError

| Code | Means |
|---|---|
| `NOT_INITIALIZED` | `initialize()` has not finished. |
| `SERVICE_DISABLED` | Off in `mobile_services.cfg`. Not a fault. |
| `SERVICE_UNAVAILABLE` | No native plugin here — desktop, the editor, a build without it. Not a fault. |
| `INITIALIZATION_FAILED` | The SDK is present and refused to start. |
| `INVALID_CONFIGURATION` | An unknown placement, a product not in the config, a missing unit id. |
| `INVALID_ARGUMENT` | |
| `NOT_READY` | Asked to show something not loaded yet. |
| `NO_FILL` | The network had no ad. Ordinary and frequent. |
| `NETWORK_ERROR` | |
| `USER_CANCELLED` | |
| `ALREADY_OWNED` / `NOT_OWNED` | |
| `PURCHASE_PENDING` | Awaiting a slow payment method. Not a failure. |
| `BILLING_UNAVAILABLE` | |
| `CONSENT_REQUIRED` | |
| `UNSUPPORTED` | |
| `THROTTLED` | |
| `UNKNOWN` | The provider's own code is in `native_code`. |

`MSError.is_recoverable(code)` — whether a "Try again" button makes sense.
`MSError.is_benign(code)` — whether this is just "not on a phone".
`MSError.describe(error)` — one readable line.
