/**************************************************************************/
/*  ms_common.h — shared helpers for the Mobile Services iOS plugins       */
/**************************************************************************/
/*
 * WHAT AN iOS GODOT PLUGIN IS, because it is nothing like the Android one.
 *
 * On Android a plugin is a Kotlin class in an AAR that the engine finds through
 * a manifest entry. On iOS it is a STATIC LIBRARY compiled against the engine's
 * own C++ headers, packaged as an .xcframework, described by a .gdip file, and
 * linked into the Xcode project Godot generates. It therefore has to be built
 * on macOS with Xcode against a checkout of the Godot source at the same version
 * as the export templates — see tools/build_ios.sh.
 *
 * REGISTRATION happens through GodotAppDelegate's service list: each plugin's
 * module file adds itself in +load and creates its singleton when the app
 * finishes launching, which is after the engine's own setup and before the first
 * frame. MS_REGISTER_PLUGIN writes that boilerplate.
 *
 * THE BOUNDARY IS THE SAME AS ANDROID'S. Signals carry strings, ints, bools and
 * floats only; anything structured is a JSON string. The GDScript side cannot
 * tell the two platforms apart, which is the whole point — see the "The native
 * boundary" note in ms_service.gd.
 */

#ifndef MS_COMMON_H
#define MS_COMMON_H

#include "core/config/engine.h"
#include "core/object/class_db.h"
#include "core/object/object.h"
#include "core/variant/variant.h"

#import <Foundation/Foundation.h>

/** An NSDictionary of plain values as a JSON string, or "{}" if it cannot be
 * serialised. Never throws: a diagnostics payload is not worth an exception. */
String ms_json_from_dictionary(NSDictionary *dictionary);

/** An NSArray of dictionaries as a JSON array string. */
String ms_json_from_array(NSArray *array);

/** A JSON string as an NSDictionary, or an empty one when it does not parse. */
NSDictionary *ms_dictionary_from_json(const String &json);

/** An NSString from a Godot String, never nil. */
NSString *ms_ns(const String &value);

/** A Godot String from an NSString, empty when nil. */
String ms_str(NSString *value);

/**
 * Emits a signal on the engine's own thread.
 *
 * StoreKit, GameKit and the ad SDKs answer on queues of their own choosing, and
 * touching a Godot Object from one of them is undefined behaviour that shows up
 * as a crash somewhere else entirely. `call_deferred` hands the emission to the
 * main loop, which is the only safe way in.
 */
#define MS_EMIT(...) call_deferred(SNAME("emit_signal"), __VA_ARGS__)

/**
 * Writes the registration boilerplate for one plugin.
 *
 * `klass` is the C++ class, `name` the singleton name GDScript reaches it by —
 * and that name must match the Android module's, or the same GDScript would need
 * two code paths.
 */
#define MS_REGISTER_PLUGIN(klass, name, prefix)                                  \
	klass *prefix##_instance = nullptr;                                          \
                                                                                 \
	void prefix##_init() {                                                       \
		if (prefix##_instance != nullptr) {                                      \
			return;                                                              \
		}                                                                        \
		prefix##_instance = memnew(klass);                                       \
		Engine::get_singleton()->add_singleton(                                  \
				Engine::Singleton(name, prefix##_instance));                     \
	}                                                                            \
                                                                                 \
	void prefix##_deinit() {                                                     \
		if (prefix##_instance != nullptr) {                                      \
			memdelete(prefix##_instance);                                        \
			prefix##_instance = nullptr;                                         \
		}                                                                        \
	}

#endif // MS_COMMON_H
