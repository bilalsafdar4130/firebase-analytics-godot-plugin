# Firebase

Analytics, Crashlytics and Remote Config. Each is optional, and a game that
wants only analytics ships only `firebase-analytics`.

## Setup

See [`installation.md`](installation.md#firebase). Two files, in two specific
places:

| | |
|---|---|
| `google-services.json` | `android/build/` — **not** `res://` |
| `GoogleService-Info.plist` | `res://ios/` |

Neither is committed; both are per-project secrets in your CI.

## Analytics

```gdscript
MobileServices.analytics.log_event("level_end", {
    "level_name": "grid_012",
    "score": 4500,
    "success": true,        # sent as 1/0 — see below
})
```

### Firebase's rules, applied before the SDK sees your event

Firebase **drops what it does not like, without saying so**. An event name over
40 characters, one starting with a digit, a reserved prefix, a 26th parameter —
each is discarded and the only symptom is a report that is emptier than it should
be, discovered weeks later.

So the SDK checks first and logs the reason:

| | |
|---|---|
| Event name | ≤ 40 characters, letters/digits/underscore, must not start with a digit, must not begin `firebase_`, `google_` or `ga_` |
| Parameter name | ≤ 40 characters, same character rules |
| String value | truncated at 100 characters |
| Parameters per event | 25 |

A bad name is **refused, not rewritten**. A silently renamed event is a report
split across two names, which is worse than a missing one because it looks like
data.

### Numbers keep their type

Firebase registers a parameter's type from the **first event that carries it**. A
parameter that arrives as an int on one build and a float on the next is a column
that stops aggregating, forever, for that property.

The SDK widens ints to long and floats to double consistently, and sends booleans
as `1`/`0` for the same reason. Keep your own types stable too.

### Events sent before the SDK is ready

Firebase initialises from a ContentProvider that races your first scene, and the
events around first launch are the ones you cannot re-collect. Anything logged
before the native half answers is queued (up to 20) and flushed in order once it
does. The oldest is dropped if the queue fills, because the recent events are the
interesting ones when start-up is slow.

### Helpers

`log_level_start`, `log_level_end`, `log_tutorial_begin`,
`log_tutorial_complete`, `log_unlock_achievement`, `log_post_score`,
`log_ad_impression`, `log_purchase` — ordinary `log_event` calls with the names
Firebase's own reports understand. Nothing requires them; ignore them if you have
your own scheme.

### Automatic events

With the defaults, the SDK also sends:

| Event | When | Switch |
|---|---|---|
| `ad_impression` | every ad impression, with revenue | `analytics/auto_ad_events` |
| `rewarded_ad_completed` | a reward is earned | `analytics/auto_ad_events` |
| `purchase` | a purchase completes | `analytics/auto_iap_events` |
| `purchase_failed` | a purchase fails | `analytics/auto_iap_events` |

Turn them off if you send your own, or you will have both.

### User properties

```gdscript
MobileServices.analytics.set_user_property("play_style", "methodical")
```

Not for anything identifying a person — property values are visible to everyone
with console access, and Firebase's terms forbid personal data there.

The user id is set for you from `MobileServices.player` when
`analytics/sync_user_id` is on.

### Verifying

```
adb shell setprop debug.firebase.analytics.app com.example.game
```

then Firebase console ▸ Analytics ▸ **DebugView**, which shows events within
seconds. The standard reports take hours, and an empty one is not evidence of
anything for most of a day. On iOS, add `-FIRDebugEnabled` to the scheme's launch
arguments.

## Crashlytics

Native and JVM crashes are captured automatically — an engine segfault, an ANR,
an uncaught exception in another plugin. **A GDScript error is none of those**:
it does not crash the process, so nothing reports it unless you do.

```gdscript
MobileServices.crash.record_error("save_failed", "disk full", {"path": path})
```

Keep `name` and `reason` stable so reports group; put the varying part in
`context`. `record_error("save failed at 12:04:11", …)` makes a new group every
time and is useless.

### Breadcrumbs matter more than the stack

A native crash report from a Godot game is a stack full of engine symbols and
nothing about your game. What makes one actionable:

```gdscript
func _on_scene_changed(name: String) -> void:
    MobileServices.crash.log_breadcrumb("scene: %s" % name)
    MobileServices.crash.set_key("level", current_level)
```

That turns "crashed in `Object::call`" into "crashed in `Object::call` while
opening the shop with a banner up".

Breadcrumbs are a local ring buffer until a crash happens, so they cost nothing.
Nothing sensitive goes in: they are uploaded to Google and readable by anyone
with console access.

### Proving it works

```gdscript
MobileServices.crash.force_test_crash()   # test_mode only
```

There is no other way to know it is wired up: Crashlytics uploads on the launch
**after** a crash, so a real crash you did not cause tells you nothing for a day.
Restart the app afterwards, then look at the console.

**Native symbols are not uploaded.** That needs Google's Crashlytics Gradle
plugin, which cannot be added through Godot's export API — the same limitation
that shaped how this addon handles `google-services.json`. Breadcrumbs are the
compensation.

## Remote Config

For the numbers you will want to change without a store review: interstitial
cooldown, whether a sale banner is up, which tutorial new players get.

```gdscript
func _ready() -> void:
    MobileServices.remote_config.set_defaults({
        "interstitial_cooldown": 90.0,
        "sale_banner": "",
    })
    MobileServices.remote_config.fetched.connect(func(_updated): _apply())
    MobileServices.remote_config.fetch()

func _apply() -> void:
    cooldown = MobileServices.remote_config.get_value("interstitial_cooldown", 90.0)
```

**Reads never block.** `get_value` returns the fetched value, then the default you
registered, then the fallback you passed — so a first launch with no network gets
defaults and nothing has to know the difference. The fallback's **type** decides
how the value is read, which avoids Remote Config's own
`getString`/`getLong`/`getBoolean` trap where picking the wrong one is a silent
zero.

Register every key in `set_defaults` before the first `fetch`. A key with no
default still works, but your game's real defaults end up scattered across
whichever call sites happen to read them.

**Fetching is throttled hard.** The production minimum is 12 hours by default and
the SDK simply refuses more often. While developing:

```ini
; mobile_services.development.cfg
[analytics]
remote_config_min_fetch_seconds = 0
```

Shipping that is the mistake to avoid — hence the overlay.
