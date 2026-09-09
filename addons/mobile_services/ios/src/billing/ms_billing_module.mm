/**************************************************************************/
/*  ms_billing_module.mm — registration. See ms_core_module.mm.           */
/**************************************************************************/

#import "ms_billing.h"

#import "platform/ios/app_delegate.h"
#import <UIKit/UIKit.h>

MS_REGISTER_PLUGIN(MobileServicesBilling, "MobileServicesBilling", ms_billing)

@interface MobileServicesBillingDelegate : NSObject <GodotAppDelegateService>
@end

@implementation MobileServicesBillingDelegate

+ (void)load {
	[GodotAppDelegate addService:[[MobileServicesBillingDelegate alloc] init]];
}

- (BOOL)application:(UIApplication *)application
		didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	ms_billing_init();
	return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
	ms_billing_deinit();
}

@end
