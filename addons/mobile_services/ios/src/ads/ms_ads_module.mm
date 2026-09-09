/**************************************************************************/
/*  ms_ads_module.mm — registration. See ms_core_module.mm.               */
/**************************************************************************/

#import "ms_ads.h"

#import "platform/ios/app_delegate.h"
#import <UIKit/UIKit.h>

MS_REGISTER_PLUGIN(MobileServicesAds, "MobileServicesAds", ms_ads)

@interface MobileServicesAdsDelegate : NSObject <GodotAppDelegateService>
@end

@implementation MobileServicesAdsDelegate

+ (void)load {
	[GodotAppDelegate addService:[[MobileServicesAdsDelegate alloc] init]];
}

- (BOOL)application:(UIApplication *)application
		didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	ms_ads_init();
	return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
	ms_ads_deinit();
}

@end
