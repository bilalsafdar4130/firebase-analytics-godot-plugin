# Troubleshooting

**Start here:** print `MobileServices.get_diagnostics_text()`. It names your SDK
version, the engine version, the device, which native plugins are present, which
services started and what the last failure of each was — which answers most of
what follows without guessing.

```
adb logcat -s MobileServicesCore MobileServicesFirebase MobileServicesAds \
            MobileServicesBilling MobileServicesPlayGames MobileServicesConsent godot
```

---

## Nothing works: every call says SERVICE_UNAVAILABLE

`native_plugins` in the diagnostics dump is all `false`.

| Cause | Fix |
|---|---|
| Running in the editor or on desktop | Expected. Export to a device. |
| The AARs were never built | `tools/build_android.sh release` |
| The Gradle build is off | *Project ▸ Install Android Build Template*, and tick **Use Gradle Build** in the export preset. |
| The addon is not enabled | *Project Settings ▸ Plugins*. |
| A minified release build | Missing keep rules — see below. |
| iOS: the `.gdip` files are not in `res://ios/plugins/`, or not ticked in the export preset | [`ios.md`](ios.md) |

## A release build works in debug and not in release

R8 removed the plugin. Godot instantiates plugin classes **by name** from a
manifest entry and calls `@UsedByGodot` methods **reflectively**; R8 sees
neither.

Each module ships `consumer-rules.pro` with the right rules, so this should not
happen — unless your project's own ProGuard configuration overrides them. Check
that `-keep class com.bilalsafdar.godot.mobileservices.** { *; }` survives.

## The app crashes on launch as soon as ads are enabled

`GADApplicationIdentifier`/`com.google.android.gms.ads.APPLICATION_ID` is missing
or malformed. AdMob's initialiser throws; that is Google's behaviour.

Set `ads/android_app_id` and `ads/ios_app_id` to the **app id** — `ca-app-pub-…~…`
with a **tilde** — not an ad unit id, which uses a slash. The export plugin fails
the build when it is empty, so this means it is present and wrong.

## Firebase reports nothing

1. `google-services.json` must be in **`android/build/`**, not in `res://`.
2. Its `client` list must contain a block whose `package_name` matches the export
   preset's package **exactly**. The export plugin fails by name if not — read the
   export log.
3. Check the generated
   `android/build/res/values/mobile_services_generated.xml` exists and has
   `google_app_id` in it.
4. `MobileServices.analytics.is_ready()` on the device; if false,
   `get_last_error()` says why.
5. Consent: with `consent/enabled = true` and no decision made, collection stays
   off **by design**. Check `consent.get_flags()`.
6. Reports take hours. Use DebugView:
   ```
   adb shell setprop debug.firebase.analytics.app <your.package.name>
   ```

## Some events never appear, others do

Firebase silently drops what it does not like. The SDK checks first and logs the
reason at `warn` — raise `core/log_level` to `debug` and look.

Event names: ≤ 40 characters, letters/digits/underscore, not starting with a
digit, not prefixed `firebase_`, `google_` or `ga_`. Parameter names ≤ 40.
String values truncated at 100. At most 25 parameters.

A parameter that arrives as an int on one build and a float on the next is a
column that stops aggregating — the SDK widens both consistently, but only for
values it sends.

## Ads never load

| `error.code` | Means |
|---|---|
| `NO_FILL` | The network had nothing. Ordinary, especially with a new unit or in a small market. Wait — new AdMob units can take hours to serve at all. |
| `NETWORK_ERROR` | Off-line, or a timeout. The SDK retries with backoff. |
| `INVALID_CONFIGURATION` | The unit id is wrong, or belongs to another app. |
| `NOT_READY` | You called `show()` before the ad loaded. Call `load_ad()` a screen ahead. |

Also: a brand-new AdMob account serves no ads until it is approved, and an
account with a payment problem stops serving without notice.

## The rewarded ad plays but the player gets nothing

You are listening to the wrong signal. Only `reward_earned` grants — not
`ad_shown`, not `ad_closed`, and not `show()` returning `{}`.

If `reward_earned` genuinely never fires, check the unit is a **rewarded** unit
in the network's console rather than an interstitial.

## Billing: every product is "unknown"

Almost always the same thing: **the build is not signed with the same key as an
uploaded release, or is not installed from a Play track.** A debug APK sideloaded
from your machine reports every product as unknown. Upload to internal testing
and install from there.

Then check, in order:

- the ids in `mobile_services.cfg` match the Play Console exactly (case included)
- every product is **Active**
- every subscription has an **active base plan**
- the account testing is a **licence tester**
- `com.android.vending.BILLING` is in the manifest — the export plugin adds it
  when `iap/enabled` is true

On iOS: sign the **Paid Applications Agreement**, and use a Sandbox tester.

## A purchase succeeded and the player did not get it

- Are you granting on `purchase_completed`, not on `purchase()` returning?
- Was it `purchase_pending`? Cash and Ask-to-Buy purchases complete later.
- Did the game crash between the grant and its own save? Turn off
  `iap/auto_consume`, save first, then consume.

## A purchase came back three days later as a refund

It was never acknowledged. Google refunds unacknowledged purchases after three
days. `iap/auto_acknowledge` handles it; if you turned it off, your server must
acknowledge within the window.

## A consumable cannot be bought a second time

It was never consumed. Play answers `ITEM_ALREADY_OWNED`. Leave
`iap/auto_consume` on, or consume it yourself after saving.

## The consent form never appears in testing

It only appears where it is required. Force it:

```ini
[consent]
debug_geography = "eea"
test_device_hashed_ids = ["THE-HASH-FROM-LOGCAT"]
```

Debug settings take effect **only** on a device whose hashed id is listed —
forcing a geography on an unlisted device does nothing at all. The hash is
printed by UMP on the first `request_update()`.

`MobileServices.consent.reset()` (test mode only) clears the stored decision.

## Play Games sign-in always fails

| Cause |
|---|
| `player/play_games_app_id` missing, or not the numeric project id |
| No credential for this build's signing certificate in the Play Console |
| The account is not on the tester list |
| An emulator image without Google APIs |
| The Play Games Services configuration is not published |

Play Games reports all of these the same way, and the detail only in logcat.

## Gradle: "duplicate class" or a manifest merge failure

Two copies of the same SDK. Most likely another Godot addon is adding a Firebase
or ads dependency as well. Check every addon's `_get_android_dependencies`, and
remove `ads/extra_android_dependencies` entries that duplicate what this SDK
already adds (`play-services-ads`, `firebase-analytics`, `billing-ktx`,
`play-services-games-v2`, `user-messaging-platform`).

## Gradle: "the plugin has not been built"

`tools/build_android.sh` has not run, or ran for a different variant. A debug
export needs the debug AARs:

```
addons/mobile_services/tools/build_android.sh both
```

## Build fails with unresolved `org.godotengine.*`

`libs/godot-lib.jar` is missing. Do not run Gradle directly — run
`tools/build_android.sh`, which extracts the engine library from the installed
Android build template first.

## The editor prints script errors about the addon on startup

Make sure `mobile_services.cfg` exists and parses. The plugin validates it when
it is enabled and prints every problem by name. If the file is genuinely absent
the addon says so once and switches everything off.

## A method is "missing from the installed native plugin"

The AAR or xcframework in this build is older than the GDScript half. Rebuild the
native plugins. `tests/test_versions.gd` exists to catch this before a release;
the diagnostics dump shows both versions.
