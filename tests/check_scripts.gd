extends SceneTree
## Loads every GDScript in the project and reports the ones that do not compile.
##
##     godot --headless --script res://tests/check_scripts.gd
##
## WHY THIS IS SEPARATE FROM THE TESTS. `run_tests.gd` only compiles what it
## actually reaches: itself, its preloads, and the autoload chain. Everything
## under `examples/` and `demo/` is never touched by it — and those are the files
## a developer copies into their own game, so a parse error there is a parse
## error handed straight to someone else.
##
## It also catches what a green test run can hide. Godot logs a parse error and
## carries on, so a script can fail to compile while the process still exits 0.
## That happened on this repository's first CI run: `run_tests.gd` reported 100
## checks passing while `MSIap` had not compiled at all.

func _initialize() -> void:
	var scripts := _find_scripts("res://")
	var failed: PackedStringArray = PackedStringArray()

	for path in scripts:
		# `load()` compiles the script and everything it depends on, printing its
		# own parse error above this line. It does NOT answer null for a broken
		# GDScript — it hands back the resource with the script marked invalid,
		# which is how the first version of this file reported "0 failed" while
		# Godot had just logged a parse error two lines earlier.
		#
		# `can_instantiate()` is the flag that actually tracks validity. For
		# GDScript it reads `valid && (tool || scripting_enabled)`, and scripting
		# is enabled while a script is running — so here it means exactly
		# "this compiled", @tool scripts included.
		var script = load(path)
		if script == null or not (script is GDScript) or not script.can_instantiate():
			failed.append(path)

	print("")
	print("checked %d script(s), %d failed to compile" % [scripts.size(), failed.size()])
	for path in failed:
		print("  FAIL  %s" % path)
	quit(1 if not failed.is_empty() else 0)


## Every `.gd` file in the project, `addons/` included.
##
## `.godot/` is skipped: it holds the import cache, not source. Directories
## carrying a `.gdignore` are skipped too, because the engine itself skips them
## — `android/` does, so its Kotlin tree is not walked looking for GDScript.
func _find_scripts(root: String) -> PackedStringArray:
	var found := PackedStringArray()
	var directory := DirAccess.open(root)
	if directory == null:
		return found
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		var path := root.path_join(entry)
		if directory.current_is_dir():
			if entry != ".godot" and not entry.begins_with("."):
				if not FileAccess.file_exists(path.path_join(".gdignore")):
					found.append_array(_find_scripts(path))
		elif entry.ends_with(".gd"):
			found.append(path)
		entry = directory.get_next()
	directory.list_dir_end()
	return found
