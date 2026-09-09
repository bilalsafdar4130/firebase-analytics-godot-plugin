# Configuration

Everything a game tells the SDK is in **one file it owns**:
`res://mobile_services.cfg`. There is not one ad unit id, product id or API key
anywhere in `addons/mobile_services/`. The addon is byte-identical in every
game; this file is the whole difference between them.

Start from `addons/mobile_services/mobile_services.cfg.template`, which is
commented line by line.

## Environments

A file called `mobile_services.<environment>.cfg` next to the base one is
overlaid on top of it, **key by key**. So a development overlay is usually four
lines:

```ini
; mobile_services.development.cfg
[core]
log_level = "debug"
test_mode = true
```

Which environment loads:

1. `--ms-env=<name>` on the command line, if given.
2. `mobile_services/config/environment` in Project Settings, if not empty. Godot's
   own feature-override syntax varies this per export preset —
   `mobile_services/config/environment.debug = "development"`.
3. Otherwise: `development` in a debug build, `production` in a release build.

That last default is why most projects never configure this at all.

You can also override in code for one run, which is what a test scene wants:

```gdscript
MobileServices.initialize({"core": {"test_mode": true, "log_level": "debug"}})
```

## What is safe to commit

**All of it.** AdMob unit ids, an AppLovin SDK key, a Firebase app id, store
product ids and a Play Games project id are public by design: they ship inside
every APK and IPA and identify your app rather than authorise anything.

What must **never** be in a game project: a Google service-account private key,
an OAuth client *secret*, a Play Developer API key, an AppLovin *management*
key. Those belong on a server. See [`security.md`](security.md).

---

## `[core]`

| Key | Default | |
|---|---|---|
| `log_level` | `"warn"` | `none`, `error`, `warn`, `info`, `debug`. |
| `test_mode` | `false` | Test ads, verbose native logging, and permission to call the deliberately destructive test helpers. **The export plugin fails a release build that leaves this on.** |
| `auto_initialize` | `true` | Call `initialize()` on autoload. Turn off if your game shows its own privacy screen first. |

## `[analytics]`

| Key | Default | |
|---|---|---|
| `enabled` | `false` | |
| `crashlytics_enabled` | `false` | Needs `enabled`. |
| `remote_config_enabled` | `false` | Needs `enabled`. |
| `remote_config_min_fetch_seconds` | `3600` | Set to `0` in a development overlay. Shipping that is the mistake to avoid. |
| `auto_ad_events` | `true` | Send Firebase's `ad_impression` and `rewarded_ad_completed`. |
| `auto_iap_events` | `true` | Send Firebase's `purchase` and `purchase_failed`. |
| `sync_user_id` | `true` | Use `MobileServices.player`'s id as the Firebase user id. |

## `[ads]`

| Key | Default | |
|---|---|---|
| `enabled` | `false` | |
| `provider` | `"none"` | `none`, `admob`, `applovin_max`. |
| `android_app_id` / `ios_app_id` | `""` | From the AdMob console. **A build with ads enabled and no app id crashes AdMob's own initialiser on launch.** |
| `applovin_sdk_key` | `""` | Required for `applovin_max`. |
| `test_device_ids` | `[]` | Printed by both SDKs on the first ad request. |
| `banner_position` | `"bottom"` | `top` or `bottom`. |
| `auto_reload` | `true` | Reload after a failure and after an ad closes. |
| `reload_backoff_seconds` | `[5,15,45,120,300]` | The last entry repeats forever. |
| `mute_on_start` | `false` | |
| `max_ad_content_rating` | `""` | `G`, `PG`, `T`, `MA`. |
| `tag_for_child_directed_treatment` | `false` | **A legal declaration under COPPA**, not a preference. |
| `tag_for_under_age_of_consent` | `false` | Likewise. |
| `suppress_when_entitled` | `""` | Stop serving ads when the player holds this entitlement. Usually `"remove_ads"`. |
| `extra_android_dependencies` | `[]` | Maven coordinates for mediation adapters the SDK does not ship itself. |
| `extra_ios_pods` | `[]` | Extra CocoaPods lines. The iOS export plugin prints the Podfile your configuration implies into the export log; it cannot install them. |

### `[ads.placement.<name>]`

One section per placement. The name is what game code says.

```ini
[ads.placement.rewarded_extra_life]
format = "rewarded"          ; banner | interstitial | rewarded
                             ; | rewarded_interstitial | app_open
admob_android = "ca-app-pub-…/…"
admob_ios     = "ca-app-pub-…/…"
applovin_android = ""
applovin_ios     = ""
```

Name placements after **what they are for**, not what they are:
`interstitial_game_over`, `rewarded_double_coins`, `banner_store`. That is what
makes the same names work when you switch provider, and what makes an ad revenue
report readable.

## `[iap]`

| Key | Default | |
|---|---|---|
| `enabled` | `false` | |
| `auto_acknowledge` | `true` | **Leave this on** unless a server verifies first: Google refunds an unacknowledged purchase after three days. |
| `auto_consume` | `true` | Likewise: an unconsumed consumable can never be bought again. |
| `restore_on_start` | `true` | What makes a reinstall keep a player's purchases. |

### `[iap.product.<name>]`

```ini
[iap.product.remove_ads]
type = "non_consumable"   ; consumable | non_consumable | subscription
entitlement = "remove_ads" ; what owning it grants; empty for consumables
android_id = "remove_ads"  ; defaults to the section name
ios_id = "remove_ads"
```

A **consumable** is spent and grants no entitlement — give currency in game code
from `purchase_completed`. The validator warns if you try, because the
entitlement would be gone by the next launch and the bug looks like a lost
purchase.

## `[player]`

| Key | Default | |
|---|---|---|
| `enabled` | `true` | |
| `play_games_enabled` | `false` | |
| `game_center_enabled` | `false` | |
| `play_games_app_id` | `""` | The **numeric** project id from the Play Console. Play Games refuses to authenticate without it and says so only in logcat. |
| `play_games_server_client_id` | `""` | The **WEB** OAuth client id, only if a server of yours verifies players. The client *secret* stays on the server. |

## `[consent]`

| Key | Default | |
|---|---|---|
| `enabled` | `false` | Google UMP. **Read [`privacy.md`](privacy.md) before leaving this off.** |
| `request_on_start` | `true` | |
| `debug_geography` | `"disabled"` | `eea`, `not_eea`. Only works on a device in `test_device_hashed_ids`. |
| `under_age_of_consent` | `false` | |
| `test_device_hashed_ids` | `[]` | |
| `att_prompt` | `true` | Ask for App Tracking Transparency on iOS. |
| `att_message` | *(a sentence)* | Apple rejects builds whose text does not say what the data is used for. |

## Validation

The config is validated on load **and again before every export**. Errors stop
initialisation and fail the export loudly; warnings are logged. Every check is a
mistake whose only symptom in a shipped game is missing revenue or missing data:

- ads enabled with `provider = "none"`, or MAX with no SDK key
- an ad app id missing for the platform being built
- a placement with an unknown format, or no unit id for a platform
- a consumable that claims to grant a permanent entitlement
- `suppress_when_entitled` naming an entitlement no product grants
- Play Games enabled with no numeric project id, or a package name in its place
- Crashlytics or Remote Config enabled with analytics off
- **`test_mode = true` in a release build**

## One SDK, three games

The addon does not change. Only this file does.

| | Game A | Game B | Game C |
|---|---|---|---|
| analytics | on | on | on |
| ads | AdMob | AppLovin MAX | off |
| iap | on | on | off |
| Play Games | on | off | off |
| consent | on | on | on |

Each ships only the native modules its own config enables.
