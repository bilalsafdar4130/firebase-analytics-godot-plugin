package com.bilalsafdar.godot.mobileservices.playgames

import android.util.Base64
import com.google.android.gms.games.PlayGames
import com.google.android.gms.games.PlayGamesSdk
import com.google.android.gms.games.SnapshotsClient
import com.google.android.gms.games.snapshot.Snapshot
import com.google.android.gms.games.snapshot.SnapshotMetadataChange
import com.bilalsafdar.godot.mobileservices.core.MobileServicesPlugin
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot

/**
 * Google Play Games Services v2.
 *
 * V2 IS NOT V1, and the difference shapes this whole class. Play Games v2 signs
 * the player in AUTOMATICALLY at app start, has no explicit sign-out, needs no
 * `GoogleSignInClient`, and asks for no scopes. [signIn] therefore usually just
 * confirms what has already happened; the prompt only appears for a player who
 * has previously declined.
 *
 * IT ALSO FAILS FOR PERFECTLY ORDINARY REASONS. No Play Store on the device, an
 * emulator image without Play Services, a player who declined once, a game not
 * yet published to a test track. All of those are normal, none of them is worth
 * interrupting a player over, and every one of them reaches GDScript as a
 * failure signal the game is free to ignore.
 *
 * THE MANIFEST MUST CARRY THE PROJECT ID or nothing here works at all — Play
 * Games refuses to authenticate and says so only in logcat. The export plugin
 * writes it from `player/play_games_app_id`.
 */
class MobileServicesPlayGamesPlugin(godot: Godot) : MobileServicesPlugin(godot) {

	companion object {
		const val PLUGIN_NAME = "MobileServicesPlayGames"

		/** Matches `MSError` on the GDScript side, which maps these to its own
		 * vocabulary. */
		private const val CODE_CANCELLED = 1
		private const val CODE_NETWORK = 2
		private const val CODE_UNSUPPORTED = 3
		private const val CODE_NOT_READY = 4

		/** Arbitrary but stable; Play Games' own UI comes back through
		 * onMainActivityResult and nothing here reads the result. */
		private const val REQUEST_UI = 0x4D53
	}

	override fun getPluginName(): String = PLUGIN_NAME

	override fun getPluginSignals(): MutableSet<SignalInfo> = mutableSetOf(
		SignalInfo("play_games_signed_in", String::class.java, String::class.java),
		SignalInfo(
			"play_games_sign_in_failed",
			Int::class.javaObjectType, String::class.java
		),
		SignalInfo("play_games_achievement_unlocked", String::class.java),
		SignalInfo("play_games_achievements_loaded", String::class.java),
		SignalInfo("play_games_score_submitted", String::class.java, Int::class.javaObjectType),
		SignalInfo("play_games_server_access", String::class.java),
		SignalInfo("play_games_saved", String::class.java),
		SignalInfo("play_games_loaded", String::class.java, String::class.java),
		SignalInfo(
			"play_games_failed",
			String::class.java, Int::class.javaObjectType, String::class.java
		)
	)

	private var serverClientId: String = ""
	private var authenticated = false

	@UsedByGodot
	fun initializePlayGames(clientId: String) = onUi("initializePlayGames") {
		serverClientId = clientId
		val activity = getActivity() ?: return@onUi
		// Safe to call more than once; the SDK guards it internally.
		PlayGamesSdk.initialize(activity)
	}

	/** Which of this SDK's optional features Android actually has. The iOS half
	 * answers a shorter list — see docs/play_games.md. */
	@UsedByGodot
	fun getSupportedFeatures(): String =
		"achievements,leaderboards,saved_games,server_access"

	@UsedByGodot
	fun isAuthenticated(): Boolean = authenticated

	@UsedByGodot
	fun lastError(): String = lastFailure

