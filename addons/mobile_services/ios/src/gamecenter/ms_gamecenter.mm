/**************************************************************************/
/*  ms_gamecenter.mm                                                      */
/**************************************************************************/

#import "ms_gamecenter.h"

#import <GameKit/GameKit.h>
#import <UIKit/UIKit.h>

MobileServicesGameCenter *MobileServicesGameCenter::instance = nullptr;

/** Matches the Android module's codes, which the GDScript side maps to MSError. */
static const int MS_GC_CANCELLED = 1;
static const int MS_GC_NETWORK = 2;
static const int MS_GC_UNSUPPORTED = 3;
static const int MS_GC_NOT_READY = 4;

static UIViewController *ms_gc_controller() {
	UIWindow *window = nil;
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if ([scene isKindOfClass:[UIWindowScene class]]) {
			for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
				if (candidate.isKeyWindow) {
					window = candidate;
					break;
				}
			}
		}
		if (window != nil) {
			break;
		}
	}
	if (window == nil) {
		window = [UIApplication sharedApplication].delegate.window;
	}
	return window.rootViewController;
}

@interface MSGameCenterDelegate : NSObject <GKGameCenterControllerDelegate>
+ (instancetype)shared;
@end

@implementation MSGameCenterDelegate

+ (instancetype)shared {
	static MSGameCenterDelegate *delegate = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		delegate = [[MSGameCenterDelegate alloc] init];
	});
	return delegate;
}

- (void)gameCenterViewControllerDidFinish:(GKGameCenterViewController *)controller {
	[controller dismissViewControllerAnimated:YES completion:nil];
}

@end

MobileServicesGameCenter *MobileServicesGameCenter::get_singleton() {
	return instance;
}

void MobileServicesGameCenter::_bind_methods() {
	ClassDB::bind_method(D_METHOD("initializePlayGames", "server_client_id"),
			&MobileServicesGameCenter::initialize_play_games);
	ClassDB::bind_method(D_METHOD("getSupportedFeatures"), &MobileServicesGameCenter::get_supported_features);
	ClassDB::bind_method(D_METHOD("isAuthenticated"), &MobileServicesGameCenter::is_authenticated);
	ClassDB::bind_method(D_METHOD("lastError"), &MobileServicesGameCenter::last_error_message);
	ClassDB::bind_method(D_METHOD("signIn"), &MobileServicesGameCenter::sign_in);
	ClassDB::bind_method(D_METHOD("unlockAchievement", "id"), &MobileServicesGameCenter::unlock_achievement);
	ClassDB::bind_method(D_METHOD("incrementAchievement", "id", "steps"),
			&MobileServicesGameCenter::increment_achievement);
	ClassDB::bind_method(D_METHOD("showAchievements"), &MobileServicesGameCenter::show_achievements);
	ClassDB::bind_method(D_METHOD("submitScore", "leaderboard_id", "score"),
			&MobileServicesGameCenter::submit_score);
	ClassDB::bind_method(D_METHOD("showLeaderboard", "leaderboard_id"),
			&MobileServicesGameCenter::show_leaderboard);
	ClassDB::bind_method(D_METHOD("requestServerSideAccess", "force_refresh"),
			&MobileServicesGameCenter::request_server_side_access);
	ClassDB::bind_method(D_METHOD("saveGame", "slot", "data", "description"),
			&MobileServicesGameCenter::save_game);
	ClassDB::bind_method(D_METHOD("loadGame", "slot"), &MobileServicesGameCenter::load_game);

	ADD_SIGNAL(MethodInfo("play_games_signed_in", PropertyInfo(Variant::STRING, "player_id"),
			PropertyInfo(Variant::STRING, "display_name")));
	ADD_SIGNAL(MethodInfo("play_games_sign_in_failed", PropertyInfo(Variant::INT, "code"),
			PropertyInfo(Variant::STRING, "message")));
	ADD_SIGNAL(MethodInfo("play_games_achievement_unlocked", PropertyInfo(Variant::STRING, "id")));
	ADD_SIGNAL(MethodInfo("play_games_achievements_loaded", PropertyInfo(Variant::STRING, "achievements")));
	ADD_SIGNAL(MethodInfo("play_games_score_submitted", PropertyInfo(Variant::STRING, "leaderboard_id"),
			PropertyInfo(Variant::INT, "score")));
	ADD_SIGNAL(MethodInfo("play_games_server_access", PropertyInfo(Variant::STRING, "auth_code")));
	ADD_SIGNAL(MethodInfo("play_games_saved", PropertyInfo(Variant::STRING, "slot")));
	ADD_SIGNAL(MethodInfo("play_games_loaded", PropertyInfo(Variant::STRING, "slot"),
			PropertyInfo(Variant::STRING, "data")));
	ADD_SIGNAL(MethodInfo("play_games_failed", PropertyInfo(Variant::STRING, "operation"),
			PropertyInfo(Variant::INT, "code"), PropertyInfo(Variant::STRING, "message")));
}

