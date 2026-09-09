# Godot instantiates plugin classes by name, from the value of the
# <meta-data android:name="org.godotengine.plugin.v2.*"> entry in the merged
# manifest, and calls @UsedByGodot methods reflectively. R8 sees neither, so in
# a minified release build it removes the lot and the plugin simply does not
# exist — Engine.has_singleton() answers false and every call returns
# SERVICE_UNAVAILABLE, with no error anywhere to explain it.
#
# These rules travel with the AAR, so a game gets them without editing its own
# proguard files.
-keep class com.bilalsafdar.godot.mobileservices.** { *; }
-keepclassmembers class * extends org.godotengine.godot.plugin.GodotPlugin {
	public *;
}
-keep class org.godotengine.godot.plugin.UsedByGodot
-keepclasseswithmembers class * {
	@org.godotengine.godot.plugin.UsedByGodot <methods>;
}

# Only one provider's SDK is in a given build; the other's references must not
# fail R8. Which one is absent depends on ads/provider in mobile_services.cfg,
# so both are listed.
-dontwarn com.google.android.gms.ads.**
-dontwarn com.applovin.**
