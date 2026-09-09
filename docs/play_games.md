# Play Games Services and Game Center

One API, two platforms. `MobileServices.play_games` is Google Play Games
Services on Android and Game Center on iOS — the same method names, the same
signals, the same singleton name underneath.

```gdscript
MobileServices.play_games.unlock_achievement("first_win")
MobileServices.play_games.submit_score("high_scores", 12000)
MobileServices.play_games.show_leaderboard("high_scores")
```

## Where they genuinely differ

The SDK does not pretend the platforms are the same shape. `is_supported()`
answers per feature, and the differences that leak through are these:

| | Play Games v2 | Game Center |
|---|---|---|
| Sign-in | automatic at launch; `sign_in()` usually just confirms it | presents a controller the player can dismiss |
| Sign-out | none — the account belongs to the device | none |
| Achievements | incremental, in **steps** | a **percentage** complete |
| Cloud saves | Snapshots | iCloud saved games |
| Server-side identity | `requestServerSideAccess` → a one-time auth code | none; use `GKLocalPlayer` identity verification |
| `is_supported("server_access")` | `true` | `false` |

### Incremental achievements

Play Games takes a number of **steps to add**; Game Center stores a
**percentage**. `increment_achievement(id, steps)` translates, and the iOS side
has to read the current percentage first — a round trip Android does not need.

To have one call work correctly on both, **set every incremental achievement's
total steps to 100** in the Play Console. Then a step is a percentage point on
both platforms and the numbers mean the same thing.

## Everything must work without it

Players decline sign-in, Play Services is missing on some devices and every
emulator image without Google APIs, and Game Center is switched off in Settings
for plenty of people. Achievements and leaderboards are extras layered on a game
that already works; the SDK never blocks on them and neither should you.

```gdscript
func _ready() -> void:
    MobileServices.play_games.sign_in_failed.connect(func(_error):
        $LeaderboardButton.disabled = true      # not an error dialog
    )
```

## Cloud saves

```gdscript
func save_to_cloud() -> void:
    var bytes := var_to_bytes(game_state)
    MobileServices.play_games.save_game("main", bytes, "Level %d" % level)

func _ready() -> void:
    MobileServices.play_games.game_loaded.connect(func(slot, data):
        game_state = bytes_to_var(data)
    )
    MobileServices.play_games.operation_failed.connect(func(op, error):
        if op == "load_game" and error["code"] == MSError.NOT_READY:
            pass    # No save yet. Not a failure — a first launch.
    )
    MobileServices.play_games.load_game("main")
```

**Not a replacement for a local save.** Cloud saves fail off-line, conflict
between devices, and are unavailable to a player who declined sign-in. Save
locally first and treat this as the copy that survives a new phone.

Both platforms resolve conflicts by taking the most recently modified save. That
is right for a single-player game and wrong for anything where a player might
progress on two devices at once — put a version counter inside your own payload
if you care.

Play Games Snapshots also need **Saved Games** switched on in the Play Console,
or every call fails with an unhelpful message.

## Setup

Android needs the **numeric project id** in `player/play_games_app_id`. Without
it Play Games refuses to authenticate and says so only in logcat. It also needs
a credential for your app's signing certificate, and testers added — sign-in
fails for everyone who is not one.

iOS needs the **Game Center capability** in the provisioning profile, and
leaderboards and achievements configured in App Store Connect.

Full steps in [`installation.md`](installation.md).

## Common failures

| What you see | Why |
|---|---|
| Sign-in fails silently on every device | `play_games_app_id` missing or wrong |
| Sign-in fails for everyone but you | testers not added in the Play Console |
| Sign-in fails on an emulator | the image has no Google APIs; use one that does |
| Achievements never appear | the ids in your code are not the ids in the console |
| Snapshots always fail | Saved Games not enabled in the Play Console |
| Leaderboard shows nothing on iOS | the leaderboard is not yet live in App Store Connect |
