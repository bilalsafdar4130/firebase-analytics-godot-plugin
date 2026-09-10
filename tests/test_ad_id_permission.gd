extends RefCounted
## The advertising-ID permission decision in the Android export plugin.
##
## WHY THIS IS TESTED SEPARATELY. Getting it wrong is not a bug a player sees; it
## is a Play policy rejection, or a silently zeroed advertising identifier and
## the ad revenue with it. Play's Data Safety form treats a DECLARED AD_ID
## permission as a declaration that the identifier is collected, so an ad-free
## build must take it back out — and a build that serves ads must leave it alone.
##
## AND WHY IT IS A PURE FUNCTION RATHER THAN A METHOD ON THE PLUGIN.
## `EditorExportPlugin` cannot be instantiated outside the editor —
## `ClassDB.can_instantiate()` answers false in a game runtime — so a game's own
## headless compliance check cannot construct the plugin to drive these branches.
## It gets `null`, every assertion against it errors rather than fails, and a
## check that never runs is a check that always passes. `ad_id_permission_xml()`
## takes the one bool it depends on so that both branches are reachable from any
## project, with no editor.

const AndroidExport := preload("res://addons/mobile_services/editor/android_export_plugin.gd")


func run() -> Array[MSTestCase]:
	return [
		_an_ads_build_keeps_it(),
		_an_ad_free_build_takes_it_back_out(),
		_the_two_branches_disagree(),
		_the_ad_services_tie_is_broken(),
	]


## The <property> that stops a build carrying BOTH ads and Firebase.
##
## WHY THIS IS HERE AND NOT ONLY IN A GAME. `play-services-ads` and
## `play-services-measurement-api` each declare
## `android.adservices.AD_SERVICES_CONFIG` pointing at a different xml resource.
## Neither outranks the other, so the manifest merger REFUSES the build -- not a
## warning, not a runtime surprise, a failed export. Only the app can break the
## tie, and this addon is what writes the app's manifest.
##
## It went unnoticed until SparkLogic became the first project to ship the `ads`
## and `firebase` modules together; every build before that carried one or the
## other.
func _the_ad_services_tie_is_broken() -> MSTestCase:
	var test := MSTestCase.new("the AD_SERVICES_CONFIG tie-breaker is well formed")
	var xml := AndroidExport.ad_services_config_xml()
	test.contains(xml, AndroidExport.AD_SERVICES_CONFIG_PROPERTY, "names the property")
	test.contains(
		xml,
		AndroidExport.AD_SERVICES_CONFIG_RESOURCE,
		"and keeps the ads SDK's resource, which is the superset"
	)
	test.contains(
		xml,
		'tools:replace="android:resource"',
		"with the merger's own override mechanism, or it is just a third opinion"
	)
	return test


func _an_ads_build_keeps_it() -> MSTestCase:
	var test := MSTestCase.new("a build with ads leaves the permission in place")
	var xml := AndroidExport.ad_id_permission_xml(true)
	test.check(
		not xml.contains('tools:node="remove"'),
		"nothing is removed — the ad SDK reads the advertising ID"
	)
	test.check(
		not xml.contains("<uses-permission"),
		"and no permission element is emitted at all: the ad SDK's own manifest "
		+ "declares it, and this one only ever takes it away"
	)
	return test


func _an_ad_free_build_takes_it_back_out() -> MSTestCase:
	var test := MSTestCase.new("a build without ads removes the permission")
	var xml := AndroidExport.ad_id_permission_xml(false)
	test.contains(xml, 'tools:node="remove"', "the merger is told to delete it")
	test.contains(
		xml,
		AndroidExport.AD_ID_PERMISSION,
		"and it names com.google.android.gms.permission.AD_ID"
	)
	return test


## The branches have to actually differ. A refactor that made both return the
## same string would leave every assertion above passing.
func _the_two_branches_disagree() -> MSTestCase:
	var test := MSTestCase.new("the two branches are not the same string")
	test.check(
		AndroidExport.ad_id_permission_xml(true)
			!= AndroidExport.ad_id_permission_xml(false),
		"an ads build and an ad-free build get different manifest fragments"
	)
	return test
