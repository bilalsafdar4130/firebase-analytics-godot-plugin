# Quick start

Five minutes, from a fresh project to an analytics event and a rewarded ad.
Assumes you know Godot and GDScript and nothing about Android or iOS.

## 1. Add the addon

Copy `addons/mobile_services/` into your project's `addons/` folder.

Enable **Mobile Services** in *Project ▸ Project Settings ▸ Plugins*. That
registers the `MobileServices` autoload — you do not add it yourself.

## 2. Write the config

Copy `addons/mobile_services/mobile_services.cfg.template` to
`res://mobile_services.cfg`. For a first run, switch on ads with Google's public
test units, which are already in the template:

```ini
[core]
log_level = "debug"
test_mode = true

[analytics]
enabled = true

[ads]
enabled = true
provider = "admob"
android_app_id = "ca-app-pub-3940256099942544~3347511713"
ios_app_id = "ca-app-pub-3940256099942544~1458002511"
```

Those two app ids are Google's own test app ids. Replace them before release —
`docs/installation.md` says where yours come from.

## 3. Install the Android build template

*Project ▸ Install Android Build Template.* The native plugins need the Gradle
build; the addon refuses to add anything to an export without it and says so.

## 4. Build the native plugins

```
addons/mobile_services/tools/build_android.sh release
```

Needs a JDK 17+, an Android SDK (`ANDROID_HOME`), and network access on the
first run. It uses the Gradle wrapper from the Godot build template, so Gradle
itself does not have to be installed.

Only the modules your config enables are built into the export, so this being
slow the first time is a one-off.

## 5. Use it

```gdscript
extends Node

func _ready() -> void:
    # Connect first. Initialisation can finish in the same frame it starts in.
    MobileServices.initialized.connect(_on_services_ready)
    MobileServices.ads.reward_earned.connect(_on_reward)
    MobileServices.initialize()

func _on_services_ready(_report: Dictionary) -> void:
    MobileServices.analytics.log_event("game_started")

func _on_reward(_placement: String, _reward_type: String, amount: int) -> void:
    # The ONLY place to grant a reward. Not when the ad opens, not when it
    # closes — only here, and the SDK guarantees it fires at most once per ad.
    player_lives += amount
```

Showing ads:

```gdscript
# Load a screen ahead: interstitials and rewarded ads take seconds to fetch.
func _on_level_started() -> void:
    MobileServices.ads.load_ad("interstitial_game_over")

func _on_game_over() -> void:
    MobileServices.ads.show("interstitial_game_over")

func _on_watch_ad_pressed() -> void:
    var problem := MobileServices.ads.show("rewarded_extra_life")
    if not problem.is_empty():
        # `NOT_READY` means "still loading" — tell the player that, not "error".
        $Message.text = "The ad isn't ready yet, try again in a moment."
```

Selling things:

```gdscript
func _on_remove_ads_pressed() -> void:
    MobileServices.iap.purchase("remove_ads")

func _ready() -> void:
    MobileServices.iap.purchase_completed.connect(func(p): _grant(p["product"]))

func should_show_ads() -> bool:
    return not MobileServices.iap.has_entitlement("remove_ads")
```

## 6. Export and check

Build a debug APK and install it. Then:

```
adb logcat -s MobileServicesCore MobileServicesFirebase MobileServicesAds godot
```

You should see `Mobile Services 2.0.0 starting`, then `admob initialised`, then
an ad loading. If you do not, `docs/troubleshooting.md` lists every failure with
a known cause — start there rather than guessing.

For Firebase events specifically:

```
adb shell setprop debug.firebase.analytics.app <your.package.name>
```

then watch Firebase console ▸ Analytics ▸ **DebugView**, which shows events
within seconds. The standard reports take hours, and an empty one is not
evidence of anything for most of a day.

## What to do next

- Put your real ad units and app ids in `mobile_services.cfg`, and set
  `core/test_mode = false`. **Both**: test ads earn nothing, and serving live ads
  to a registered test device is grounds for an AdMob suspension.
- Read [`docs/privacy.md`](privacy.md) before shipping anywhere in the EEA, the
  UK or Switzerland.
- Put `MobileServices.get_diagnostics_text()` behind a hidden gesture in your
  settings screen. It will answer most of the support questions you are going to
  get.
