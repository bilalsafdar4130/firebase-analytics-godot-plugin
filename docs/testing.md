# Testing

## The headless tests

```
godot --headless --import
godot --headless --script res://tests/run_tests.gd
```

Exits non-zero on failure. CI runs this on every push.

They cover everything **pure**: config parsing and validation, the
`google-services.json` reader, Firebase's event-name rules, the error vocabulary,
and that the five places stating the SDK version agree.

That is deliberately where the tests are, because those are the parts where a
mistake is **silent in a shipped game**. A mis-parsed config produces a build
that installs, runs, and reports to nothing.

## What is not tested, and why

No ad loads, no purchases, no Firebase, no sign-in. A test double for Google Play
Billing tests the double: the failures that matter are Play refusing a product
because the build is not signed with the right key, an AdMob unit that is
technically valid and serves nothing, a rewarded callback that arrives twice
after a network switch. None of those has a mock that would have caught them.

So those are checked by hand, against the matrix below, on a real device.

## The manual matrix

Run this before a release, on at least one real Android device and one real
iPhone.

### Start-up
- [ ] Cold start with no network → the game runs; ads and billing report failures
- [ ] Cold start on a device with no Google Play Services → the game runs
- [ ] `initialize()` twice → the second returns immediately, nothing starts twice
- [ ] A config with a deliberate error → initialisation fails loudly and the game
      still runs
- [ ] Background and foreground during start-up
- [ ] Rotate during start-up (activity recreation)

### Analytics
- [ ] An event appears in **DebugView** within seconds
- [ ] An event logged before `initialized` arrives after it (the queue)
- [ ] A bad event name is refused with a log line, not silently dropped
- [ ] With consent denied, nothing is collected
- [ ] `reset_data()` then a new event → a new app instance

### Ads
- [ ] Banner shows, hides, shows again, and is clear of the gesture bar
- [ ] Interstitial: load, show, close, and the next one is ready
- [ ] **Rewarded: reward arrives exactly once**
- [ ] **Rewarded closed early: no reward**
- [ ] Airplane mode → `NETWORK_ERROR`, retries with backoff, recovers when back
- [ ] A wrong unit id → `INVALID_CONFIGURATION`, no crash
- [ ] `show()` on an unloaded placement → `NOT_READY`, and a load starts
- [ ] Revenue arrives on `ad_impression`
- [ ] With `suppress_when_entitled` held → nothing serves

### Purchases
- [ ] Products load with **localised** prices
- [ ] Buy a consumable → granted once, buyable again
- [ ] Buy a non-consumable → entitlement held, and still held after a restart
- [ ] **Buy the same non-consumable again → `ALREADY_OWNED`, not a crash**
- [ ] Cancel the sheet → `purchase_cancelled`, nothing granted
- [ ] Subscription with an offer → the right price is charged
- [ ] Cancel a subscription in Play → the entitlement is revoked on next launch
- [ ] Reinstall → `restore_purchases()` gets it back
- [ ] Kill the app mid-purchase → it completes on the next launch
- [ ] **A test-card "pending" purchase → nothing granted, then granted later**

### Player and Play Games
- [ ] First launch → an id exists
- [ ] Restart → the same id
- [ ] Sign in → the id does **not** change; `provider_id` appears
- [ ] Decline sign-in → the game works
- [ ] Achievement, leaderboard, cloud save round trip

### Consent
- [ ] `debug_geography = "eea"` → the form appears
- [ ] Accept → ads start, Firebase collects
- [ ] Decline → ads do not start, the game runs
- [ ] The privacy button re-opens the form
- [ ] iOS: the ATT prompt appears **after** the UMP form
- [ ] `reset()` → the form appears again

### Release build
- [ ] A **minified** release build: every plugin still present *(this is where R8
      removes the lot if the keep rules are wrong)*
- [ ] `test_mode = false` and real units → real ads
- [ ] A signed build from a Play track: purchases work
- [ ] Diagnostics dump contains no ad unit, product id, key or token

## Useful commands

```bash
# Firebase DebugView
adb shell setprop debug.firebase.analytics.app com.example.game
adb shell setprop debug.firebase.analytics.app .none.      # off

# Just this SDK
adb logcat -s MobileServicesCore MobileServicesFirebase MobileServicesAds \
            MobileServicesBilling MobileServicesPlayGames MobileServicesConsent

# Wipe entitlement and id caches
adb shell pm clear com.example.game
```

Force a specific state from a test scene without editing files:

```gdscript
MobileServices.initialize({"core": {"test_mode": true, "log_level": "debug"}})
```