void MobileServicesGameCenter::initialize_play_games(const String &p_server_client_id) {
	// Nothing to configure: Game Center reads the app's bundle id and the Game
	// Center entitlement. The argument exists so the GDScript API is identical on
	// both platforms.
}

String MobileServicesGameCenter::get_supported_features() const {
	// No "server_access": Game Center has no equivalent of Play Games'
	// requestServerSideAccess. See the header.
	return String("achievements,leaderboards,saved_games");
}

/**
 * Sets Game Center's authentication handler.
 *
 * The handler is called MORE THAN ONCE over a session — on sign-in, on sign-out,
 * and when the player switches accounts — which is why authentication state is
 * kept rather than assumed after the first call.
 */
void MobileServicesGameCenter::sign_in() {
	@autoreleasepool {
		GKLocalPlayer *player = [GKLocalPlayer localPlayer];
		player.authenticateHandler = ^(UIViewController *controller, NSError *error) {
			MobileServicesGameCenter *plugin = MobileServicesGameCenter::get_singleton();
			if (!plugin) {
				return;
			}
			if (controller != nil) {
				UIViewController *root = ms_gc_controller();
				if (root != nil) {
					[root presentViewController:controller animated:YES completion:nil];
				}
				return;
			}
			if ([GKLocalPlayer localPlayer].isAuthenticated) {
				plugin->report_signed_in(ms_str([GKLocalPlayer localPlayer].gamePlayerID),
						ms_str([GKLocalPlayer localPlayer].displayName));
			} else {
				plugin->report_sign_in_failed(MS_GC_CANCELLED,
						error != nil ? ms_str(error.localizedDescription)
									 : String("the player is not signed in to Game Center"));
			}
		};
	}
}

void MobileServicesGameCenter::unlock_achievement(const String &p_id) {
	@autoreleasepool {
		GKAchievement *achievement = [[GKAchievement alloc] initWithIdentifier:ms_ns(p_id)];
		achievement.percentComplete = 100.0;
		achievement.showsCompletionBanner = YES;
		String identifier = p_id;
		[GKAchievement reportAchievements:@[ achievement ]
					withCompletionHandler:^(NSError *error) {
						MobileServicesGameCenter *plugin = MobileServicesGameCenter::get_singleton();
						if (!plugin) {
							return;
						}
						if (error != nil) {
							plugin->report_failed(String("unlock_achievement"), MS_GC_NETWORK,
									ms_str(error.localizedDescription));
						} else {
							plugin->MS_EMIT("play_games_achievement_unlocked", identifier);
						}
					}];
	}
}

/**
 * Adds steps to an incremental achievement.
 *
 * Game Center stores a PERCENTAGE, so the current value has to be read first and
 * the step count converted. `steps` is interpreted as percentage points, which
 * matches Play Games when an achievement's total steps is 100 — the convention
 * docs/play_games.md asks games to follow so one call works on both platforms.
 */
