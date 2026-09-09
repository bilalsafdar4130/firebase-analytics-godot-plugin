# Security

## The one rule

**Anything inside an APK or IPA is public.** Both are zip files. Assume every
string in your game is readable by anyone who wants to read it, because it is.

## Safe to ship, safe to commit

These identify your app. They authorise nothing on their own.

- AdMob app id and ad unit ids
- AppLovin **SDK** key
- Firebase app id, Web API key, project id, sender id, database URL
- `google-services.json` and `GoogleService-Info.plist` *(they contain only the
  above — but keep them out of a public repository anyway: they name your project
  to anyone browsing it, and there is no reason to make that easy)*
- Store product ids
- Play Games **numeric project id**
- The Play Games server **client id** (the id, not the secret)

A Firebase Web API key in particular identifies a project; access is decided by
your database and storage **rules**, not by the key. If your rules allow anything
to anyone, the key is not what is wrong.

## Never in a game project

- **A Google service-account private key** (`*.json` with `"private_key"` in it).
  Never. Not in the APK, not in the repository, not in a Godot resource. Anyone
  who has it can act as your service account.
- **An OAuth client secret.** It stays on the server that exchanges auth codes.
- **A Play Developer API key or refresh token.**
- **An AppLovin management/report key** (different from the SDK key).
- **Any signing keystore or its passwords.**

If a Google API needs a service account, the **server** performs that call. The
game never holds the credential.

## Identity, done safely

The SDK never asks for an email address, an account name, or an OAuth token, and
there is no method in it that could return one.

To let a server know who a player is:

```gdscript
MobileServices.play_games.server_access_granted.connect(func(auth_code):
    my_backend.sign_in(auth_code)     # the SERVER exchanges it with Google
)
MobileServices.player.request_server_side_access()
```

The code is single-use and worthless without your server's client secret. The
game never holds a token. On iOS, Game Center has no equivalent — use
`GKLocalPlayer` identity verification from your server instead.

## Purchases

The entitlement cache is on the device and is editable by anyone who wants to
edit it. For a small game that is the right trade — see
[`iap.md`](iap.md#the-security-limit-stated-plainly) — and for anything with
meaningful revenue, verify the purchase token on a server.

**Never log a purchase token.** `MSLog.redact` strips anything whose key contains
`token`, `signature`, `receipt`, `secret`, `password`, `credential`, `auth_code`,
`id_token` or `email` from everything this SDK prints and from every diagnostics
dump. Do the same in your own code.

## The diagnostics dump

`MobileServices.get_diagnostics()` is designed to be pasted into a bug report. It
carries the SDK and engine versions, the device, which native plugins are
present, which services started and what the last failure of each was.

It does **not** carry ad unit ids, product ids, API keys, purchase tokens or the
player's platform account. It does carry the anonymous installation id, on
purpose: a support conversation that cannot name the player cannot get anywhere,
and that id is random, per install, and traceable to nothing.

## R8 and minification

Each native module ships `consumer-rules.pro`, so a game gets the right keep
rules without editing its own ProGuard files. Godot instantiates plugin classes
**by name** from a manifest entry and calls `@UsedByGodot` methods
**reflectively**; R8 sees neither, so without those rules a minified release
build removes the lot and the plugin simply does not exist —
`Engine.has_singleton()` answers false and every call returns
`SERVICE_UNAVAILABLE`, with no error anywhere to explain it.

If you add your own `-dontobfuscate`-style exceptions, do not remove
`-keep class com.bilalsafdar.godot.mobileservices.** { *; }`.

## Checklist before a release build

- [ ] `core/test_mode = false` *(the export plugin fails the build otherwise)*
- [ ] Real ad unit ids, not Google's test units
- [ ] `ads/test_device_ids` empty, or only devices you own
- [ ] No service-account key, keystore or client secret anywhere in `res://`
- [ ] `consent/enabled = true` if you ship to the EEA, the UK or Switzerland
- [ ] Firebase database and storage **rules** reviewed, not just the API key
- [ ] The Data Safety / App Privacy form matches what your config actually
      enables — see [`privacy.md`](privacy.md)
- [ ] A release build installed from a store track, with a purchase and a
      rewarded ad tested end to end
