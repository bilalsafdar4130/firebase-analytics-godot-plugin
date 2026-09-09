@tool
extends EditorPlugin
## The editor half of the addon: registers the autoload, installs the two export
## plugins, and refuses to let a broken configuration reach a build.
##
## There is deliberately no `class_name` here. That would register an
## editor-only script in the project's global class list, and an exported game
## then tries to load it against a release template that has no `EditorPlugin`
## in it. Everything with a `class_name` in this addon lives under `runtime/`
## and is safe to export.

const AUTOLOAD_NAME := "MobileServices"
const AUTOLOAD_PATH := "res://addons/mobile_services/runtime/mobile_services.gd"

const AndroidExportPlugin := preload("res://addons/mobile_services/editor/android_export_plugin.gd")
const IosExportPlugin := preload("res://addons/mobile_services/editor/ios_export_plugin.gd")

var _android: EditorExportPlugin
var _ios: EditorExportPlugin


func _enter_tree() -> void:
	# Only when it is not already there. A project that declares the autoload in
	# project.godot — this repository's demo does — would otherwise get an
	# "autoload already exists" error every time the editor loads the addon.
	if not ProjectSettings.has_setting("autoload/%s" % AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	_android = AndroidExportPlugin.new()
	add_export_plugin(_android)
	_ios = IosExportPlugin.new()
	add_export_plugin(_ios)
	_report_configuration()


func _exit_tree() -> void:
	# Deliberately NOT removing the autoload: a project may have declared it
	# itself, and disabling the addon for a moment must not silently break every
	# `MobileServices.` reference in the game's scripts.
	if _android != null:
		remove_export_plugin(_android)
		_android = null
	if _ios != null:
		remove_export_plugin(_ios)
		_ios = null


## Says what the project's configuration looks like the moment the addon is
## enabled, rather than leaving it to be discovered at export time or, worse,
## after a release.
func _report_configuration() -> void:
	var path := str(ProjectSettings.get_setting(
		MobileServicesEditorConfig.SETTING_CONFIG_PATH, MSConfig.DEFAULT_PATH
	))
	if not FileAccess.file_exists(path):
		push_warning(
			"[MobileServices] no %s yet — copy " % path
			+ "addons/mobile_services/mobile_services.cfg.template to it and edit. "
			+ "Until then every service is switched off."
		)
		return
	var config := MSConfig.load_from(path, "production")
	for problem in config.errors:
		push_error("[MobileServices] %s: %s" % [path, problem])
	for warning in config.warnings:
		push_warning("[MobileServices] %s: %s" % [path, warning])
	if config.errors.is_empty():
		print("[MobileServices] %s loaded: %s" % [path, config.summary()])
