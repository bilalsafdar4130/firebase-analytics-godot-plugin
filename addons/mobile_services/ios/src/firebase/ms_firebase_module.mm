/**************************************************************************/
/*  ms_firebase_module.mm — registration. See ms_core_module.mm.          */
/**************************************************************************/

#import "ms_firebase.h"

#import "platform/ios/app_delegate.h"
#import <UIKit/UIKit.h>

MS_REGISTER_PLUGIN(MobileServicesFirebase, "MobileServicesFirebase", ms_firebase)

@interface MobileServicesFirebaseDelegate : NSObject <GodotAppDelegateService>
@end

@implementation MobileServicesFirebaseDelegate

+ (void)load {
	[GodotAppDelegate addService:[[MobileServicesFirebaseDelegate alloc] init]];
}

- (BOOL)application:(UIApplication *)application
		didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	ms_firebase_init();
	return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
	ms_firebase_deinit();
}

@end
