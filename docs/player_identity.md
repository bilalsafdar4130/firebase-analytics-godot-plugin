# Player identity

## There is always an id

```gdscript
var id := MobileServices.player.get_id()
```

Never empty. Never changes for the life of an install. Survives signing in and
signing out.

It starts as an **anonymous installation id** — a random UUID made on first
launch and kept on the device. If the player later signs in to Play Games or
Game Center, `get_provider()` changes and `get_provider_id()` gains the
platform's own id, but `get_id()` does **not** move: anything already keyed to it
keeps working.

That is the whole point. A game wants a stable id for save files, support
tickets, analytics and leaderboards. Written per-call, you end up with three code
paths and a save file that changes identity the day someone signs in.

## What it is not

The anonymous id is **not** derived from any hardware identifier — not the
advertising id, not `ANDROID_ID`, not `identifierForVendor`, not the IMEI. Two
installs on one phone get two ids and neither can be traced to the device. That
is what makes it usable without a consent prompt and safe to put in a bug report.

Where it lives:

| Platform | Store | Survives |
|---|---|---|
| Android | app-private SharedPreferences | app updates; **not** "clear data" or uninstall |
| iOS | the keychain, `AfterFirstUnlockThisDeviceOnly` | app updates **and reinstall**; not restored to another device |
| Everything else | `user://mobile_services_player.cfg` | as long as `user://` does |

The keychain choice on iOS is deliberate: `NSUserDefaults` is wiped by a
reinstall and `identifierForVendor` changes when the last app from a vendor is
removed, so both would silently hand a returning player a new identity.
`ThisDeviceOnly` keeps it out of encrypted backups, because two devices sharing
one "installation" id is exactly what the name says it is not.

## Signing in

Optional in every game this SDK is meant for. Refusing leaves the anonymous id in
place and everything keeps working.

```gdscript
func _ready() -> void:
    MobileServices.player.signed_in.connect(func(provider_id, name):
        $Greeting.text = "Hello, %s" % name
    )
    MobileServices.player.sign_in_failed.connect(func(error):
        pass  # Normal. No Play Services, an emulator, a player who declined.
    )

func _on_sign_in_pressed() -> void:
    MobileServices.player.sign_in()
```

On Android this is usually a silent confirmation — Play Games v2 has signed the
player in before your first frame — and shows a prompt only for someone who
previously declined. On iOS it presents Game Center's authentication controller,
which the player may dismiss; that is a `USER_CANCELLED`, not an error to show
them.

`sign_out()` is the **game** forgetting. Neither platform offers a real sign-out
— the account belongs to the device, and only the player can sign out of it from
the platform's own app.

## Analytics

With `analytics/sync_user_id = true` (the default), the player id becomes the
Firebase user id and a Crashlytics custom key automatically. You do not have to
do anything.

Do **not** put anything identifying a person into a user property. Property
values are visible in the Firebase console to everyone with project access, and
Firebase's own terms forbid personal data there. Skill band, chosen difficulty,
whether ads are removed — that is the shape of it.

## Telling a server who the player is

```gdscript
MobileServices.play_games.server_access_granted.connect(func(auth_code):
    my_backend.sign_in(auth_code)
)
MobileServices.player.request_server_side_access()
```

The **only** safe shape: the game never sees a token, the code is single-use, and
it is worthless without your server's client secret — which stays on the server.
Needs `player/play_games_server_client_id` (the **WEB** client id from the Google
Cloud console, not the Android one).

Android only. Game Center has no equivalent; use `GKLocalPlayer` identity
verification from your server instead.

## Deleting it

```gdscript
MobileServices.player.reset_id()      # a new anonymous id
MobileServices.analytics.reset_data() # a new Firebase app instance id
```

Together those are the whole of what a player can ask to have erased, because
there is no account to close.
