# Installation

The full version. [`quick_start.md`](quick_start.md) is the five-minute one.

## The addon

1. Copy `addons/mobile_services/` into your project's `addons/`.
2. Copy `addons/mobile_services/mobile_services.cfg.template` to
   `res://mobile_services.cfg`.
3. *Project ▸ Project Settings ▸ Plugins* → enable **Mobile Services**. This
   registers the `MobileServices` autoload and installs both export plugins.
4. *Project ▸ Install Android Build Template.* The native plugins need the
   Gradle build; the addon refuses to add anything to an export without it.

Exclude `addons/*` from the export preset's resource filter — nothing in there
belongs inside the game package except `runtime/`, which the autoload pulls in
by reference.

## Building the Android plugins

```
addons/mobile_services/tools/build_android.sh release
```

Needs a JDK 17+, an Android SDK (`ANDROID_HOME` or `ANDROID_SDK_ROOT`), and
network access on the first run. It uses the Gradle wrapper from the Godot build
template, so Gradle itself does not have to be installed — and it compiles
against the **engine's own** `godot-lib` from that template, so there is no
`org.godotengine:godot` Maven version to pin or get wrong.

Build only what you use:

```
addons/mobile_services/tools/build_android.sh release core firebase
```

Re-run it after a Godot upgrade: the script re-extracts the engine library, so
the plugins follow the engine automatically.

## Building the iOS plugins

Needs macOS, Xcode and SCons. See [`ios.md`](ios.md) — including what is and is
not verified there.

---

## Firebase

1. Firebase console → add an **Android** app with your package name (and an
   **iOS** app with your bundle id).
2. Download `google-services.json` → put it in `android/build/` (next to the
   installed build template, **not** in `res://`).
3. Download `GoogleService-Info.plist` → put it in `res://ios/`.
4. In `mobile_services.cfg`:
   ```ini
   [analytics]
   enabled = true
   crashlytics_enabled = true
   ```

The export plugin reads `google-services.json`, picks the client block matching
**your** package name, and generates the Android string resources Firebase
initialises from. If there is no matching block it fails the export by name
rather than producing a build that reports into someone else's project.

Do not commit either file: they are per-project and belong in your CI secrets.
`.gitignore` in this repository already excludes them.

**Crashlytics note.** Crashes are captured and uploaded without any extra setup.
What is *not* set up is native symbol upload, which needs Google's Crashlytics
Gradle plugin — so an engine-level crash arrives with an unsymbolicated native
stack. Breadcrumbs (`MobileServices.crash.log_breadcrumb`) are what make those
reports actionable; see [`api.md`](api.md).

## AdMob

1. AdMob console → add your app → copy the **App ID** (`ca-app-pub-…~…`, with a
   tilde).
2. Create ad units → copy each **Ad unit ID** (`ca-app-pub-…/…`, with a slash).
3. In `mobile_services.cfg`:
   ```ini
   [ads]
   enabled = true
   provider = "admob"
   android_app_id = "ca-app-pub-…~…"
   ios_app_id = "ca-app-pub-…~…"

   [ads.placement.interstitial_game_over]
   format = "interstitial"
   admob_android = "ca-app-pub-…/…"
   admob_ios = "ca-app-pub-…/…"
   ```

The app id goes into the Android manifest and the iOS Info.plist for you. Get it
wrong and AdMob's initialiser throws on launch — that is Google's behaviour, not
this addon's, and it is why the export plugin refuses a build without one.

While developing, register your device: run once, find the id the SDK prints in
logcat or the Xcode console, and put it in `ads/test_device_ids`.

## AppLovin MAX

1. AppLovin dashboard → **Account ▸ Keys** → SDK key.
2. Create MAX ad units → copy each unit id.
3. In `mobile_services.cfg`:
   ```ini
   [ads]
   provider = "applovin_max"
   applovin_sdk_key = "…"
   android_app_id = "ca-app-pub-…~…"   ; still needed: MAX mediates AdMob

   [ads.placement.interstitial_game_over]
   format = "interstitial"
   applovin_android = "…"
   applovin_ios = "…"
   ```
4. Add the **network adapters** your waterfall uses:
   ```ini
   extra_android_dependencies = [
     "com.applovin.mediation:google-adapter:23.6.0.0",
     "com.applovin.mediation:facebook-adapter:6.18.0.1",
   ]
   ```
   Which ones is a question for your MAX dashboard, so the SDK does not guess.

Your placement names, and the rest of your game, do not change. That is the
point of the abstraction.

## Google Play Billing

1. Play Console → **Monetise ▸ Products** → create in-app products and
   subscriptions.
2. Every subscription needs an **active base plan**, or a purchase fails with a
   `DEVELOPER_ERROR` that explains nothing.
3. In `mobile_services.cfg`:
   ```ini
   [iap]
   enabled = true

   [iap.product.remove_ads]
   type = "non_consumable"
   entitlement = "remove_ads"
   android_id = "remove_ads"
   ios_id = "remove_ads"
   ```

Products only resolve for a build **signed with the same key as an uploaded
release** and installed from a Play track (internal testing is enough). A debug
APK sideloaded from your machine will report every product as unknown, and that
is Play's behaviour rather than a bug here. See [`iap.md`](iap.md).

## App Store purchases

1. App Store Connect → **In-App Purchases** → create the products.
2. Sign the **Paid Applications Agreement**, or nothing resolves.
3. Put the same ids in `ios_id`, and test with a **Sandbox tester** account.

## Google Play Games Services

1. Play Console → **Play Games Services ▸ Setup and management ▸ Configuration**.
2. Copy the **numeric project id** into `player/play_games_app_id`. Without it
   Play Games refuses to authenticate and says so only in logcat.
3. Add a credential for your app's signing certificate.
4. Add testers, or sign-in fails for everyone but you.
5. ```ini
   [player]
   play_games_enabled = true
   play_games_app_id = "123456789012"
   ```

## Game Center

1. Enable the **Game Center** capability in your provisioning profile.
2. Configure leaderboards and achievements in App Store Connect.
3. ```ini
   [player]
   game_center_enabled = true
   ```

## Consent

```ini
[consent]
enabled = true
```

Read [`privacy.md`](privacy.md) before shipping. Leaving consent off makes the
SDK grant full consent and log a warning, which is fine outside the EEA/UK and a
policy violation inside it.

## Verifying an export

After exporting a debug APK:

```
adb logcat -s MobileServicesCore MobileServicesFirebase MobileServicesAds \
            MobileServicesBilling MobileServicesPlayGames godot
```

You are looking for `Mobile Services 2.0.0 starting`, then one line per service.
Anything missing is in [`troubleshooting.md`](troubleshooting.md).