void MobileServicesGameCenter::increment_achievement(const String &p_id, int p_steps) {
	@autoreleasepool {
		NSString *identifier = ms_ns(p_id);
		double added = (double)p_steps;
		[GKAchievement loadAchievementsWithCompletionHandler:^(NSArray<GKAchievement *> *achievements,
				NSError *error) {
			MobileServicesGameCenter *plugin = MobileServicesGameCenter::get_singleton();
			if (!plugin) {
				return;
			}
			if (error != nil) {
				plugin->report_failed(String("increment_achievement"), MS_GC_NETWORK,
						ms_str(error.localizedDescription));
				return;
			}
			double current = 0.0;
			for (GKAchievement *existing in achievements) {
				if ([existing.identifier isEqualToString:identifier]) {
					current = existing.percentComplete;
					break;
				}
			}
			GKAchievement *updated = [[GKAchievement alloc] initWithIdentifier:identifier];
			updated.percentComplete = MIN(100.0, current + added);
			updated.showsCompletionBanner = YES;
			[GKAchievement reportAchievements:@[ updated ] withCompletionHandler:nil];
		}];
	}
}

void MobileServicesGameCenter::show_achievements() {
	@autoreleasepool {
		UIViewController *root = ms_gc_controller();
		if (root == nil) {
			report_failed(String("show_achievements"), MS_GC_NOT_READY, String("no view controller"));
			return;
		}
		GKGameCenterViewController *controller =
				[[GKGameCenterViewController alloc] initWithState:GKGameCenterViewControllerStateAchievements];
		controller.gameCenterDelegate = [MSGameCenterDelegate shared];
		[root presentViewController:controller animated:YES completion:nil];
	}
}

void MobileServicesGameCenter::submit_score(const String &p_leaderboard_id, int p_score) {
	@autoreleasepool {
		NSString *identifier = ms_ns(p_leaderboard_id);
		int score = p_score;
		[GKLeaderboard submitScore:score
					   context:0
						player:[GKLocalPlayer localPlayer]
				 leaderboardIDs:@[ identifier ]
			  completionHandler:^(NSError *error) {
				  MobileServicesGameCenter *plugin = MobileServicesGameCenter::get_singleton();
				  if (!plugin) {
					  return;
				  }
				  if (error != nil) {
					  plugin->report_failed(String("submit_score"), MS_GC_NETWORK,
							  ms_str(error.localizedDescription));
				  } else {
					  plugin->MS_EMIT("play_games_score_submitted", ms_str(identifier), score);
				  }
			  }];
	}
}

void MobileServicesGameCenter::show_leaderboard(const String &p_leaderboard_id) {
	@autoreleasepool {
		UIViewController *root = ms_gc_controller();
		if (root == nil) {
			report_failed(String("show_leaderboard"), MS_GC_NOT_READY, String("no view controller"));
			return;
		}
		GKGameCenterViewController *controller;
		if (p_leaderboard_id.is_empty()) {
			controller = [[GKGameCenterViewController alloc]
					initWithState:GKGameCenterViewControllerStateLeaderboards];
		} else {
			controller = [[GKGameCenterViewController alloc]
					initWithLeaderboardID:ms_ns(p_leaderboard_id)
							  playerScope:GKLeaderboardPlayerScopeGlobal
								timeScope:GKLeaderboardTimeScopeAllTime];
		}
		controller.gameCenterDelegate = [MSGameCenterDelegate shared];
		[root presentViewController:controller animated:YES completion:nil];
	}
}

void MobileServicesGameCenter::request_server_side_access(bool p_force_refresh) {
	// Game Center has no equivalent. Reported rather than silently ignored, so a
	// game sharing code between platforms finds out here rather than from a
	// server that never receives a code.
	report_failed(String("server_access"), MS_GC_UNSUPPORTED,
			String("Game Center has no server-side authorisation code; use "
				   "GKLocalPlayer identity verification instead. See docs/play_games.md."));
}

