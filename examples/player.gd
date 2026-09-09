extends Node
## Identity, sign-in, achievements, leaderboards and a cloud save.
##
## The rule underneath all of it: the game must work for a player who never signs
## in. Play Services is missing on some devices, Game Center is off in Settings
## for plenty of people, and some players simply decline.

func _ready() -> void:
	# There is ALWAYS an id, from the first launch, whether or not anyone signs
	# in — and it does not change when they do.
	print("player: %s" % MobileServices.player.get_id())

	MobileServices.player.signed_in.connect(func(_id, display_name):
		%Greeting.text = "Hello, %s" % display_name
		%LeaderboardButton.disabled = false
	)
	MobileServices.player.sign_in_failed.connect(func(_error):
		# Normal, not an error dialog. Hide what needs an account and move on.
		%LeaderboardButton.disabled = true
		%AchievementsButton.disabled = true
	)
	MobileServices.play_games.game_loaded.connect(_on_cloud_save_loaded)
	MobileServices.play_games.operation_failed.connect(_on_play_games_failed)


func _on_sign_in_pressed() -> void:
	MobileServices.player.sign_in()


# --- Achievements and leaderboards --------------------------------------

func on_first_win() -> void:
	MobileServices.play_games.unlock_achievement("first_win")
	MobileServices.analytics.log_unlock_achievement("first_win")


func on_enemy_defeated() -> void:
	# Set incremental achievements to 100 total steps in the Play Console: Game
	# Center stores a percentage, so a step is then a percentage point and one
	# call means the same thing on both platforms.
	MobileServices.play_games.increment_achievement("hundred_enemies", 1)


func on_run_finished(score: int) -> void:
	MobileServices.play_games.submit_score("high_scores", score)
	MobileServices.analytics.log_post_score(score)


func _on_leaderboard_pressed() -> void:
	# There is no way to build this screen from the APIs, and no need to.
	MobileServices.play_games.show_leaderboard("high_scores")


# --- Cloud saves --------------------------------------------------------

## Save LOCALLY first, always. A cloud save fails off-line, conflicts between
## devices, and does not exist for a player who declined sign-in. Treat it as the
## copy that survives a new phone, not as the save.
func save_game(state: Dictionary) -> void:
	var bytes := var_to_bytes(state)
	var file := FileAccess.open("user://save.dat", FileAccess.WRITE)
	if file != null:
		file.store_buffer(bytes)
		file.close()
	if MobileServices.play_games.is_supported(MSPlayGames.FEATURE_SAVED_GAMES):
		MobileServices.play_games.save_game("main", bytes, "Level %d" % state.get("level", 1))


func try_load_from_cloud() -> void:
	MobileServices.play_games.load_game("main")


func _on_cloud_save_loaded(_slot: String, data: PackedByteArray) -> void:
	var state = bytes_to_var(data)
	if not (state is Dictionary):
		return
	# Both platforms resolve conflicts by taking the most recently modified save,
	# which is right for a single-player game — but a player who progressed on
	# two devices can still end up behind. Keeping a counter in the payload lets
	# the game refuse a save older than the local one.
	if int(state.get("version", 0)) > local_save_version:
		apply(state)


func _on_play_games_failed(operation: String, error: Dictionary) -> void:
	if operation == "load_game" and error["code"] == MSError.NOT_READY:
		return   # No cloud save yet. A first launch, not a failure.
	push_warning("%s: %s" % [operation, MSError.describe(error)])


# --- Telling a server who the player is ---------------------------------

## The only safe shape: the game never sees a token, the code is single-use, and
## it is worthless without the server's own client secret — which stays on the
## server. Android only; Game Center has no equivalent.
func sign_in_to_backend() -> void:
	MobileServices.play_games.server_access_granted.connect(
		func(auth_code): my_backend_sign_in(auth_code),
		CONNECT_ONE_SHOT
	)
	MobileServices.player.request_server_side_access()


var local_save_version := 0
func apply(_state: Dictionary) -> void: pass
func my_backend_sign_in(_auth_code: String) -> void: pass
