/**************************************************************************/
/*  ms_core.mm                                                            */
/**************************************************************************/

#import "ms_core.h"

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>
#import <netinet/in.h>
#import <sys/sysctl.h>

static NSString *const kKeychainService = @"com.mobileservices.installation";
static NSString *const kKeychainAccount = @"installation_id";

MobileServicesCore *MobileServicesCore::instance = nullptr;

/**
 * Reads the installation id out of the keychain.
 *
 * `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on the write side is
 * deliberate: the id must be readable while the game runs in the background
 * (after first unlock) but must NOT travel to the player's other devices through
 * an encrypted backup, because two devices sharing one "installation" id is
 * exactly what the name says it is not.
 */
static NSString *ms_keychain_read() {
	NSDictionary *query = @{
		(__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
		(__bridge id)kSecAttrService : kKeychainService,
		(__bridge id)kSecAttrAccount : kKeychainAccount,
		(__bridge id)kSecReturnData : @YES,
		(__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
	};
	CFTypeRef result = NULL;
	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
	if (status != errSecSuccess || result == NULL) {
		return nil;
	}
	NSData *data = (__bridge_transfer NSData *)result;
	return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static void ms_keychain_write(NSString *value) {
	NSDictionary *query = @{
		(__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
		(__bridge id)kSecAttrService : kKeychainService,
		(__bridge id)kSecAttrAccount : kKeychainAccount,
	};
	SecItemDelete((__bridge CFDictionaryRef)query);
	if (value.length == 0) {
		return;
	}
	NSMutableDictionary *item = [query mutableCopy];
	item[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
	item[(__bridge id)kSecAttrAccessible] =
			(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
	SecItemAdd((__bridge CFDictionaryRef)item, NULL);
}

MobileServicesCore *MobileServicesCore::get_singleton() {
	return instance;
}

void MobileServicesCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("getInstallationId"), &MobileServicesCore::get_installation_id);
	ClassDB::bind_method(D_METHOD("setInstallationId", "id"), &MobileServicesCore::set_installation_id);
	ClassDB::bind_method(D_METHOD("getDeviceInfo"), &MobileServicesCore::get_device_info);
	ClassDB::bind_method(D_METHOD("isNetworkAvailable"), &MobileServicesCore::is_network_available);
	ClassDB::bind_method(D_METHOD("getNativeVersion"), &MobileServicesCore::get_native_version);
	ClassDB::bind_method(D_METHOD("lastError"), &MobileServicesCore::last_error_message);
}

String MobileServicesCore::get_installation_id() {
	@autoreleasepool {
		NSString *existing = ms_keychain_read();
		if (existing.length > 0) {
			return ms_str(existing);
		}
		NSString *fresh = [[NSUUID UUID] UUIDString];
		ms_keychain_write(fresh);
		return ms_str(fresh);
	}
}

void MobileServicesCore::set_installation_id(const String &p_id) {
	@autoreleasepool {
		ms_keychain_write(ms_ns(p_id));
	}
}

String MobileServicesCore::get_device_info() {
	@autoreleasepool {
		// `utsname.machine` rather than UIDevice.model: the latter answers
		// "iPhone" for every iPhone ever made, which tells a bug report nothing.
		size_t size = 0;
		sysctlbyname("hw.machine", NULL, &size, NULL, 0);
		char *machine = (char *)malloc(size + 1);
		String hardware;
		if (machine != NULL) {
			sysctlbyname("hw.machine", machine, &size, NULL, 0);
			machine[size] = '\0';
			hardware = String::utf8(machine);
			free(machine);
		}
		UIDevice *device = [UIDevice currentDevice];
		NSDictionary *info = @{
			@"manufacturer" : @"Apple",
			@"model" : ms_ns(hardware),
			@"device" : device.model ?: @"",
			@"ios_version" : device.systemVersion ?: @"",
			@"package" : [[NSBundle mainBundle] bundleIdentifier] ?: @"",
		};
		return ms_json_from_dictionary(info);
	}
}

/**
 * Whether the device believes it has a route to the internet.
 *
 * SCNetworkReachability rather than NWPathMonitor because it answers
 * synchronously, which is what the GDScript API here is: an advisory yes/no for
 * a "you appear to be offline" message. Everything in this SDK still handles a
 * request that fails regardless of what this says.
 */
bool MobileServicesCore::is_network_available() {
	@autoreleasepool {
		struct sockaddr_in address;
		bzero(&address, sizeof(address));
		address.sin_len = sizeof(address);
		address.sin_family = AF_INET;
		SCNetworkReachabilityRef target =
				SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&address);
		if (target == NULL) {
			return false;
		}
		SCNetworkReachabilityFlags flags;
		bool got = SCNetworkReachabilityGetFlags(target, &flags);
		CFRelease(target);
		if (!got) {
			return false;
		}
		bool reachable = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
		bool needs_connection = (flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0;
		return reachable && !needs_connection;
	}
}

String MobileServicesCore::get_native_version() {
	// Must match MobileServices.VERSION in GDScript and BuildInfo.VERSION on
	// Android; tests/test_versions.gd checks that they agree.
	return String("2.0.0");
}

MobileServicesCore::MobileServicesCore() {
	ERR_FAIL_COND(instance != nullptr);
	instance = this;
}

MobileServicesCore::~MobileServicesCore() {
	if (instance == this) {
		instance = nullptr;
	}
}
