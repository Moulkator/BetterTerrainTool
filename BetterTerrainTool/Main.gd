# Main.gd — Better Terrain Tool loader
#
# Thin, stable entry point. All the logic lives in scripts/better_terrain_tool.gd,
# which is re-read from disk at every map load (ResourceLoader no_cache), so
# the implementation can be hot-reloaded by simply reopening a map.
#
# The implementation exposes boot()/tick()/shutdown() (NOT start()/update())
# so DD's ModManager does not mistake it for a standalone mod.

var script_class = "tool"

const META_KEY = "BetterTerrainTool.instance"
const IMPL_PATH = "scripts/better_terrain_tool.gd"

var _impl = null
var _lib_registered := false
var _lib_tries := 0
var _lib_size_slider = null
var _lib_size_spin = null


func start() -> void:
	# Free any instance left over from the previous map (same DD session).
	if Engine.has_meta(META_KEY):
		var old = Engine.get_meta(META_KEY)
		if old != null and is_instance_valid(old) and old.has_method("shutdown"):
			old.shutdown()
		Engine.remove_meta(META_KEY)

	var script = ResourceLoader.load(Global.Root + IMPL_PATH, "GDScript", true)
	if script == null:
		printerr("[BetterTerrain] Could not load " + IMPL_PATH)
		return
	_impl = script.new()
	_impl._g = Global
	_impl._root = Global.Root
	Engine.set_meta(META_KEY, _impl)
	_impl.boot()
	_register_lib()


# _Lib integration: register the mod, then declare the tool-switch shortcut so
# it shows up (editable + persisted) in Preferences -> Shortcuts. Done here in
# Main.gd because _Lib identifies the mod from the ModManager-loaded script.
# Retried from update(): _Lib may load after this mod.
func _register_lib() -> void:
	if _lib_registered:
		return
	if not Engine.has_signal("_lib_register_mod"):
		if _lib_tries == 1:
			print("[BetterTerrain] _Lib not detected (no _lib_register_mod signal).")
		return
	_lib_registered = true
	Engine.emit_signal("_lib_register_mod", self)
	var api = Global.get("API")
	if api == null and "API" in self:
		api = get("API")
	if api == null:
		printerr("[BetterTerrain] _Lib API not found on Global after registration.")
		return
	var defs = {
		"Better Terrain Tool": ["better_terrain_tool", ""],
		"BTT: Brush Size +": ["btt_size_up", ""],
		"BTT: Brush Size -": ["btt_size_down", ""],
		"BTT: Brush Rotation CW": ["btt_rot_cw", ""],
		"BTT: Brush Rotation CCW": ["btt_rot_ccw", ""],
	}
	# InputMapApi.add_actions puts the action into the Preferences -> Shortcuts
	# tree; the config builder only persists rebinds (Minor Utils does both).
	var ima = api.get("InputMapApi")
	if ima != null:
		var missing = {}
		for k in defs.keys():
			if not InputMap.has_action(defs[k][0]):
				missing[k] = defs[k]
		if not missing.empty():
			ima.add_actions(missing)
	var mca = api.get("ModConfigApi")
	if mca == null:
		printerr("[BetterTerrain] _Lib ModConfigApi not found.")
		return
	var builder = mca.create_config()
	builder.shortcuts("shortcuts", defs)
	# Mod settings page (Mods menu -> Better Terrain Tool -> settings).
	# Diagnostic prints: with some _Lib versions one of these builder calls
	# crashes -- the last step printed points at the culprit.
	print("[BTT-CFG] 1 label")
	builder.label("Library icon size (texture / brush grids)")
	print("[BTT-CFG] 2 hbox")
	builder.h_box_container().enter()
	print("[BTT-CFG] 3 slider")
	builder.h_slider("lib_icon_size", 64.0)
	print("[BTT-CFG] 4 with min/max/step")
	builder.with("min_value", 32.0)
	builder.with("max_value", 320.0)
	builder.with("step", 2.0)
	print("[BTT-CFG] 5 sizing")
	builder.rect_min_size(Vector2(260, 0))
	builder.size_flags_v(Control.SIZE_SHRINK_CENTER)
	print("[BTT-CFG] 6 connect")
	builder.connect_current("value_changed", self, "_on_lib_icon_slider")
	_lib_size_slider = builder.get_current()
	print("[BTT-CFG] 7 exit")
	builder.exit()
	print("[BTT-CFG] 7b picker location")
	builder.check_button("use_popup_picker", false, "Choose textures in a popup window (instead of the right panel's Textures tab)")
	builder.connect_current("toggled", self, "_on_popup_picker_toggled")
	builder.check_button("invert_wheel", false, "Invert Rotation and Size shortcuts (wheel = size, Alt + wheel = rotation)")
	builder.connect_current("toggled", self, "_on_invert_wheel_toggled")
	print("[BTT-CFG] 8 build")
	var agent = builder.build()
	print("[BTT-CFG] 9 built")
	_on_popup_picker_toggled(bool(agent.use_popup_picker))
	_on_invert_wheel_toggled(bool(agent.invert_wheel))
	var v = float(agent.lib_icon_size)
	# The spin box is a plain sibling added AFTER the build (not a config
	# node), synced both ways with the slider.
	_lib_size_spin = SpinBox.new()
	_lib_size_spin.min_value = 32
	_lib_size_spin.max_value = 320
	_lib_size_spin.step = 2
	_lib_size_spin.value = v
	_lib_size_spin.connect("value_changed", self, "_on_lib_icon_spin")
	if _lib_size_slider != null and is_instance_valid(_lib_size_slider) and _lib_size_slider.get_parent() != null:
		_lib_size_slider.get_parent().add_child(_lib_size_spin)
	print("[BTT-CFG] 10 spin added")
	_on_lib_icon_size_changed(v)
	print("[BetterTerrain] Shortcut + settings registered in _Lib preferences.")


func _on_popup_picker_toggled(on: bool) -> void:
	Engine.set_meta("BetterTerrainTool.use_popup_picker", bool(on))


func _on_invert_wheel_toggled(on: bool) -> void:
	Engine.set_meta("BetterTerrainTool.invert_wheel", bool(on))


func _on_lib_icon_size_changed(v: float) -> void:
	Engine.set_meta("BetterTerrainTool.lib_icon_size", float(v))


func _on_lib_icon_slider(v: float) -> void:
	if _lib_size_spin != null and is_instance_valid(_lib_size_spin) and _lib_size_spin.value != v:
		_lib_size_spin.value = v
	_on_lib_icon_size_changed(v)


func _on_lib_icon_spin(v: float) -> void:
	# Setting the slider re-emits value_changed, which updates the saved
	# config value and the spin guard above.
	if _lib_size_slider != null and is_instance_valid(_lib_size_slider) and _lib_size_slider.value != v:
		_lib_size_slider.value = v


func update(delta: float) -> void:
	if not _lib_registered and _lib_tries < 600:
		_lib_tries += 1
		if _lib_tries % 30 == 1:
			_register_lib()
	if _impl != null:
		_impl.tick(delta)


# DD calls these on the object passed to CreateModTool (= _impl), not on
# Main. They are kept here as a safety net in case a future DD version routes
# them to the script that owns the tool instead.
func on_tool_enable(tool_id) -> void:
	if _impl != null:
		_impl.on_tool_enable(tool_id)


func on_tool_disable(tool_id) -> void:
	if _impl != null:
		_impl.on_tool_disable(tool_id)


func on_content_input(event) -> void:
	if _impl != null:
		_impl.on_content_input(event)
