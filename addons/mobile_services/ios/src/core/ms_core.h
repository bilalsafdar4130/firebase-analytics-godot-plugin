/**************************************************************************/
/*  ms_core.h — the MobileServicesCore singleton on iOS                   */
/**************************************************************************/
/*
 * The iOS half of `MobileServicesCore`. Same singleton name, same methods and
 * the same return shapes as the Android module, so GDScript cannot tell them
 * apart — see android/core/.../MobileServicesCorePlugin.kt, which this mirrors
 * line for line in intent.
 *
 * THE INSTALLATION ID IS NOT `identifierForVendor`. It is a random UUID kept in
 * the KEYCHAIN, which matters: `NSUserDefaults` is wiped by a reinstall and
 * `identifierForVendor` changes when the last app from a vendor is removed, so
 * both would silently hand a returning player a new identity. The keychain entry
 * survives a reinstall and is still deleted when the player asks, because
 * MSPlayer.reset_id() deletes it.
 */

#ifndef MS_CORE_H
#define MS_CORE_H

#include "core/object/object.h"
#include "ms_common.h"

class MobileServicesCore : public Object {
	GDCLASS(MobileServicesCore, Object);

	static MobileServicesCore *instance;
	String last_error;

protected:
	static void _bind_methods();

public:
	static MobileServicesCore *get_singleton();

	String get_installation_id();
	void set_installation_id(const String &p_id);
	String get_device_info();
	bool is_network_available();
	String get_native_version();
	String last_error_message() const { return last_error; }

	MobileServicesCore();
	~MobileServicesCore();
};

#endif // MS_CORE_H