	/**
	 * Confirms the automatic sign-in, or prompts when it did not happen.
	 *
	 * `isAuthenticated` first, `signIn` only if that says no: calling `signIn`
	 * unconditionally shows a prompt to a player who is already signed in on
	 * some Play Services versions, which is a jarring thing to do on launch.
	 */
	@UsedByGodot
	fun signIn() = onUi("signIn") {
		val activity = getActivity() ?: return@onUi
		val client = PlayGames.getGamesSignInClient(activity)
		client.isAuthenticated.addOnCompleteListener { task ->
			safely("signIn/isAuthenticated") {
				if (task.isSuccessful && task.result.isAuthenticated) {
					authenticated = true
					loadPlayer()
					return@safely
				}
				client.signIn().addOnCompleteListener { attempt ->
					safely("signIn/signIn") {
						if (attempt.isSuccessful && attempt.result.isAuthenticated) {
							authenticated = true
							loadPlayer()
						} else {
							authenticated = false
							signal(
								"play_games_sign_in_failed", CODE_CANCELLED,
								attempt.exception?.message
									?: "the player is not signed in to Play Games"
							)
						}
					}
				}
			}
		}
	}

	private fun loadPlayer() {
		val activity = getActivity() ?: return
		PlayGames.getPlayersClient(activity).currentPlayer
			.addOnSuccessListener { player ->
				safely("loadPlayer") {
					logInfo("signed in to Play Games")
					signal(
						"play_games_signed_in",
						player.playerId ?: "",
						player.displayName ?: ""
					)
				}
			}
			.addOnFailureListener { error ->
				signal(
					"play_games_sign_in_failed", CODE_NETWORK,
					error.message ?: "could not read the player profile"
				)
			}
	}

	// --- Achievements ---------------------------------------------------

	@UsedByGodot
	fun unlockAchievement(achievementId: String) = onUi("unlockAchievement") {
		val activity = getActivity() ?: return@onUi
		// `unlock` is fire-and-forget by design: Play Games queues it and
		// retries when the device comes back online, so there is no callback to
		// wait on and no failure a game could act on.
		PlayGames.getAchievementsClient(activity).unlock(achievementId)
		signal("play_games_achievement_unlocked", achievementId)
	}

	@UsedByGodot
	fun incrementAchievement(achievementId: String, steps: Int) = onUi("incrementAchievement") {
		val activity = getActivity() ?: return@onUi
		PlayGames.getAchievementsClient(activity).increment(achievementId, steps)
	}

	@UsedByGodot
	fun showAchievements() = onUi("showAchievements") {
		val activity = getActivity() ?: return@onUi
		PlayGames.getAchievementsClient(activity).achievementsIntent
			.addOnSuccessListener { intent ->
				safely("showAchievements") { activity.startActivityForResult(intent, REQUEST_UI) }
			}
			.addOnFailureListener { error -> report("show_achievements", error) }
	}

	// --- Leaderboards ---------------------------------------------------

	@UsedByGodot
	fun submitScore(leaderboardId: String, score: Int) = onUi("submitScore") {
		val activity = getActivity() ?: return@onUi
		PlayGames.getLeaderboardsClient(activity).submitScore(leaderboardId, score.toLong())
		signal("play_games_score_submitted", leaderboardId, score)
	}

	@UsedByGodot
	fun showLeaderboard(leaderboardId: String) = onUi("showLeaderboard") {
		val activity = getActivity() ?: return@onUi
		val client = PlayGames.getLeaderboardsClient(activity)
		val task = if (leaderboardId.isEmpty()) {
			client.allLeaderboardsIntent
		} else {
			client.getLeaderboardIntent(leaderboardId)
		}
		task.addOnSuccessListener { intent ->
			safely("showLeaderboard") { activity.startActivityForResult(intent, REQUEST_UI) }
		}.addOnFailureListener { error -> report("show_leaderboard", error) }
	}

	// --- Server-side identity -------------------------------------------

