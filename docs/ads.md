# Ads

## Placements

Game code names a **placement**, never an ad unit:

```gdscript
MobileServices.ads.show("rewarded_extra_life")
```

The unit ids live in `mobile_services.cfg`, per provider and per platform. That
is what lets you switch from AdMob to AppLovin MAX by changing one line, and what
makes the same addon work in several games.

Name placements after what they are **for**, not what they are:
`interstitial_game_over`, `rewarded_double_coins`, `banner_store`. Those names
end up in your ad revenue reports, and `interstitial_1` tells you nothing six
months later.

## Load ahead, show later

Interstitials and rewarded ads take seconds to fetch. A game that calls `show()`
without having loaded first will usually be told `NOT_READY`.

```gdscript
func _on_level_started() -> void:
    MobileServices.ads.load_ad("interstitial_game_over")
    MobileServices.ads.load_ad("rewarded_extra_life")
```

With `ads/auto_reload = true` (the default) the SDK preloads every one-shot
placement at start-up and reloads each one after it closes, so most games do not
have to call `load_ad` at all.

`show()` answering `NOT_READY` also starts a load, so the *next* attempt can
work. Tell the player "not ready yet", never "error 4":

```gdscript
var problem := MobileServices.ads.show("rewarded_extra_life")
if not problem.is_empty() and problem["code"] == MSError.NOT_READY:
    $Message.text = "The ad isn't ready yet — try again in a moment."
```

## The reward rule

This is the one thing in the SDK worth being strict about, because every
rewarded-ad bug that costs real money is a variant of granting on the wrong
signal.

**A reward is granted only when the network reports one, only for the ad on
screen at the time, and only once.**

```gdscript
func _ready() -> void:
    MobileServices.ads.reward_earned.connect(_on_reward)

func _on_reward(placement: String, reward_type: String, amount: int) -> void:
    match placement:
        "rewarded_extra_life": lives += amount
        "rewarded_double_coins": coins *= 2
```

Not on `ad_shown`. Not on `ad_closed`. Not on `show()` returning `{}` — that
means the ad was handed to the network, nothing more. A player who closes a
rewarded ad after two seconds gets `ad_closed` and no reward, which is correct.

The SDK drops a reward for a placement that is not the one on screen, and drops
a second reward for the same impression. Both happen in the wild: AppLovin has
delivered duplicate callbacks after a network switch, and a late callback can
arrive after the player has already closed the ad and opened another.

## Banners

```gdscript
MobileServices.ads.show_banner("banner_main")           # config's position
MobileServices.ads.show_banner("banner_store", "top")
MobileServices.ads.hide_banner("banner_main")           # keeps refreshing
MobileServices.ads.destroy("banner_main")               # releases it
```

Banners are anchored **adaptive** on both platforms — sized to the device's
width, which is what Google recommends and what stops a banner looking like a
postage stamp on a tablet — and pinned inside the safe area, so a bottom banner
is clear of the gesture bar or home indicator.

Hiding keeps the ad refreshing, which is what a game switching between two
screens wants. Destroy when a banner is gone for good.

## Failures are ordinary

`NO_FILL` and `NETWORK_ERROR` happen constantly on real devices. Neither is a
reason to interrupt a player, and the SDK retries with the backoff in
`ads/reload_backoff_seconds` — the last entry repeats forever, which is what you
want for a player on a train.

```gdscript
MobileServices.ads.ad_load_failed.connect(func(placement, format, error):
    if MSError.is_benign(error["code"]):
        return
    push_warning("%s: %s" % [placement, MSError.describe(error)])
)
```

## Test ads

`core/test_mode = true` and Google's public test units get you test ads. To see
test ads through your **real** unit ids — which is the only way to test the
waterfall you will ship — register your device:

1. Run once with ads on.
2. Find the id the SDK prints (`Use RequestConfiguration.Builder.setTestDeviceIds`
   in logcat, or the equivalent in the Xcode console).
3. Put it in `ads/test_device_ids`.

**Never ship with a registered test device that is a real user's, and never ship
`test_mode = true`.** Test ads earn nothing, and serving live ads to a device
flagged as a test device is grounds for an AdMob suspension. The export plugin
fails a release build that leaves `test_mode` on.

## Mediation with AppLovin MAX

MAX is a waterfall over several networks, AdMob among them, so the network that
actually filled an impression is only known afterwards. That is why the
`ad_impression` signal's `network` field is the interesting part on MAX and
usually just `"admob"` on AdMob.

The per-network **adapters** are yours to add — which ones depends on your MAX
dashboard:

```ini
extra_android_dependencies = ["com.applovin.mediation:google-adapter:23.6.0.0"]
```

Nothing else changes. Your placement names, your signal handlers and your reward
code are identical.

## Revenue

```gdscript
MobileServices.ads.ad_impression.connect(func(placement, info):
    print("%s paid %.4f %s via %s" % [
        placement, info["revenue"], info["currency"], info["network"]
    ])
)
```

With `analytics/auto_ad_events = true` this is already being sent to Firebase as
`ad_impression` with the parameter names Google's ad-revenue reports look for, so
most games do not connect it at all.

`precision` says how much to trust the figure — on AdMob: 0 unknown, 1 estimated,
2 the publisher's floor, 3 the exact amount paid. Keep it alongside the number;
averaging estimates and exact values gives you something that means nothing.

## Suppressing ads

A "remove ads" purchase:

```ini
[ads]
suppress_when_entitled = "remove_ads"
```

The SDK then stops serving as soon as the entitlement is held, and hides any
banner that is up. It does **not** touch your UI — what to draw in the space is
your decision. Do it by hand instead if you prefer:

```gdscript
MobileServices.ads.set_suppressed(true)
```

## Frequency

The SDK never shows an ad on its own. Every impression is a call your game made,
so pacing is yours: a cooldown, an every-N-levels rule, a first-session grace
period. `remote_config` is a good place to keep those numbers so you can change
them without shipping.