void MobileServicesGameCenter::save_game(const String &p_slot, const String &p_data_base64,
		const String &p_description) {
	@autoreleasepool {
		NSData *data = [[NSData alloc] initWithBase64EncodedString:ms_ns(p_data_base64) options:0];
		if (data == nil) {
			report_failed(String("save_game"), MS_GC_NOT_READY, String("the save data is not valid base64"));
			return;
		}
		NSString *slot = ms_ns(p_slot);
		[[GKLocalPlayer localPlayer] saveGameData:data
										 withName:slot
								completionHandler:^(GKSavedGame *saved, NSError *error) {
									MobileServicesGameCenter *plugin =
											MobileServicesGameCenter::get_singleton();
									if (!plugin) {
										return;
									}
									if (error != nil) {
										plugin->report_failed(String("save_game"), MS_GC_NETWORK,
												ms_str(error.localizedDescription));
									} else {
										plugin->report_saved(ms_str(slot));
									}
								}];
	}
}

void MobileServicesGameCenter::load_game(const String &p_slot) {
	@autoreleasepool {
		NSString *slot = ms_ns(p_slot);
		[[GKLocalPlayer localPlayer] fetchSavedGamesWithCompletionHandler:^(NSArray<GKSavedGame *> *saves,
				NSError *error) {
			MobileServicesGameCenter *plugin = MobileServicesGameCenter::get_singleton();
			if (!plugin) {
				return;
			}
			if (error != nil) {
				plugin->report_failed(String("load_game"), MS_GC_NETWORK,
						ms_str(error.localizedDescription));
				return;
			}
			GKSavedGame *newest = nil;
			for (GKSavedGame *save in saves) {
				if (![save.name isEqualToString:slot]) {
					continue;
				}
				// iCloud can hold several versions of one slot when two devices
				// wrote it; the newest is the only sensible default, and a game
				// that cares should version its own payload.
				if (newest == nil ||
						[save.modificationDate compare:newest.modificationDate] == NSOrderedDescending) {
					newest = save;
				}
			}
			if (newest == nil) {
				plugin->report_failed(String("load_game"), MS_GC_NOT_READY,
						String("no save in slot ") + ms_str(slot));
				return;
			}
			[newest loadDataWithCompletionHandler:^(NSData *data, NSError *loadError) {
				MobileServicesGameCenter *inner = MobileServicesGameCenter::get_singleton();
				if (!inner) {
					return;
				}
				if (loadError != nil || data == nil) {
					inner->report_failed(String("load_game"), MS_GC_NETWORK,
							loadError != nil ? ms_str(loadError.localizedDescription)
											 : String("the save could not be read"));
					return;
				}
				inner->report_loaded(ms_str(slot), ms_str([data base64EncodedStringWithOptions:0]));
			}];
		}];
	}
}

void MobileServicesGameCenter::report_signed_in(const String &p_id, const String &p_name) {
	authenticated = true;
	last_error = String();
	MS_EMIT("play_games_signed_in", p_id, p_name);
}

void MobileServicesGameCenter::report_sign_in_failed(int p_code, const String &p_message) {
	authenticated = false;
	last_error = p_message;
	MS_EMIT("play_games_sign_in_failed", p_code, p_message);
}

void MobileServicesGameCenter::report_failed(const String &p_operation, int p_code, const String &p_message) {
	last_error = p_message;
	MS_EMIT("play_games_failed", p_operation, p_code, p_message);
}

void MobileServicesGameCenter::report_saved(const String &p_slot) {
	MS_EMIT("play_games_saved", p_slot);
}

void MobileServicesGameCenter::report_loaded(const String &p_slot, const String &p_data_base64) {
	MS_EMIT("play_games_loaded", p_slot, p_data_base64);
}

MobileServicesGameCenter::MobileServicesGameCenter() {
	ERR_FAIL_COND(instance != nullptr);
	instance = this;
}

MobileServicesGameCenter::~MobileServicesGameCenter() {
	if (instance == this) {
		instance = nullptr;
	}
}
