/**************************************************************************/
/*  ms_gamecenter.h — MobileServicesPlayGames on iOS (Game Center)        */
/**************************************************************************/
/*
 * Game Center, registered under the SAME singleton name as Android's Play Games
 * module — `MobileServicesPlayGames` — so one GDScript service drives both.
 *
 * WHERE THE TWO GENUINELY DIFFER, and this file does not pretend otherwise:
 *
 * - Game Center achievements take a PERCENTAGE complete; Play Games takes a
 *   number of steps to add. `incrementAchievement` translates by reading the
 *   current percentage and adding, which needs a round trip Play Games does not.
 * - There is no server-side authorisation code. `getSupportedFeatures` leaves
 *   "server_access" out, and the GDScript side answers UNSUPPORTED.
 * - Authentication presents a view controller the player can dismiss, where Play
 *   Games v2 has usually signed them in before the first frame.
 */

#ifndef MS_GAMECENTER_H
#define MS_GAMECENTER_H

#include "core/object/object.h"
#include "ms_common.h"

class MobileServicesGameCenter : public Object {
	GDCLASS(MobileServicesGameCenter, Object);

	static MobileServicesGameCenter *instance;
	bool authenticated = false;
	String last_error;

protected:
	static void _bind_methods();

public:
	static MobileServicesGameCenter *get_singleton();

	void initialize_play_games(const String &p_server_client_id);
	String get_supported_features() const;
	bool is_authenticated() const { return authenticated; }
	String last_error_message() const { return last_error; }

	void sign_in();
	void unlock_achievement(const String &p_id);
	void increment_achievement(const String &p_id, int p_steps);
	void show_achievements();
	void submit_score(const String &p_leaderboard_id, int p_score);
	void show_leaderboard(const String &p_leaderboard_id);
	void request_server_side_access(bool p_force_refresh);
	void save_game(const String &p_slot, const String &p_data_base64, const String &p_description);
	void load_game(const String &p_slot);

	/** Called from the GameKit callbacks. Not bound to GDScript. */
	void report_signed_in(const String &p_id, const String &p_name);
	void report_sign_in_failed(int p_code, const String &p_message);
	void report_failed(const String &p_operation, int p_code, const String &p_message);
	void report_saved(const String &p_slot);
	void report_loaded(const String &p_slot, const String &p_data_base64);

	MobileServicesGameCenter();
	~MobileServicesGameCenter();
};

#endif // MS_GAMECENTER_H
