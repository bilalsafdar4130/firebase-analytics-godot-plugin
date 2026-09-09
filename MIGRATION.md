# Migration

## From 1.x (`firebase_analytics`) to 2.0 (`mobile_services`)

**Your existing game code keeps working.** That is the first thing to know: 2.0
still registers the Android singleton `FirebaseAnalyticsBridge` with the same six
methods and the same signatures, so a game written against 1.x reports exactly as
it did before, on day one, with no source changes.

```gdscript
# Still works, unchanged, in 2.0:
if Engine.has_singleton("FirebaseAnalyticsBridge"):
    var firebase := Engine.get_singleton("FirebaseAnalyticsBridge")
    firebase.logEvent("level_end", {"level_name": "grid_012"})
```

Three games are written that way. Removing the singleton would have meant every
one of them silently stopping — `Engine.has_singleton` would answer false and the
guard every call site has would swallow it. So it stays.

### What actually has to change

| 1.x | 2.0 |
|---|---|
| Folder is `addons/firebase_analytics/` | `addons/mobile_services/` |
| Plugin named "Firebase Analytics" | "Mobile Services" |
| No config file | `res://mobile_services.cfg` is required |
| `tools/build_plugin.sh` | `tools/build_android.sh` |
| One AAR | up to six, named by module |
| No autoload | `MobileServices` autoload, registered by the plugin |

### Step by step

1. **Delete** `addons/firebase_analytics/` from the game.
2. **Copy in** `addons/mobile_services/`.
3. **Enable** *Mobile Services* in *Project Settings ▸ Plugins*, and disable the
   old *Firebase Analytics* entry if it is still listed.
4. **Write the config.** Copy
   `addons/mobile_services/mobile_services.cfg.template` to
   `res://mobile_services.cfg`. To reproduce 1.x behaviour exactly, this is
   enough:
   ```ini
   [core]
   log_level = "warn"

   [analytics]
   enabled = true
   crashlytics_enabled = false

   [consent]
   ; 1.x had no consent management, so this reproduces its behaviour.
   ; Read docs/privacy.md before shipping to the EEA, the UK or Switzerland.
   enabled = false
   ```
5. **Rebuild:**
   ```
   addons/mobile_services/tools/build_android.sh release
   ```
6. **Export and check DebugView.** Nothing else should have changed.

### Then, at leisure

The compatibility singleton is Android-only — it is a Kotlin class. To get the
same calls working on iOS, in the editor and on desktop, swap the one line where
you obtain it:

```gdscript
# Before
var firebase := Engine.get_singleton("FirebaseAnalyticsBridge")

# After — same six methods, same signatures, but it works everywhere
var firebase := MSLegacyFirebase.new()
```

`MSLegacyFirebase` forwards to the 2.0 SDK and has `logEvent`,
`setUserProperty`, `setAnalyticsCollectionEnabled`, `setConsent`,
`resetAnalyticsData`, `isReady` and `lastError`.

And when you are ready, port the call sites:

| 1.x | 2.0 |
|---|---|
| `firebase.logEvent(name, params)` | `MobileServices.analytics.log_event(name, params)` |
| `firebase.setUserProperty(n, v)` | `MobileServices.analytics.set_user_property(n, v)` |
| `firebase.setAnalyticsCollectionEnabled(b)` | `MobileServices.analytics.set_collection_enabled(b)` |
| `firebase.setConsent(a, b, c, d)` | `MobileServices.consent.set_manual_consent(a, b, c, d)` |
| `firebase.resetAnalyticsData()` | `MobileServices.analytics.reset_data()` |
| `firebase.isReady()` | `MobileServices.analytics.is_ready()` |
| `firebase.lastError()` | `MSError.describe(MobileServices.analytics.get_last_error())` |
| `Engine.has_singleton(...)` guards | **delete them** — the SDK is safe to call anywhere |

That last row is most of the benefit. Every 1.x call site needed a guard because
the singleton does not exist in the editor, on desktop, or in a build exported
without the plugin. In 2.0 every call is safe everywhere and answers with a
failure dictionary you can ignore.

### Behaviour that changed on purpose

- **Event names are validated.** 1.x passed anything through and let Firebase
  drop it silently. 2.0 refuses a name Firebase would drop, and logs why. If your
  reports gain events after upgrading, those are ones 1.x was losing.
- **Events before the SDK is ready are queued** rather than dropped.
- **The privacy manifest defaults are unchanged** — everything denied — but the
  SDK now *grants* on your behalf. With `consent/enabled = false` it grants
  everything and warns; with it true it grants what UMP decided. In 1.x the game
  had to call `setConsent` itself.
- **The `AD_ID` permission rule now keys off `ads/enabled`**, not off whether a
  separate ads addon is installed.

### Things 1.x did that 2.0 does not

Nothing. `firebase_client.cfg` is still written into the package at export time
with the same four keys, so a game reading Firebase REST APIs from GDScript is
unaffected.

## Upgrading between 2.x releases

Minor and patch releases add config keys with safe defaults and never remove a
method. Read [`docs/release.md`](docs/release.md#upgrading-a-game) — the short
version is: replace the folder, rebuild the AARs, diff the config template
against your config, and run the manual matrix before you ship.
