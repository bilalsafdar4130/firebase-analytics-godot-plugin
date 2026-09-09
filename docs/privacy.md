# Privacy and consent

This page is about staying inside Google's and Apple's rules without a lawyer. It
is not legal advice.

## Everything defaults to denied

The Android export plugin writes Firebase's own consent switches into the
manifest, all denied:

```xml
<meta-data android:name="google_analytics_default_allow_analytics_storage" android:value="false" />
<meta-data android:name="google_analytics_default_allow_ad_storage" android:value="false" />
<meta-data android:name="google_analytics_default_allow_ad_user_data" android:value="false" />
<meta-data android:name="google_analytics_default_allow_ad_personalization_signals" android:value="false" />
<meta-data android:name="google_analytics_adid_collection_enabled" android:value="false" />
<meta-data android:name="google_analytics_ssaid_collection_enabled" android:value="false" />
```

**Why the manifest and not code.** Firebase starts Analytics from a
ContentProvider that runs before the app's first Activity, so the game's first
chance to say "not yet" in GDScript is already several automatic events late. A
manifest default is the only thing that can be in place before that.

The SDK then grants what it may at runtime, and those runtime calls persist
across launches — so these defaults decide the first session only, and decide it
in the safe direction.

## The advertising ID

`google_analytics_adid_collection_enabled` is the loud one, and it stays denied
**even in a build that serves ads**.

Firebase Analytics collects the Android advertising ID unless told not to, and
that single default is what puts "Advertising ID" on a Play Data Safety
declaration and makes an ad-free game look like an ad-supported one. An ad SDK
reading that identifier to fill a banner is one thing; *analytics* also
collecting it and joining it to every gameplay event you report is a second and
much wider collection that serving a banner does not require.

The `AD_ID` **permission** is a different question, and the export plugin decides
it from your config:

- **ads enabled** → the permission the ad SDK declares is left in place.
- **ads disabled** → the permission is removed with `tools:node="remove"`.

An app that does not read the advertising ID must not ask for it: Play's Data
Safety form treats a declared `AD_ID` permission as a declaration that the ID is
collected, and a mismatch is a policy rejection.

## Turning consent off

`consent/enabled = false` makes the SDK **grant** Firebase and the ad SDK full
consent, and log a warning saying so.

That is deliberate. If a project that simply never switched consent on ended up
denied instead, it would ship with analytics silently dead — an empty dashboard
that looks like a game nobody plays, which is the worst failure mode this SDK
could have.

It also means: **shipping to the EEA, the UK or Switzerland with consent off
breaks Google's policy.** Either switch it on, or call
`set_manual_consent()` from your own privacy screen.

## The Google UMP flow

```ini
[consent]
enabled = true
request_on_start = true
```

The SDK then, at start-up:

1. asks Google whether a form is required for this player's region;
2. shows Google's own form if it is;
3. reads the result back and passes it to Firebase as Consent Mode flags;
4. **only then** starts the ad service.

A player who declines, or a device that never reaches Google's consent servers,
simply never reaches step 4 — and the game runs without ads rather than not
running.

You must give players a way back:

```gdscript
func _ready() -> void:
    $PrivacyButton.visible = MobileServices.consent.is_privacy_options_required()

func _on_privacy_pressed() -> void:
    MobileServices.consent.show_privacy_options()
```

Google **requires** that for any app that showed a form. `is_privacy_options_required()`
is false outside the EEA/UK, so the button hides itself where it is not needed.

### Testing the form

The form only appears where it is required, so force it:

```ini
[consent]
debug_geography = "eea"
test_device_hashed_ids = ["THE-HASH-FROM-LOGCAT"]
```

Debug settings only take effect on a device whose hashed id is listed. Forcing a
geography on an unlisted device does nothing at all, which is the usual reason
"the form never appears in testing".

`MobileServices.consent.reset()` clears the stored decision so it appears again.
It refuses outside `core/test_mode`.

## Consent Mode, and the honest caveat

UMP writes the player's decision into the IAB TCF strings. The **ad SDKs read
those themselves**. Firebase does not — Google's own guidance is that an app
using Consent Mode must call `setConsent` itself.

So the SDK reads the TCF purposes back out and derives four flags:

| Consent Mode flag | Derived from TCF purposes |
|---|---|
| `analytics_storage` | 1 **and** (8 or 9 or 10) |
| `ad_storage` | 1 and 2 |
| `ad_user_data` | 1 and 7 |
| `ad_personalization` | 1 and 3 and 4 |

**This is an approximation.** TCF purposes do not line up one-for-one with
Consent Mode's four storage types, and Google's published mapping has changed
more than once. The rule above errs towards deny on anything ambiguous, which
costs some analytics fidelity and cannot cost a compliance finding. It is
identical on Android and iOS.

When GDPR does not apply — `IABTCF_gdprApplies` is not 1, which is the case
outside the EEA/UK — everything is granted, which is what UMP itself assumes when
it decides no form is needed.

## Running your own privacy screen

```ini
[consent]
enabled = false
```

```gdscript
func _on_player_chose(analytics: bool, ads: bool, personalised: bool) -> void:
    MobileServices.consent.set_manual_consent(analytics, ads, ads, personalised)
```

Analytics and the ad SDK follow immediately. Do not also leave UMP on, or the
player is asked twice.

## App Tracking Transparency

Apple's ATT prompt is a **different question** from the UMP form: UMP is about
GDPR, ATT is about the IDFA. A player can consent to one and refuse the other.

```gdscript
# After the first level, not on the splash screen.
MobileServices.consent.request_tracking_authorization()
```

Apple allows the prompt **once per install, ever**, and expects most people to
say no. Google requires the UMP form to be shown first, because ATT is meaningless
to a player who has not yet been told what the app collects.

`consent/att_message` is the sentence Apple shows. Apple rejects builds whose
text does not say what the data is used for, and rejects the default placeholder
outright.

## Children's apps

`ads/tag_for_child_directed_treatment` and `ads/tag_for_under_age_of_consent` are
**legal declarations** under COPPA and the GDPR, not preferences. Set them only
if your app genuinely targets children, and expect much lower ad revenue —
personalised ads are disabled by them.

## Deleting a player's data

```gdscript
func _on_delete_my_data_pressed() -> void:
    MobileServices.analytics.reset_data()   # throws away the app instance id
    MobileServices.player.reset_id()        # a new anonymous id
    DirAccess.remove_absolute("user://save.dat")
```

Nothing sent afterwards can be joined to anything sent before. There is no
account to close: this SDK never collects one.

## What to put on a Play Data Safety form

Read your own build's `MobileServices.get_diagnostics()` and answer from it.
Roughly:

| If your config has | You are collecting |
|---|---|
| `analytics/enabled` | App interactions, device identifiers (the app instance id), crash logs, approximate location (Firebase infers country from IP) |
| `ads/enabled` | Advertising ID, app interactions |
| `iap/enabled` | Purchase history |
| `player/play_games_enabled` | A player id from Google (not an email address) |
| nothing above | Nothing |

The anonymous installation id this SDK generates is **not** derived from any
hardware identifier — it is random, per install, and deleted with the app's data.