	/**
	 * A one-time authorisation code for a server to exchange with Google.
	 *
	 * THE ONLY SAFE SHAPE FOR SERVER-SIDE IDENTITY: the game never sees a token,
	 * the code is single-use, and it is worthless without the server's own client
	 * secret — which stays on the server and must never be in a game project.
	 */
	@UsedByGodot
	fun requestServerSideAccess(forceRefresh: Boolean) = onUi("requestServerSideAccess") {
		val activity = getActivity() ?: return@onUi
		if (serverClientId.isEmpty()) {
			signal(
				"play_games_failed", "server_access", CODE_NOT_READY,
				"player/play_games_server_client_id is empty in mobile_services.cfg"
			)
			return@onUi
		}
		PlayGames.getGamesSignInClient(activity)
			.requestServerSideAccess(serverClientId, forceRefresh)
			.addOnSuccessListener { code ->
				// Deliberately not logged: short-lived, but still a credential.
				safely("requestServerSideAccess") { signal("play_games_server_access", code) }
			}
			.addOnFailureListener { error -> report("server_access", error) }
	}

	// --- Cloud saves ----------------------------------------------------

	/**
	 * Writes a snapshot.
	 *
	 * Base64 in and out, because the JNI boundary in this SDK carries strings —
	 * see the GDScript side's "The native boundary" note. A small game's save is
	 * a few kilobytes and Play's own limit is 3 MB, so the ~33% the encoding
	 * costs is not the constraint.
	 *
	 * MOST_RECENTLY_MODIFIED resolves conflicts by taking the newer save. That is
	 * the right default for a single-player game and the wrong one for anything
	 * where a player might progress on two devices at once — a game that cares
	 * should keep its own version counter inside the payload.
	 */
	@UsedByGodot
	fun saveGame(slot: String, dataBase64: String, description: String) = onUi("saveGame") {
		val activity = getActivity() ?: return@onUi
		val client = PlayGames.getSnapshotsClient(activity)
		client.open(slot, true, SnapshotsClient.RESOLUTION_POLICY_MOST_RECENTLY_MODIFIED)
			.addOnSuccessListener { result ->
				safely("saveGame/commit") {
					val snapshot: Snapshot? = result.data
					if (snapshot == null) {
						signal(
							"play_games_failed", "save_game", CODE_NOT_READY,
							"the save slot is in conflict and could not be opened"
						)
						return@safely
					}
					snapshot.snapshotContents.writeBytes(
						Base64.decode(dataBase64, Base64.NO_WRAP)
					)
					client.commitAndClose(
						snapshot,
						SnapshotMetadataChange.Builder().setDescription(description).build()
					)
						.addOnSuccessListener { signal("play_games_saved", slot) }
						.addOnFailureListener { error -> report("save_game", error) }
				}
			}
			.addOnFailureListener { error -> report("save_game", error) }
	}

	@UsedByGodot
	fun loadGame(slot: String) = onUi("loadGame") {
		val activity = getActivity() ?: return@onUi
		PlayGames.getSnapshotsClient(activity)
			.open(slot, false, SnapshotsClient.RESOLUTION_POLICY_MOST_RECENTLY_MODIFIED)
			.addOnSuccessListener { result ->
				safely("loadGame/read") {
					val snapshot = result.data
					if (snapshot == null) {
						signal(
							"play_games_failed", "load_game", CODE_NOT_READY,
							"no save in slot $slot"
						)
						return@safely
					}
					val bytes = snapshot.snapshotContents.readFully()
					signal(
						"play_games_loaded", slot,
						Base64.encodeToString(bytes, Base64.NO_WRAP)
					)
				}
			}
			.addOnFailureListener { error -> report("load_game", error) }
	}

	/**
	 * Turns any Play Services failure into one signal.
	 *
	 * `ApiException` carries a status code that says whether the player
	 * cancelled, the network is down, or the feature is unavailable on this
	 * device — the three cases a game handles differently and the reason this
	 * does not just forward a message.
	 */
	private fun report(operation: String, error: Throwable) {
		val code = when {
			error.message?.contains("NETWORK", true) == true -> CODE_NETWORK
			error.message?.contains("CANCEL", true) == true -> CODE_CANCELLED
			error.message?.contains("SIGN_IN", true) == true -> CODE_NOT_READY
			error.javaClass.simpleName.contains("ApiException") -> CODE_UNSUPPORTED
			else -> CODE_UNSUPPORTED
		}
		signal("play_games_failed", operation, code, error.message ?: error.javaClass.simpleName)
	}
}
