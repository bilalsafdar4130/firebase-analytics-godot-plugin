package com.bilalsafdar.godot.mobileservices.core

/**
 * The SDK version, stated once on the native side.
 *
 * Must match `MobileServices.VERSION` in GDScript, `plugin.cfg`, and
 * `MobileServicesEditorConfig.VERSION`. `tests/test_versions.gd` checks that all
 * four agree — a mismatch means an AAR from one release running under GDScript
 * from another, which is the failure `MSNative` reports as a missing method.
 */
object BuildInfo {
	const val VERSION = "2.0.0"
}
