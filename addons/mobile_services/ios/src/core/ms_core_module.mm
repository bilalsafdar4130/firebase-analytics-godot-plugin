/**************************************************************************/
/*  ms_core_module.mm — registration                                      */
/**************************************************************************/
/*
 * How the singleton comes into existence.
 *
 * `GodotAppDelegate` keeps a list of service objects and forwards the app
 * lifecycle to each. Adding one in +load runs before the app delegate itself,
 * and `application:didFinishLaunchingWithOptions:` then runs after the engine's
 * setup and before the first frame — which is where a singleton has to be
 * registered to exist by the time the first scene's _ready() looks for it.
 */

#import "ms_core.h"

#import "platform/ios/app_delegate.h"
#import <UIKit/UIKit.h>

MS_REGISTER_PLUGIN(MobileServicesCore, "MobileServicesCore", ms_core)

@interface MobileServicesCoreDelegate : NSObject <GodotAppDelegateService>
@end

@implementation MobileServicesCoreDelegate

+ (void)load {
	[GodotAppDelegate addService:[[MobileServicesCoreDelegate alloc] init]];
}

- (BOOL)application:(UIApplication *)application
		didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	ms_core_init();
	return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
	ms_core_deinit();
}

@end
