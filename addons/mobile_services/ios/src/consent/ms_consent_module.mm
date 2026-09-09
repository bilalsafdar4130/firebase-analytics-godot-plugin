/**************************************************************************/
/*  ms_consent_module.mm — registration. See ms_core_module.mm.           */
/**************************************************************************/

#import "ms_consent.h"

#import "platform/ios/app_delegate.h"
#import <UIKit/UIKit.h>

MS_REGISTER_PLUGIN(MobileServicesConsent, "MobileServicesConsent", ms_consent)

@interface MobileServicesConsentDelegate : NSObject <GodotAppDelegateService>
@end

@implementation MobileServicesConsentDelegate

+ (void)load {
	[GodotAppDelegate addService:[[MobileServicesConsentDelegate alloc] init]];
}

- (BOOL)application:(UIApplication *)application
		didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	ms_consent_init();
	return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
	ms_consent_deinit();
}

@end
