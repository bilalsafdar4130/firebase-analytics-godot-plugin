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

# Crashlytics and Remote Config are reached only after a Class.forName check, so
# an app that ships neither must not have R8 fail on the references.
-dontwarn com.google.firebase.crashlytics.**
-dontwarn com.google.firebase.remoteconfig.**
