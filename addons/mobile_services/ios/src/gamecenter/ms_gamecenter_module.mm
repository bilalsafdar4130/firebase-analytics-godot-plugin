/**************************************************************************/
/*  ms_gamecenter_module.mm — registration. See ms_core_module.mm.        */
/**************************************************************************/
/*
 * Registered under "MobileServicesPlayGames", the SAME name the Android module
 * uses. That is the whole reason one GDScript service can drive Play Games and
 * Game Center without a platform branch.
 */

#import "ms_gamecenter.h"

#import "platform/ios/app_delegate.h"
#import <UIKit/UIKit.h>

MS_REGISTER_PLUGIN(MobileServicesGameCenter, "MobileServicesPlayGames", ms_gamecenter)

@interface MobileServicesGameCenterDelegate : NSObject <GodotAppDelegateService>
@end

@implementation MobileServicesGameCenterDelegate

+ (void)load {
	[GodotAppDelegate addService:[[MobileServicesGameCenterDelegate alloc] init]];
}

- (BOOL)application:(UIApplication *)application
		didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	ms_gamecenter_init();
	return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
	ms_gamecenter_deinit();
}

@end
