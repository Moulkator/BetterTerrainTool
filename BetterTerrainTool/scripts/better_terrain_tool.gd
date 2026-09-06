# better_terrain_tool.gd — Better Terrain Tool (implementation, hot-reloadable)
#
# A "Better Terrain Tool" (Terrain category, right after the Terrain brush): paint terrain textures on any
# number of transparent layers, each with its own texture, z-index, opacity,
# visibility and mask resolution. Left mouse paints, right mouse erases.
#
# Model
#   _levels[level.ID] = { "layers": [Layer, ...], "node": Node2D container }
#   Layer (Dictionary):
#     uid, name, tex (path), z, opacity, visible, res (world px per mask px),
#     mask (Image RGBA8, coverage in RED, alpha always 1), mask_tex (ImageTexture),
#     node (Polygon2D), mat (ShaderMaterial), dirty (bool), b64 (cached PNG)
#
# Rendering
#   One Polygon2D quad per layer, child of Level (z_as_relative, so its
#   z_index lines up with DD's own layer values: Terrain -500, Caves -300,
#   Floor -200, Water 0, ...). Shader: tile texture * mask.r * opacity,
#   blend_mix, default light mode -> lit like the vanilla terrain.
#
# Painting
#   Brush = small RGBA8 Image whose alpha is the per-pixel weight * flow.
#   Image.blend_rect() does the src-over blend in C++. With the mask alpha
#   pinned to 1, src-over on the colour channels is a plain lerp:
#     paint : white brush  -> mask.r = lerp(mask.r, 1, w)
#     erase : black brush  -> mask.r = lerp(mask.r, 0, w)
#   (storing coverage in alpha would not work: src-over can only raise alpha).
#   Per-frame cost = a few blend_rect + one partial texture upload.
#
# Persistence
#   Global.ModMapData["BetterTerrainTool"] (DD serializes it inside the map file):
#   { "v":1, "levels": { "<level.ID>": { "layers": [ {name, tex, z, opacity,
#     visible, res, w, h, mask:<base64 PNG>} ] } } }

const EMBED_KEY = "BetterTerrainTool"
const LEGACY_EMBED_KEY = "TerrainLayers"
const TOOL_CATEGORY = "Terrain"
const TOOL_ID = "better_terrain_tool"
const TOOL_NAME = "Better Terrain Tool"
const TOOL_POSITION = 1   # index in the Terrain category (0 = Terrain brush)
const USER_BRUSH_DIR = "user://BetterTerrainTool/brushes/"
const THUMB_CACHE_DIR = "user://BetterTerrainTool/thumbs/"   # 64x64 brush thumbnails, keyed by path + mtime
const THUMB_BUDGET_MS = 6   # per-frame budget for the deferred thumbnail builds

const CURSOR_OFF = 0
const CURSOR_CIRCLE = 1

const DEFAULT_TEX = "res://textures/terrain/terrain_grass.png"
const RES_OPTIONS = [1, 2, 4, 8, 16, 32, 64]
const RES_LABELS = ["Godlike", "Epic", "Ultra", "High", "Medium", "Low", "Potato"]
const DEFAULT_LAYER_COUNT = 4     # layers created on a fresh level (first terrain slots)
const BRUSH_BUILD_MAX_R = 64      # brushes are built at most this big (mask px) then upscaled
const DEFAULT_RES = 4
const PERSIST_DELAY = 1.5         # seconds of inactivity before re-encoding changed masks

var _g = null
var _root := ""

var _tool_panel = null
var _tool_active := false
var _record_script = null
var _op_record_script = null

# Per-level store
var _levels := {}
var _cur_level_id := -1
var _cur_level = null
var _next_uid := 1
var _map_size := Vector2.ZERO
var _resize_hooked := false          # DD's Change Map Size dialog OK button connected
var _resize_cells := Vector2.ZERO    # Left/Top cells added (negative = removed) by the pending resize

# Brush settings
var _brush_size := 128.0      # world px radius
var _brush_hardness := 0.5
var _brush_roundness := 1.0   # falloff window: 0 = square, 1 = round
# ── Draw mode (DD-style polygon drawing through WorldUI's native polyline) ──
var isDrawing := false        # DD-style name, read by the Unofficial Patch's arc_draw
var _draw_arc_segments := 16  # native curve resolution (wheel-adjustable, like ShapeTool)
var _draw_pending_end := false   # loop was closed with a curve: finish when it lands
var _draw_saved_cursor = null
var _shape_sub := 0           # 0 rectangle / 1 oval / 2 polygon
var _shape_btns := []
var _shape_sub_row: HBoxContainer = null
var _shape_dragging := false
var _shape_begin := Vector2.ZERO
var _shape_neg := false       # negative shape (right-click): removes coverage
var _stroke_lock_axis = null      # Shift axis lock: unit vector once decided
var _stroke_lock_anchor = null    # world point the locked line passes through
var _last_paint_world = null      # end of the previous stroke (shift-click lines)
var _move_dragging := false
var _move_start := Vector2.ZERO
var _move_off := Vector2.ZERO
var _brush_flow := 0.7        # slider value; per-stamp alpha = flow^2 (more room at low values)
const SIZE_MIN = 8.0
const SIZE_RANGE = 256.0      # size = SIZE_MIN * SIZE_RANGE^slider  (0.5 -> 128, 1 -> 2048)
const SIZE_MAX = 4096.0       # hard ceiling: past the slider's 2048, the spin box
                              # (or the wheel) can go up to here; beyond that the
                              # stamp images get too large to stay responsive
const STAMP_SPACING = 0.2     # distance between stamps, as a fraction of the brush radius
const MODE_ADDITIVE = 0       # every stamp adds (also within a stroke)
const MODE_PER_STROKE = 1     # within one stroke a pixel never exceeds the brush weight; new clicks add
const MODE_NON_ADDITIVE = 2   # a pixel never exceeds the brush weight, ever (max compositing)
var _stroke_mode := MODE_ADDITIVE

# Paint modes: round brush / snapped square / bucket fill
const PAINT_BRUSH = 0
const PAINT_SQUARE = 1
const PAINT_BUCKET = 2
const PAINT_DRAW = 3
const PAINT_MOVE = 4
const ACTIVE_ICON_COLOR = Color(90.0 / 255.0, 177.0 / 255.0, 254.0 / 255.0)   # DD's active toolbar icon blue
var _paint_mode := PAINT_BRUSH
var _mode_buttons := []
var _square_preview: Line2D = null
var _bucket_cursor_tex = null
var _bucket_cursor_on := false
var _bucket_opts: VBoxContainer = null
var _cb_walls: CheckBox = null
var _cb_paths: CheckBox = null
var _cb_patterns: CheckBox = null
var _region_geo = null
var _progress_script = null
var _filling := false
var _square_rows := []       # controls shown in brush + square modes (size)
const BUCKET_SUPERSAMPLE = 4
const BUCKET_REACH = -4.0    # px: shrink the fill region so it stays inside the walls
var _brush_random_rot := true
var _brush_random_ratio := false
var _brush_rot_fixed := 0.0     # degrees, used when random rotation is OFF
var _brush_ratio_fixed := 1.0   # used when random ratio is OFF
var _size_spin: SpinBox = null
var _hard_spin: SpinBox = null
var _flow_spin: SpinBox = null
var _rot_slider: HSlider = null
var _rot_spin: SpinBox = null
var _ratio_slider: HSlider = null
var _ratio_spin: SpinBox = null
var _random_icon = null
var _cs = null                 # reusable colour-settings UI module
var _brush_continuous := true   # keep stamping every CONTINUOUS_INTERVAL frames while the mouse is still
const CONTINUOUS_INTERVAL = 5
const ROT_VARIANTS = 8           # pre-built rotated copies used for per-stamp random rotation
var _frame_counter := 0
var _persist_timer := -1.0        # <0: nothing pending
var _encode_thread: Thread = null
var _encode_pending := false
var _brush_paths := []        # library: PNG paths (mod brushes/ + user://)
var _brush_idx := 0
var _brush_src: Image = null  # selected brush PNG (grayscale weights)
var _brush_src_path := ""
var _brush_img: Image = null        # RGBA8, alpha = weight * flow (paint)
var _brush_erase_img: Image = null  # RGBA8, alpha = weight * flow (erase)
var _brush_rot := 0.0         # rotation of the current stamp (also used by the preview)
var _brush_variants := {}     # key -> Array of [paint, erase, rot]
var _preview: Sprite = null
var _input_listener: Node = null
var _preview_key := ""

# Stroke state
var _painting := false
var _erasing := false
var _stroke_before: Image = null
var _stroke_accum: Image = null   # non-additive: max weight reached per pixel this stroke
var _stroke_layer_uid := -1
var _stroke_first_stamp := false
var _preview_rot := 0.0   # rotation/ratio shown by the preview; the NEXT stroke's first stamp uses them
var _preview_ratio := 1.0
var _last_paint_pos := Vector2(INF, INF)

# UI
var _layer_rows: VBoxContainer = null
var _layer_scroll: ScrollContainer = null
var _scroll_to_sel := 0
var _clip_menu: PopupMenu = null
var _clip_menu_uid := -1
var _clip_icon_layer = null
var _clip_icon_all = null
var _clip_icon_single = null
var _clip_icon_above = null
var _clip_mat: ShaderMaterial = null
var _clip_carve_mat: ShaderMaterial = null
var _clip_tick := 0
var _clip_pick_armed := false
var _clip_pick_btn: Button = null
var _clip_check: CheckButton = null
var _clip_box: VBoxContainer = null
var _clip_mode_opt: OptionButton = null
var _scroll_last_sel := -1
var _scroll_restore := 0
var _scroll_restore_v := 0   # frames left before scrolling the list to the selected row
var _widen_frames := 5    # frames before widening the tool panel (layout must settle)
var _mu_done := false     # Minor Utils integration
var _mu_tries := 400      # checked every 15 frames while the editor settles
var _left_min_w := 0.0
var _right_min_w := 0.0
var _panel_w_left := 0.0   # user widths (0 = default), persisted
var _panel_w_right := 0.0
var _left_grip: Control = null
var _left_dragging := false
const LAYER_LIST_MIN_H = 183.0
var _layer_list_h := 0.0   # library-style list (thumb + label + hide), sorted by z
var _compact_rows := false  # right-click > Compact rows: rows as tall as their text
var _layer_group: ButtonGroup = null
var _row_by_uid := {}                   # uid -> {"btn": Button, "hide": Button}
var _hide_icon = null
var _eye_icon = null
var _sel_uid := -1
var _sel_multi := []          # multi-selection (uids, always contains _sel_uid)
var _sel_anchor := -1         # fixed origin of Shift ranges (plain / Ctrl clicks move it)
var _next_group_uid := 1
var _sel_group := -1          # group selected as PAINT TARGET (its fusion mask)
var _stroke_group_guid := -1  # >= 0: the running stroke paints a group mask
var _grp_row_btn := {}        # guid -> group name Button (inline rename)
var _z_row: HBoxContainer = null
var _shader_outdated := false
var _shader_warned := false
var _rename_guid := -1        # >= 0: the inline rename targets a group
var _rename_edit: LineEdit = null
var _rename_uid := -1
var _brush_search: LineEdit = null
var _small_thumbs := {}
var _z_slider: HSlider = null
var _z_spin: SpinBox = null
var _opacity_spin: SpinBox = null
var _opacity_slider: HSlider = null
var _res_option: OptionButton = null
var _size_slider: HSlider = null
var _square_slider: HSlider = null      # square mode (left panel): size in grid cells
var _square_spin: SpinBox = null
var _square_cells := 1.0                # square side, in grid cells (DD grid or Custom Snap grid)
var _hardness_slider: HSlider = null
var _flow_slider: HSlider = null
var _round_slider: HSlider = null
var _round_spin: SpinBox = null
var _adjust_active := false      # Alt + right-drag: live hardness / roundness
var _adjust_anchor := Vector2.ZERO
var _adjust_screen := Vector2.ZERO
var _adjust_hard0 := 0.5
var _adjust_round0 := 1.0
var _adjust_last_rebuild := 0
var _prefs_dirty_at := -1
var _adjust_axis := -1        # -1 undecided / 0 horizontal (hardness) / 1 vertical (roundness)
var _adjust_src_small = null  # grid-sized copy of the brush source used while dragging
var _brush_list: ItemList = null
var _right_panel: PanelContainer = null
var _bottom_note = null
var _mode_option: OptionButton = null
var _rot_check: Button = null
var _ratio_check: Button = null
var _continuous_check: CheckButton = null
var _props_box: VBoxContainer = null
var _props_top: VBoxContainer = null
var _smooth_row: HBoxContainer = null
var _smooth_slider: HSlider = null
var _smooth_spin: SpinBox = null
var _smooth_link_btn: Button = null
var _light_check: CheckButton = null
var _light_box: VBoxContainer = null
var _light_slider: HSlider = null
var _light_spin: SpinBox = null
var _smooth_linked := false
var _blend_icons := []
var _transform_toggle: CheckButton = null
var _transform_box: VBoxContainer = null
var _transform_open := false
var _hide_vanilla := false     # map-related: vanilla terrain + Terrain tool hidden
var _hide_vanilla_check: CheckButton = null
var _color_open := false
var _ui_syncing := false

# Texture picker
var _picker_win: WindowDialog = null
var _picker_search: LineEdit = null
var _catalog_paths := []       # sorted list of terrain texture paths
var _thumb_by_path := {}
var _pack_groups := {}         # pack name -> sorted paths
var _pack_order := []          # pack names in DD order
var _pattern_paths := []       # patterns + tilesets (when "Show patterns" is on)
var _pattern_by_pack := {}     # pack name -> paths
var _show_patterns := false
var _show_patterns_check: CheckButton = null
var _show_patterns_check2: CheckButton = null
var _use_plain_check: CheckButton = null
var _tex_sort_option: OptionButton = null
var _tex_sort := 0             # 0 name, 1 colour (hue)
var _tex_tools := []           # controls hidden while "Use Plain Color" is ON
var _plain_box: VBoxContainer = null
var _plain_picker: ColorPicker = null
var _plain_settle := -1.0
var _plain_before := ""
# Old (pre-v3) color_blend indices -> new ones.
const CB_MIGRATE = [0, 2, 7, 11, 9, 17, 12, 3, 18]
const PLAIN_DEFAULTS = [
	"#1c1c1c", "#4d4d4d", "#808080", "#b3b3b3", "#e6e6e6", "#ffffff",
	"#7a4a2b", "#a5682a", "#c98b3d", "#e0b56b", "#556b2f", "#3e5f2a",
	"#6b8e23", "#98b06f", "#2f4f4f", "#3a6ea5", "#5b8bb0", "#8fb7c9",
	"#7b4b94", "#a35d6a", "#c1443c", "#d9822b", "#e3c443", "#204030",
]
# Picker (Terrain Slots Extended look: packs | grid, favorites, accept/cancel)
const FAV_GROUP = "Favorites"
const ALL_GROUP = "All"
var _pack_list: ItemList = null
var _picker_grid: GridContainer = null
var _picker_groups := []
var _picker_group := ""
var _picker_query := ""
var _picker_original := ""
var _picker_uid := -1
var _picker_accept_required := false
var _picker_accept_btn: Button = null
var _picker_cancel_btn: Button = null
var _fav_ctx_menu: PopupMenu = null
var _fav_set := {}
# Brush favorites / hidden (only exposed when the Unofficial Patch Favorites mod is loaded)
const BRUSH_PREFS = "user://BetterTerrainTool/brushes.json"
const LIGHT_PREFIX = "light://"
var _show_light_brushes := false
var _light_img_cache := {}
var _brush_fav := {}
var _brush_hidden := {}
var _brush_inverted := {}       # brush key -> true: sample 1 - value
var _src_inv := false           # current brush is inverted (applied at sample time)
var _brush_view := 0            # 0 All (minus hidden), 1 Favorites, 2 Hidden
var _brush_mode_btn: Button = null
var _brush_count_lbl: Label = null   # "N Favorites | M Hidden" under the brush view button
var _tex_count_lbl: Label = null     # same under the texture view button
var _brush_list_h := 0.0             # user height of the brush library (0 = fit the panel)
var _rp_scroll: ScrollContainer = null
var _rp_sb_extra := 0.0              # width added to the right panel while its scrollbar shows
var _brush_list_prev_count := -1
var _rp_tab_btns := []
var _rp_tab_row: HBoxContainer = null
var _tab_textures: VBoxContainer = null
var _tab_brushes: VBoxContainer = null
var _rp_tab := 1               # 0 Textures, 1 Brushes
var _tex_search: LineEdit = null
var _tex_mode_btn: Button = null
var _tex_list: ItemList = null
var _tex_view := 0             # 0 All (minus hidden), 1 Favorites, 2 Hidden
var _tex_hidden := {}          # texture path -> true
var _tex_ctx_menu: PopupMenu = null
var _tex_thumb_cache := {}
var _lib_icon_size := 64.0
var _lib_size_slider: HSlider = null
var _lib_size_spin: SpinBox = null
var _lib_size_row: HBoxContainer = null
const LIB_SIZE_META = "BetterTerrainTool.lib_icon_size"
const POPUP_META = "BetterTerrainTool.use_popup_picker"
var _uir_thumb_applied := 1.0
var _frame_i := 0
var _tex_avg_cache := {}       # texture path -> average Color
var _tex_color_filter = null   # Color or null (no colour filtering)
var _tex_color_tol := 0.3
var _tex_swatches := []
var _tex_custom_btn: ColorPickerButton = null
var _tex_eyedrop_btn: Button = null
var _tex_eyedrop_armed := false
var _eyedrop_cursor = null
var _tex_tol_slider: HSlider = null
const TEX_PALETTE = [
	Color("#c62828"), Color("#ef6c00"), Color("#f9d33c"), Color("#7cb342"),
	Color("#2e7031"), Color("#26a69a"), Color("#1e6bb0"), Color("#7e57c2"),
	Color("#795548"), Color("#9e9e9e"), Color("#f5f5f0"), Color("#212121"),
]
var _brush_ctx_menu: PopupMenu = null
const BRUSH_VIEW_ALL = 0
const BRUSH_VIEW_FAV = 1
const BRUSH_VIEW_HIDDEN = 2
var _tex_cache := {}
var _shader: Shader = null
var _shutdown := false


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func boot() -> void:
	Engine.set_meta("BetterTerrainTool.impl", self)   # read by arc_draw (UP)
	# no_cache = true, so the module hot-reloads like the impl itself
	_cs = ResourceLoader.load(_root + "scripts/color_settings.gd", "GDScript", true).new()
	_cs.setup(self, _root)
	_build_shader()
	_record_script = ResourceLoader.load(_root + "scripts/better_terrain_tool_record.gd", "GDScript", true)
	_op_record_script = ResourceLoader.load(_root + "scripts/better_terrain_tool_op_record.gd", "GDScript", true)
	if _record_script == null:
		printerr("[BetterTerrain] better_terrain_tool_record.gd not found — undo disabled")
	_load_brush_prefs()
	_scan_brushes()
	var rg = ResourceLoader.load(_root + "library/region_geometry.gd", "GDScript", true)
	if rg != null:
		_region_geo = rg.new()
		_region_geo._g = _g
	else:
		printerr("[BetterTerrain] Could not load library/region_geometry.gd")
	_progress_script = ResourceLoader.load(_root + "library/progress_dialog.gd", "GDScript", true)
	if _progress_script == null:
		printerr("[BetterTerrain] Could not load library/progress_dialog.gd")
	_bucket_cursor_tex = _load_icon(_root + "icons/bucket_cursor.png")
	_register_tool()
	_install_input_listener()
	print("[BetterTerrain] Ready.")


func shutdown() -> void:
	_shutdown = true
	if Engine.has_meta("BetterTerrainTool.impl"):
		Engine.remove_meta("BetterTerrainTool.impl")
	_set_bucket_cursor(false)
	if _square_preview != null and is_instance_valid(_square_preview):
		_square_preview.queue_free()
	if _encode_thread != null:
		_encode_thread.wait_to_finish()
		_encode_thread = null
	for lid in _levels.keys():
		var e = _levels[lid]
		var n = e.get("node")
		if n != null and is_instance_valid(n):
			n.queue_free()
	_levels = {}
	_resize_cells = Vector2.ZERO
	_map_size = Vector2.ZERO
	if _picker_win != null and is_instance_valid(_picker_win):
		_picker_win.queue_free()
	if _preview != null and is_instance_valid(_preview):
		_preview.queue_free()
	if _right_panel != null and is_instance_valid(_right_panel):
		_right_panel.queue_free()
	if _input_listener != null and is_instance_valid(_input_listener):
		_input_listener.queue_free()


func tick(_delta: float) -> void:
	if _shutdown or _g == null:
		return
	_clip_tick += 1
	if _clip_tick % 30 == 0:
		var entry = _cur_entry()
		if entry != null:
			for l in entry["layers"]:
				if int(l.get("clip", 0)) > 0:
					_clip_sync_sprites(entry, l)
			for g in entry.get("groups", []):
				if int(g.get("clip", 0)) > 0 and g.get("clip_vp") != null:
					_grp_clip_sync(entry, g)
	var level = _current_level()
	if level == null:
		return
	if _shader_outdated and not _shader_warned and _g.Editor != null and is_instance_valid(_g.Editor):
		_shader_warned = true
		var wd = AcceptDialog.new()
		wd.window_title = "Better Terrain Tool"
		wd.dialog_text = "shaders/terrain_layer.shader is outdated:\nlayer groups will NOT render.\n\nCopy the terrain_layer.shader file shipped\nwith this version of the mod, then restart."
		_g.Editor.add_child(wd)
		wd.popup_centered()
	_check_map_resize()
	if level != _cur_level:
		_cur_level = level
		_cur_level_id = int(level.get("ID"))
		_sel_group = -1
		_ensure_level(level)
		_refresh_layer_list()
	if _prefs_dirty_at >= 0 and OS.get_ticks_msec() - _prefs_dirty_at > 600:
		_prefs_dirty_at = -1
		_save_brush_prefs()
	if _move_dragging and _tool_active:
		var mui = _g.get("WorldUI")
		if mui != null and _selected_layer() != null:
			var msp = mui.get("SnappedPosition")
			if msp is Vector2:
				_move_off = msp - _move_start
				for l in _move_targets():
					_move_set_off(l, _move_off)
		if Input.is_action_just_pressed("ui_cancel"):
			_move_cancel()
	if _paint_mode == PAINT_DRAW and _tool_active:
		var dui = _g.get("WorldUI")
		if dui != null:
			if _shape_sub != 2:
				if _shape_dragging:
					var sp2 = dui.get("SnappedPosition")
					if sp2 is Vector2:
						dui.call("SetSelectionBox", _shape_box(_shape_end_point(sp2)))
						dui.set("IsSelectionEllipse", _shape_sub == 1)
					if Input.is_action_just_pressed("ui_cancel"):
						_draw_cancel_shape(dui)
				# DD's inverted (blue) cursor colours while removing.
				dui.set("IsActionInverted", _shape_neg)
				isDrawing = false
			else:
				if Input.is_action_just_pressed("delete"):
					dui.call("UndoPolyPoint")
				if Input.is_action_just_pressed("ui_cancel"):
					dui.call("ClearPolyline")
					dui.set("EditArcPoint", false)
					_draw_pending_end = false
				dui.set("IndicateEditArcPoint", 1 if Input.is_key_pressed(KEY_SHIFT) else 0)
				dui.set("IsActionInverted", _shape_neg)
				var dpl = dui.get("Polyline")
				isDrawing = dpl != null and dpl.size() > 0
	_gs_tick()
	if _painting:
		_paint_step()
	else:
		_tick_prebuild()
	_update_preview()
	_update_square_preview()
	_update_bucket_cursor()
	_tick_scroll_to_selected()
	_tick_plain_settle(_delta)
	_sync_header_pad()
	_clamp_layer_list_height()
	_tick_thumbs()
	_tick_right_scrollbar()
	_frame_i += 1
	if _frame_i % 90 == 0:
		var changed = false
		var k = _uir_thumb_scale()
		if abs(k - _uir_thumb_applied) > 0.01:
			_uir_thumb_applied = k
			changed = true
		var popup_mode = _use_popup_picker()
		if _rp_tab_btns.size() > 0 and is_instance_valid(_rp_tab_btns[0]) and _rp_tab_btns[0].visible == popup_mode:
			_rp_tab_btns[0].visible = not popup_mode
			if popup_mode and _rp_tab == 0 and _rp_tab_btns.size() > 1:
				_rp_tab_btns[1].pressed = true
		if Engine.has_meta(LIB_SIZE_META):
			var mv = float(Engine.get_meta(LIB_SIZE_META))
			if abs(mv - _lib_icon_size) > 0.5:
				_lib_icon_size = mv
				changed = true
			if _lib_size_row != null and is_instance_valid(_lib_size_row) and _lib_size_row.visible:
				_lib_size_row.visible = false
		if changed:
			_apply_lib_icon_size()
	_tick_left_grip()
	if not _mu_done and _mu_tries > 0:
		_mu_tries -= 1
		if _mu_tries % 15 == 0:
			_try_minor_utils()
	if _widen_frames > 0:
		_widen_frames -= 1
		if _widen_frames == 0 and _tool_panel != null and is_instance_valid(_tool_panel) and _tool_panel is Control:
			if _tool_panel.rect_size.x > 0:
				_left_min_w = max(_tool_panel.rect_min_size.x, _tool_panel.rect_size.x * 1.08)
				_tool_panel.rect_min_size.x = max(_left_min_w, _panel_w_left)
				_ensure_left_grip()
	_tick_persist(_delta)


# ── DD ModTool callbacks ──────────────────────────────────────────────────────

func on_tool_enable(_tool_id) -> void:
	_tool_active = true
	var ui_e = _g.get("WorldUI") if _g != null else null
	if ui_e != null:
		var cf = ConfigFile.new()
		var half = false
		if cf.load("user://config.ini") == OK:
			half = bool(cf.get_value("Preferences", "half_grid_snap", false))
		ui_e.set("UseHalfSnap", half)
	_set_cursor(true)
	_apply_paint_mode()
	_ensure_catalog()
	if _show_patterns:
		_ensure_pattern_catalog()
	_ensure_default_layer()
	_refresh_layer_list()
	if _rp_tab == 0:
		_populate_tex_list()


# Always have something to paint on: if the current level has no layer yet,
# create one using the vanilla terrain's first slot texture.
func _ensure_default_layer() -> void:
	var level = _current_level()
	if level == null:
		return
	var entry = _ensure_level(level)
	if not entry["layers"].empty():
		return
	var paths := []
	var terrain = level.get("Terrain")
	if terrain != null and is_instance_valid(terrain) and terrain.has_method("GetTexture"):
		for i in range(1, DEFAULT_LAYER_COUNT + 1):   # vanilla slots 2-5 (slot 1 is the base)
			var t = terrain.GetTexture(i)
			if t != null and t is Texture and t.resource_path != "" and not (t.resource_path in paths):
				paths.append(t.resource_path)
	if paths.size() < DEFAULT_LAYER_COUNT:
		# Vanilla only has 4 slots unless "expanded": complete from the catalog.
		_ensure_catalog()
		for cp in _catalog_paths:
			if paths.size() >= DEFAULT_LAYER_COUNT:
				break
			if not (cp in paths):
				paths.append(cp)
	if paths.size() < DEFAULT_LAYER_COUNT:
		for dp in ["res://textures/terrain/terrain_moss.png", "res://textures/terrain/terrain_grass.png",
				"res://textures/terrain/terrain_sandstone.png", "res://textures/terrain/terrain_rocky.png",
				"res://textures/terrain/terrain_dirt.png", "res://textures/terrain/terrain_snow.png"]:
			if paths.size() >= DEFAULT_LAYER_COUNT:
				break
			if not (dp in paths) and ResourceLoader.exists(dp):
				paths.append(dp)
	if paths.empty():
		paths.append(DEFAULT_TEX)
	print("[BetterTerrain] Default layers for level %d: %s" % [int(level.get("ID")), str(paths)])
	for i in range(paths.size()):
		var layer = _new_layer(entry, "", paths[i], -450 + i * 10, 1.0, true, DEFAULT_RES)
		if i == 0:
			_sel_uid = layer["uid"]
	_schedule_persist()
	_refresh_layer_list()


func on_tool_disable(_tool_id) -> void:
	_tool_active = false
	_draw_cancel(_g.get("WorldUI") if _g != null else null)
	_set_right_panel_visible(false)
	_set_bucket_cursor(false)
	if _square_preview != null and is_instance_valid(_square_preview):
		_square_preview.visible = false
	if _painting:
		_stroke_end()
	_set_cursor(false)


func on_content_input(event) -> void:
	# DD only routes canvas input to the active tool, so no _tool_active gate
	# here (the enable callback may not reach this object on every DD build).
	# Right click is NOT routed here by DD -> handled by our own listener.
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT and _paint_mode == PAINT_MOVE:
			_move_click(event)
			return
		if event.button_index == BUTTON_LEFT and _paint_mode == PAINT_DRAW:
			_draw_click(event)
			return
		if event.button_index == BUTTON_LEFT:
			if event.pressed:
				if _paint_mode == PAINT_BUCKET:
					print("[BetterTerrain] Bucket: left click received")
					_bucket_click(event.alt)
				elif not _painting:
					_erasing = event.alt   # Alt + left click = erase
					_stroke_begin()
			elif _painting:
				_stroke_end()
		elif (event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN) and event.pressed:
			var dir = 1 if event.button_index == BUTTON_WHEEL_UP else -1
			if _paint_mode == PAINT_DRAW:
				var dui = _g.get("WorldUI") if _g != null else null
				if dui != null and bool(dui.get("EditArcPoint")):
					_draw_arc_segments = int(clamp(_draw_arc_segments + dir, 2, 32))
					dui.set("ArcSegments", _draw_arc_segments)
				return
			if event.shift and not event.alt and not Input.is_key_pressed(KEY_Z):
				# Shift+wheel: step through the displayed textures / brushes.
				_cycle_panel_list(-dir)
				return
			var inv = Engine.has_meta("BetterTerrainTool.invert_wheel") and bool(Engine.get_meta("BetterTerrainTool.invert_wheel"))
			if event.alt != inv:   # default: Alt+wheel = size; inverted: plain wheel = size
				_size_delta(dir)
			else:
				# Wheel: rotate the brush. 10 deg steps, 5 with Z, 1 with Shift+Z.
				var step = 10.0
				if Input.is_key_pressed(KEY_Z) and not event.control:
					step = 1.0 if event.shift else 5.0
				_rot_delta(-step * dir)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.scancode == KEY_BRACKETRIGHT:
			_size_delta(1)
		elif event.scancode == KEY_BRACKETLEFT:
			_size_delta(-1)


# Select the previous / next item of the list shown in the right panel
# (Textures tab or Brushes tab), scrolling the list to it.
func _cycle_panel_list(step: int) -> void:
	var list: ItemList = _tex_list if _rp_tab == 0 else _brush_list
	if list == null or not is_instance_valid(list) or list.get_item_count() == 0:
		return
	var cur = -1
	var sel = list.get_selected_items()
	if sel.size() > 0:
		cur = int(sel[0])
	var n = list.get_item_count()
	var nxt = cur + step
	if cur < 0:
		nxt = 0 if step > 0 else n - 1
	nxt = int(clamp(nxt, 0, n - 1))
	if nxt == cur:
		return
	list.select(nxt)
	list.ensure_current_is_visible()
	if _rp_tab == 0:
		_on_tex_selected(nxt)
	else:
		_on_brush_selected(nxt)


# Masks the Move mode drags: the members AND the fusion mask of a selected
# group, otherwise the edit targets.
func _move_targets() -> Array:
	var g = _sel_grp()
	if g != null:
		_grp_runtime(g)
		var out = _grp_member_layers(g)
		out.append(g)
		return out
	return _edit_targets()


func _move_set_off(layer: Dictionary, off: Vector2) -> void:
	if layer.get("grp"):
		for gmat in _grp_member_mats(layer):
			gmat.set_shader_param("grp_move_off", off)
	else:
		layer["mat"].set_shader_param("move_off", off)


func _move_click(event) -> void:
	var ui = _g.get("WorldUI") if _g != null else null
	var layer = _selected_layer()
	if ui == null or layer == null:
		return
	var sp = ui.get("SnappedPosition")
	if not (sp is Vector2):
		return
	if event.pressed:
		_move_dragging = true
		_move_start = sp
		_move_off = Vector2.ZERO
	elif _move_dragging:
		_move_dragging = false
		for l in _move_targets():
			_move_bake(l)
		_move_off = Vector2.ZERO


# Bake the dragged offset into the mask (integer texels, C++ blit).
func _move_bake(layer: Dictionary) -> void:
	_move_set_off(layer, Vector2.ZERO)
	var res = float(layer["res"])
	var d = Vector2(round(_move_off.x / res), round(_move_off.y / res))
	if d == Vector2.ZERO:
		return
	var img: Image = layer["mask"]
	var before = img.duplicate()
	var moved = Image.new()
	moved.create(img.get_width(), img.get_height(), false, img.get_format())
	moved.blit_rect(img, Rect2(0, 0, img.get_width(), img.get_height()), d)
	layer["mask"] = moved
	_upload_mask(layer)
	_record(layer, before, moved.duplicate())
	layer["dirty"] = true
	_schedule_persist()


func _move_cancel() -> void:
	if not _move_dragging and _move_off == Vector2.ZERO:
		return
	_move_dragging = false
	_move_off = Vector2.ZERO
	for l in _move_targets():
		_move_set_off(l, Vector2.ZERO)


func _draw_cancel(ui) -> void:
	_draw_cancel_shape(ui)
	if ui != null:
		ui.call("ClearPolyline")
		ui.set("EditArcPoint", false)
		ui.set("IndicateEditArcPoint", 0)
		ui.set("IsActionInverted", false)
	if _draw_saved_cursor != null and ui != null:
		ui.set("CursorMode", _draw_saved_cursor)
		_draw_saved_cursor = null
	isDrawing = false
	_draw_pending_end = false


func _on_shape_sub_toggled(on: bool, sub: int) -> void:
	if not on:
		return
	_shape_sub = sub
	var ui = _g.get("WorldUI") if _g != null else null
	_draw_cancel_shape(ui)
	if ui != null:
		ui.call("ClearPolyline")
		ui.set("EditArcPoint", false)


func _draw_cancel_shape(ui) -> void:
	_shape_dragging = false
	_shape_neg = false
	if ui != null:
		ui.call("ClearSelectionBox")
		ui.set("IsSelectionEllipse", false)


# One click of the Shape mode (left or right button; right = negative).
# Rectangle / Ellipse drag a box like DD's ShapeTool; Polygon drives
# WorldUI's native polyline (curves included).
func _draw_click(event, neg := false) -> void:
	if _multi_selected():
		return
	var ui = _g.get("WorldUI") if _g != null else null
	var layer = _paint_target()
	if ui == null or layer == null:
		return
	if _shape_sub != 2:
		var sp0 = ui.get("SnappedPosition")
		if not (sp0 is Vector2):
			return
		if event.pressed:
			_shape_begin = sp0
			_shape_dragging = true
			_shape_neg = neg
		elif _shape_dragging:
			_shape_dragging = false
			_erasing = _shape_neg or neg
			_shape_neg = false
			ui.call("ClearSelectionBox")
			ui.set("IsSelectionEllipse", false)
			var r2 = _shape_box(_shape_end_point(sp0))
			if r2.size.x > 0.5 and r2.size.y > 0.5:
				_draw_fill_polygon(layer, _shape_points(r2))
		return
	if neg and event.pressed:
		_shape_neg = true   # any right-click while placing marks the polygon negative
	if event.doubleclick:
		FinishShape()
		return
	if not event.pressed:
		return
	_erasing = _shape_neg
	isDrawing = true
	if bool(ui.get("EditArcPoint")):
		# Second click of a curve: commit the arc point.
		ui.set("EditArcPoint", false)
		if _draw_pending_end:
			FinishShape()
	elif bool(ui.get("IsCursorPositionFirstPoint")):
		if Input.is_key_pressed(KEY_SHIFT):
			# Close the loop WITH a curve: mark, edit the arc, finish on commit.
			ui.call("MarkPolyPoint")
			ui.set("EditArcPoint", true)
			ui.set("ArcSegments", _draw_arc_segments)
			_draw_pending_end = true
		else:
			FinishShape()
	else:
		ui.call("MarkPolyPoint")
		var pl = ui.get("Polyline")
		if pl != null and pl.size() > 1 and Input.is_key_pressed(KEY_SHIFT):
			ui.set("EditArcPoint", true)
			ui.set("ArcSegments", _draw_arc_segments)


# DD-style name on purpose: the Unofficial Patch's arc_draw finalizes the
# pattern-shape family of tools by calling FinishShape() on the active tool.
func FinishShape() -> void:
	var ui = _g.get("WorldUI") if _g != null else null
	var layer = _paint_target()
	if ui == null or layer == null:
		return
	var pl = ui.get("Polyline")
	if pl == null:
		return
	var has_arc = false
	for av in pl:
		if bool(av.get("HasArcPoint")):
			has_arc = true
			break
	if pl.size() > 2 or has_arc:
		var pts := _expand_polyline(pl)
		if _draw_pending_end and pts.size() > 0:
			pts.remove(pts.size() - 1)
		_draw_pending_end = false
		ui.call("ClearPolyline")
		ui.set("EditArcPoint", false)
		isDrawing = false
		_erasing = _shape_neg
		_shape_neg = false
		if pts.size() > 2:
			_draw_fill_polygon(layer, pts)
		else:
			printerr("[BetterTerrain] Draw: not enough points to fill (", pts.size(), ")")


# Shift constrains the dragged box to a square (1:1).
func _shape_end_point(sp: Vector2) -> Vector2:
	if not Input.is_key_pressed(KEY_SHIFT):
		return sp
	var d = sp - _shape_begin
	var m = max(abs(d.x), abs(d.y))
	return _shape_begin + Vector2(m * (1 if d.x >= 0 else -1), m * (1 if d.y >= 0 else -1))


func _corners_rect(a: Vector2, b: Vector2) -> Rect2:
	var tl = Vector2(min(a.x, b.x), min(a.y, b.y))
	return Rect2(tl, (b - a).abs())


# Box of the current drag; Alt centres the shape on the starting point.
func _shape_box(endp: Vector2) -> Rect2:
	if Input.is_key_pressed(KEY_ALT):
		return _corners_rect(_shape_begin - (endp - _shape_begin), endp)
	return _corners_rect(_shape_begin, endp)


# Rectangle corners, or the oval inscribed in the box (DD's side count).
func _shape_points(box: Rect2) -> Array:
	if _shape_sub == 0:
		return [box.position, box.position + Vector2(box.size.x, 0),
			box.position + box.size, box.position + Vector2(0, box.size.y)]
	var sides = int(max(24, (box.size.x + box.size.y) / 64.0))
	if sides < 32:
		sides = sides / 2 + 16
	sides = int(round(sides * 0.24) * 4)
	var c = box.position + box.size * 0.5
	var rx = box.size.x * 0.5
	var ry = box.size.y * 0.5
	var pts := []
	for i in range(sides):
		var a = TAU * i / sides
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return pts


# GDScript port of WorldUI.GetArcPolyline: expands the Shift-curves into
# cubic beziers (kappa handles the circle approximation, like MathEx).
const CIRCLE_BEZIER_TAU = 0.5522847498

func _expand_polyline(pl) -> Array:
	var line := []
	var segs = max(2, _draw_arc_segments)
	for i in range(pl.size()):
		var av = pl[i]
		var pos: Vector2 = av.get("Position")
		if bool(av.get("HasArcPoint")) and i > 0:
			var start: Vector2 = pl[i - 1].get("Position")
			var arc: Vector2 = av.get("ArcPoint")
			var c1 = start.linear_interpolate(arc, CIRCLE_BEZIER_TAU)
			var c2 = pos.linear_interpolate(arc, CIRCLE_BEZIER_TAU)
			for j in range(segs):
				var t = (j + 0.5) / float(segs)
				var q0 = start.linear_interpolate(c1, t)
				var q1 = c1.linear_interpolate(c2, t)
				var q2 = c2.linear_interpolate(pos, t)
				var r0 = q0.linear_interpolate(q1, t)
				var r1 = q1.linear_interpolate(q2, t)
				line.append(r0.linear_interpolate(r1, t))
		line.append(pos)
	return line


# Rasterize the closed polygon into the layer mask (scanline fill, C++ row
# fills), value 1 (or 0 with Alt), with the usual undo / persist plumbing.
func _draw_fill_polygon(layer: Dictionary, pts_world: Array) -> void:
	var img: Image = layer["mask"]
	var res = float(layer["res"])
	var n = pts_world.size()
	var pts := []
	var ymin = 1e20
	var ymax = -1e20
	for p in pts_world:
		var q = p / res
		pts.append(q)
		ymin = min(ymin, q.y)
		ymax = max(ymax, q.y)
	var y0 = int(max(0, floor(ymin)))
	var y1 = int(min(img.get_height() - 1, ceil(ymax)))
	if y1 < y0:
		return
	var before = img.duplicate()
	# Godot 3 has no Image.fill_rect: spans are blitted from a prefilled
	# one-row strip instead (same C++ speed).
	var strip = Image.new()
	strip.create(img.get_width(), 1, false, Image.FORMAT_RGBA8)
	strip.fill(Color(0, 0, 0, 1) if _erasing else Color(1, 1, 1, 1))
	for y in range(y0, y1 + 1):
		var yc = y + 0.5
		var xs := []
		for i in range(n):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[(i + 1) % n]
			if (a.y > yc) != (b.y > yc):
				xs.append(a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x))
		xs.sort()
		var k = 0
		while k + 1 < xs.size():
			var xa = int(max(0, ceil(xs[k] - 0.5)))
			var xb = int(min(img.get_width() - 1, floor(xs[k + 1] - 0.5)))
			if xb >= xa:
				img.blit_rect(strip, Rect2(0, 0, xb - xa + 1, 1), Vector2(xa, y))
			k += 2
	_upload_mask(layer)
	_record(layer, before, img.duplicate())
	layer["dirty"] = true
	_schedule_persist()


func _rot_delta(deg: float) -> void:
	# Start from the orientation currently shown (the rolled one in random
	# mode), not from the last fixed value.
	var base = rad2deg(fposmod(_preview_rot, TAU)) if _brush_random_rot else _brush_rot_fixed
	var v = fposmod(base + deg, 360.0)
	_ui_syncing = true
	if _rot_slider != null and is_instance_valid(_rot_slider):
		_rot_slider.value = v
	if _rot_spin != null and is_instance_valid(_rot_spin):
		_rot_spin.value = v
	_ui_syncing = false
	_brush_rot_fixed = v
	_brush_variants = {}
	_preview_rot = deg2rad(v)
	_save_brush_prefs()


func _size_delta(dir: int) -> void:
	if _paint_mode == PAINT_SQUARE:
		_set_square_cells(_square_cells + 0.25 * dir)
	else:
		# Land on multiples of 16 (128 -> 112 -> 128 -> 144, never 120 / 136).
		var step = _size_step()
		var v = (_brush_size / step + dir)
		v = floor(v + 0.0001) if dir < 0 else ceil(v - 0.0001)
		_set_brush_size(v * step)


func _set_square_cells(v: float) -> void:
	_square_cells = clamp(stepify(v, 0.25), 0.25, 32.0)
	_ui_syncing = true
	if _square_slider != null and is_instance_valid(_square_slider):
		_square_slider.value = _square_cells
	if _square_spin != null and is_instance_valid(_square_spin):
		_square_spin.value = _square_cells
	_ui_syncing = false


func _on_square_size_changed(v: float) -> void:
	if _ui_syncing:
		return
	_set_square_cells(v)


# Grid cell (world px) the square brush is expressed in: Custom Snap's square
# grid when its custom snap is on, else DD's CellSize (256 by default).
func _square_cell_px() -> float:
	var snappy = _get_snappy_mod()
	if snappy != null and snappy.get("custom_snap_enabled") == true:
		var interval = snappy.get("snap_interval")
		if interval is Vector2 and interval.x > 0.0 and int(snappy.get("active_geometry")) == 0:
			var mult = snappy.get("snap_interval_multiplier")
			var m = float(mult) if (mult != null and typeof(mult) in [TYPE_REAL, TYPE_INT] and float(mult) > 0.0) else 1.0
			return interval.x * m * 2.0
	var wui = _g.get("WorldUI")
	if wui != null:
		var cell = wui.get("CellSize")
		if cell is Vector2 and cell.x > 0.0:
			return cell.x
	return 256.0


# Right mouse button (erase). DD does not forward it to mod tools, so a small
# listener node catches it at _input level while our tool is active.
func _install_input_listener() -> void:
	if _input_listener != null and is_instance_valid(_input_listener):
		return
	_input_listener = Node.new()
	_input_listener.name = "BetterTerrainInputListener"
	var script = GDScript.new()
	script.source_code = "extends Node\nvar handler = null\nfunc _ready():\n\tset_process_input(true)\n\tprocess_priority = -200\nfunc _input(e):\n\tif handler != null:\n\t\thandler._on_raw_input(e)\n"
	script.reload()
	_input_listener.set_script(script)
	_input_listener.handler = self
	if _g.World != null and _g.World is Node:
		_g.World.call_deferred("add_child", _input_listener)


func _on_raw_input(event) -> void:
	if _shutdown:
		return
	# Tool shortcut (bindable in Preferences -> Shortcuts through _Lib, or via
	# the Minor Utils settings row): switch to the Better Terrain Tool.
	if event is InputEventKey and event.pressed and not event.echo:
		var focus = _g.Editor.get_focus_owner() if _g.Editor != null else null
		var typing = focus != null and (focus is LineEdit or focus is TextEdit)
		if not typing:
			if InputMap.has_action(TOOL_ID) and InputMap.event_is_action(event, TOOL_ID):
				_g.Editor.Toolset.Quickswitch(TOOL_ID)
				return
			# Bindable brush shortcuts (Preferences -> Shortcuts, via _Lib).
			if _tool_active and _paint_mode != PAINT_BUCKET:
				if InputMap.has_action("btt_size_up") and InputMap.event_is_action(event, "btt_size_up"):
					_size_delta(1)
					return
				if InputMap.has_action("btt_size_down") and InputMap.event_is_action(event, "btt_size_down"):
					_size_delta(-1)
					return
				if InputMap.has_action("btt_rot_cw") and InputMap.event_is_action(event, "btt_rot_cw"):
					_rot_delta(10.0)
					return
				if InputMap.has_action("btt_rot_ccw") and InputMap.event_is_action(event, "btt_rot_ccw"):
					_rot_delta(-10.0)
					return
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed \
		and _picker_win != null and is_instance_valid(_picker_win) and _picker_win.visible:
		var uid_hit = _thumb_at(event.position)
		if uid_hit != -1:
			_picker_win.hide()
			if uid_hit != _picker_uid:
				# Switch the picker to the other slot.
				_sel_uid = uid_hit
				call_deferred("_refresh_layer_list")
				call_deferred("_sync_props")
				call_deferred("_legacy_row_thumb_pressed", uid_hit)
			if _input_listener != null and is_instance_valid(_input_listener):
				_input_listener.get_tree().set_input_as_handled()
			return
	if _adjust_active and event is InputEventMouseMotion:
		var d2 = event.position - _adjust_screen
		# The FIRST direction taken locks the axis for the whole drag:
		# horizontal = softness only, vertical = roundness only.
		if _adjust_axis < 0:
			if d2.length() < 12.0:
				return
			_adjust_axis = 0 if abs(d2.x) >= abs(d2.y) else 1
		var nh = _adjust_hard0
		var nr = _adjust_round0
		if _adjust_axis == 0:
			nh = clamp(_adjust_hard0 + d2.x / 300.0, 0.0, 1.0)
		else:
			nr = clamp(_adjust_round0 - d2.y / 300.0, 0.0, 1.0)
		_brush_hardness = nh
		_brush_roundness = nr
		_ui_syncing = true
		if _hardness_slider != null and is_instance_valid(_hardness_slider):
			_hardness_slider.value = nh
		if _hard_spin != null and is_instance_valid(_hard_spin):
			_hard_spin.value = nh
		if _round_slider != null and is_instance_valid(_round_slider):
			_round_slider.value = nr
		if _round_spin != null and is_instance_valid(_round_spin):
			_round_spin.value = nr
		_ui_syncing = false
		return
	if _adjust_active and event is InputEventMouseButton \
		and event.button_index == BUTTON_RIGHT and not event.pressed:
		_adjust_active = false
		_adjust_src_small = null
		_brush_variants = {}
		_first_variant = null
		_preview_key = ""   # force one final full-quality contour rebuild
		_save_brush_prefs()
		if _input_listener != null and is_instance_valid(_input_listener):
			_input_listener.get_tree().set_input_as_handled()
		return
	if _tool_active and _paint_mode == PAINT_DRAW \
		and event is InputEventMouseButton and event.button_index == BUTTON_RIGHT \
		and not _mouse_over_ui(event.position):
		# Right button in Shape mode = negative shape (remove coverage).
		_draw_click(event, true)
		if _input_listener != null and is_instance_valid(_input_listener):
			_input_listener.get_tree().set_input_as_handled()
		return
	if _tool_active and _paint_mode == PAINT_BRUSH and not _painting \
		and event is InputEventMouseButton and event.button_index == BUTTON_RIGHT \
		and event.pressed and event.alt and not _mouse_over_ui(event.position):
		# Alt + right-drag (Photoshop-style): H = softness, V = roundness.
		_adjust_active = true
		_adjust_axis = -1
		_adjust_screen = event.position
		_adjust_hard0 = _brush_hardness
		_adjust_round0 = _brush_roundness
		var aui = _g.get("WorldUI") if _g != null else null
		var amp = aui.get("MousePosition") if aui != null else null
		_adjust_anchor = amp if amp is Vector2 else Vector2.ZERO
		if _input_listener != null and is_instance_valid(_input_listener):
			_input_listener.get_tree().set_input_as_handled()
		return
	if _tool_active and event is InputEventKey and event.pressed and not event.echo \
		and event.control and event.scancode == KEY_G:
		var sg = _group_of(_sel_uid)
		if sg != null and not _multi_selected():
			_ungroup(int(sg["uid"]))
		else:
			_group_selection()
		if _input_listener != null and is_instance_valid(_input_listener):
			_input_listener.get_tree().set_input_as_handled()
		return
	if _tool_active and event is InputEventKey and event.pressed and not event.echo \
		and event.control and event.scancode == KEY_J:
		_duplicate_selection()
		if _input_listener != null and is_instance_valid(_input_listener):
			_input_listener.get_tree().set_input_as_handled()
		return
	if _clip_pick_armed and event is InputEventMouseButton \
		and event.button_index == BUTTON_LEFT and event.pressed \
		and not _mouse_over_ui(event.position):
		_clip_pick(event.position)
		if _input_listener != null and is_instance_valid(_input_listener):
			_input_listener.get_tree().set_input_as_handled()
		return
	if _tex_eyedrop_armed and event is InputEventMouseButton \
		and event.button_index == BUTTON_LEFT and event.pressed \
		and not _mouse_over_ui(event.position):
		_tex_eyedrop_pick(event.position)
		if _input_listener != null and is_instance_valid(_input_listener):
			_input_listener.get_tree().set_input_as_handled()
		return
	if not _tool_active:
		return
	if not (event is InputEventMouseButton) or event.button_index != BUTTON_RIGHT:
		return
	if event.pressed:
		if _painting or _mouse_over_ui(event.position):
			return
		if _paint_mode == PAINT_BUCKET:
			_bucket_click(true)
			return
		_erasing = true
		_stroke_begin()
	elif _painting and _erasing:
		_stroke_end()


# Cheap UI hit-test for the raw listener (DD's own routing already filters
# the left button for us): top toolbar, bottom bar, our tool panel, popups.
func _mouse_over_ui(pos: Vector2) -> bool:
	if pos.y < 50.0:
		return true
	if _input_listener != null and is_instance_valid(_input_listener):
		var vp = _input_listener.get_viewport()
		if vp != null and pos.y > vp.size.y - 40.0:
			return true
	if _tool_panel != null and is_instance_valid(_tool_panel) and _tool_panel is Control:
		if _tool_panel.is_visible_in_tree() and _tool_panel.get_global_rect().has_point(pos):
			return true
	# Whole left column (toolbar icons + tool panel).
	var tools_col = _g.Editor.get_node_or_null("VPartition/Panels/Tools") if _g.Editor != null else null
	if tools_col != null and tools_col is Control and tools_col.is_visible_in_tree():
		if tools_col.get_global_rect().has_point(pos):
			return true
	if _picker_win != null and is_instance_valid(_picker_win) and _picker_win.visible:
		return true
	if _right_panel != null and is_instance_valid(_right_panel) and _right_panel.visible:
		if _right_panel.get_global_rect().has_point(pos):
			return true
	return false


func _size_step() -> float:
	return max(16.0, round(_brush_size * 0.1 / 16.0) * 16.0)


# ── Level / layer model ───────────────────────────────────────────────────────

func _current_level():
	var world = _g.get("World")
	if world == null or not is_instance_valid(world):
		return null
	var level = world.call("GetCurrentLevel")
	if level == null or not is_instance_valid(level):
		return null
	return level


func _woxels() -> Vector2:
	var world = _g.get("World")
	if world == null:
		return Vector2.ZERO
	var w = world.get("WoxelDimensions")
	return w if w is Vector2 else Vector2.ZERO


func _ensure_level(level) -> Dictionary:
	var lid = int(level.get("ID"))
	if _levels.has(lid):
		var e = _levels[lid]
		if e["node"] != null and is_instance_valid(e["node"]):
			return e
	var container = Node2D.new()
	container.name = "BetterTerrainLayers"
	container.z_as_relative = true
	level.add_child(container)
	var entry := {"layers": [], "node": container, "level": level}
	if _hide_vanilla:
		call_deferred("_apply_hide_vanilla")   # cover levels created after the toggle
	var lts = level.get("Lights")
	if lts != null:
		for c in lts.get_children():
			if str(c.name).begins_with("BTT_Light_"):
				c.queue_free()
	_levels[lid] = entry
	_load_level_from_embed(lid, entry)
	return entry


func _cur_entry():
	if _cur_level_id < 0 or not _levels.has(_cur_level_id):
		return null
	return _levels[_cur_level_id]


func _cur_layers() -> Array:
	var e = _cur_entry()
	return e["layers"] if e != null else []


func _selected_layer():
	for l in _cur_layers():
		if l["uid"] == _sel_uid:
			return l
	# Group selected: anchor on the topmost member so the regular layer UI
	# keeps working (its edits reach every member through _edit_targets).
	var g = _sel_grp()
	if g != null:
		var top = null
		for m in g["members"]:
			var ml = _find_layer(_cur_level_id, int(m))
			if ml != null and (top == null or int(ml["z"]) > int(top["z"])):
				top = ml
		return top
	return null


func _selected_index() -> int:
	var layers = _cur_layers()
	for i in range(layers.size()):
		if layers[i]["uid"] == _sel_uid:
			return i
	return -1


func _layer_label(layer: Dictionary) -> String:
	var txt = "%d: %s" % [int(layer["z"]), layer["name"]]
	if not layer["visible"]:
		txt += "  [hidden]"
	return txt


func _find_layer(level_id: int, uid: int):
	if not _levels.has(level_id):
		return null
	for l in _levels[level_id]["layers"]:
		if l["uid"] == uid:
			return l
	return null


func _new_layer(entry: Dictionary, name: String, tex_path: String, z: int, opacity: float, visible: bool, res: int, mask = null) -> Dictionary:
	var wx = _woxels()
	var w = max(1, int(ceil(wx.x / res)))
	var h = max(1, int(ceil(wx.y / res)))
	var img: Image
	if mask != null:
		# A stored mask of another size means the map was resized (DD may
		# rebuild the levels on resize): pad / crop with the pending shift
		# instead of stretching.
		img = _fit_mask(mask, w, h, res, _pending_shift_px() if (mask.get_width() != w or mask.get_height() != h) else Vector2.ZERO, Color(0, 0, 0, 1))
	else:
		img = Image.new()
		img.create(w, h, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 1))
	var mt = ImageTexture.new()
	mt.create_from_image(img, Texture.FLAG_FILTER)
	var layer := {
		"uid": _next_uid, "name": name, "auto_name": name == "", "tex": tex_path, "z": z,
		"opacity": opacity, "visible": visible, "res": res,
		"mask": img, "mask_tex": mt, "node": null, "mat": null,
		"dirty": true, "b64": "",
		"hue": 0.0, "saturation": 1.0, "lightness": 0.0, "gamma": 1.0, "contrast": 1.0,
		"tint_color": "#ffffff", "tint_amount": 0.0, "tex_rot": 0.0, "tex_scale": 1.0,
		"tex_off_x": 0.0, "tex_off_y": 0.0, "blend": 0, "smoothness": 1536.0, "color_blend": 0,
		"levels": {"on": false, "m": [0.0, 1.0, 1.0, 0.0, 1.0], "r": [0.0, 1.0, 1.0, 0.0, 1.0], "g": [0.0, 1.0, 1.0, 0.0, 1.0], "b": [0.0, 1.0, 1.0, 0.0, 1.0]},
		"blur_tex": null, "blur_small": null, "blur_f": 0,
		"light_paint": false, "light_intensity": 1.0, "light_node": null,
		"light_vp": null, "light_mat": null,
		"clip": 0, "clip_vp": null, "clip_z": null, "clip_obj": null,   # 0 none / 1 layer / 2 all below / 3 single object
	}
	if layer["auto_name"]:
		layer["name"] = _display_name(tex_path)
	if _blend_all_state != -1:
		layer["blend"] = _blend_all_state
	if _smooth_linked and _smooth_slider != null and is_instance_valid(_smooth_slider):
		layer["smoothness"] = float(_smooth_slider.value)
	_next_uid += 1
	_build_layer_node(entry, layer)
	entry["layers"].append(layer)
	return layer


func _build_layer_node(entry: Dictionary, layer: Dictionary) -> void:
	var wx = _woxels()
	var root = BackBufferCopy.new()
	root.name = "Layer_" + str(layer["uid"])
	root.copy_mode = BackBufferCopy.COPY_MODE_DISABLED   # enabled per colour-blend mode
	root.z_as_relative = true
	root.z_index = int(layer["z"])
	root.visible = bool(layer["visible"])
	var poly = Polygon2D.new()
	var pts = PoolVector2Array([Vector2(0, 0), Vector2(wx.x, 0), Vector2(wx.x, wx.y), Vector2(0, wx.y)])
	poly.polygon = pts
	poly.uv = pts
	var mat = ShaderMaterial.new()
	mat.shader = _shader
	var tex = _load_texture(layer["tex"])
	mat.set_shader_param("tile", tex)
	mat.set_shader_param("tile_size", tex.get_size() if tex != null else Vector2(512, 512))
	mat.set_shader_param("mask", layer["mask_tex"])
	mat.set_shader_param("map_size", wx)
	mat.set_shader_param("opacity", float(layer["opacity"]))
	poly.material = mat
	root.add_child(poly)
	entry["node"].add_child(root)
	layer["node"] = root
	layer["poly"] = poly
	layer["mat"] = mat
	_apply_color_params(layer, mat)


const COLOR_KEYS = ["hue", "saturation", "lightness", "gamma", "contrast", "tint_color", "tint_amount", "tex_rot", "tex_scale", "tex_off_x", "tex_off_y", "blend", "smoothness", "color_blend", "levels"]
const COLOR_DEFAULTS = {"hue": 0.0, "saturation": 1.0, "lightness": 0.0, "gamma": 1.0, "contrast": 1.0,
	"tint_color": "#ffffff", "tint_amount": 0.0, "tex_rot": 0.0, "tex_scale": 1.0, "tex_off_x": 0.0, "tex_off_y": 0.0, "blend": 0, "smoothness": 1536.0, "color_blend": 0,
	"levels": {"on": false, "m": [0.0, 1.0, 1.0, 0.0, 1.0], "r": [0.0, 1.0, 1.0, 0.0, 1.0], "g": [0.0, 1.0, 1.0, 0.0, 1.0], "b": [0.0, 1.0, 1.0, 0.0, 1.0]}}


# Terrain textures are rendered opaque (their alpha is translucency / height
# data); patterns and tilesets keep their alpha (fully transparent areas).
func _texture_is_opaque(path: String) -> bool:
	return not ("textures/patterns" in path or "textures/tilesets" in path)


func _apply_color_params(layer: Dictionary, mat: ShaderMaterial) -> void:
	if mat != null and mat == layer.get("mat"):
		var lm = layer.get("light_mat")
		if lm != null and is_instance_valid(lm):
			_apply_color_params(layer, lm)
			lm.set_shader_param("color_blend", 0.0)
	mat.set_shader_param("opaque", 1.0 if _texture_is_opaque(str(layer["tex"])) else 0.0)
	mat.set_shader_param("hue", float(layer["hue"]))
	mat.set_shader_param("saturation", float(layer["saturation"]))
	mat.set_shader_param("lightness", float(layer["lightness"]))
	mat.set_shader_param("gamma", float(layer["gamma"]))
	mat.set_shader_param("contrast", float(layer["contrast"]))
	var tc = Color(str(layer["tint_color"]))
	tc.a = clamp(float(layer["tint_amount"]), 0.0, 1.0)
	mat.set_shader_param("tint", tc)
	mat.set_shader_param("tex_rot", deg2rad(float(layer["tex_rot"])))
	mat.set_shader_param("tex_scale", float(layer["tex_scale"]))
	mat.set_shader_param("tex_offset", Vector2(float(layer["tex_off_x"]), float(layer["tex_off_y"])))
	mat.set_shader_param("blend_mode", float(int(layer["blend"])))
	mat.set_shader_param("color_blend", float(int(layer["color_blend"])))
	var lv = layer["levels"]
	mat.set_shader_param("lv_on", 1.0 if bool(lv.get("on", false)) else 0.0)
	var lr = lv.get("r", [0, 1, 1, 0, 1])
	var lg = lv.get("g", [0, 1, 1, 0, 1])
	var lb = lv.get("b", [0, 1, 1, 0, 1])
	var lm = lv.get("m", [0, 1, 1, 0, 1])
	mat.set_shader_param("lv_in_lo", Vector3(lr[0], lg[0], lb[0]))
	mat.set_shader_param("lv_in_hi", Vector3(lr[1], lg[1], lb[1]))
	mat.set_shader_param("lv_gamma", Vector3(lr[2], lg[2], lb[2]))
	mat.set_shader_param("lv_out_lo", Vector3(lr[3], lg[3], lb[3]))
	mat.set_shader_param("lv_out_hi", Vector3(lr[4], lg[4], lb[4]))
	mat.set_shader_param("lv_m_in_lo", float(lm[0]))
	mat.set_shader_param("lv_m_in_hi", float(lm[1]))
	mat.set_shader_param("lv_m_gamma", float(lm[2]))
	mat.set_shader_param("lv_m_out_lo", float(lm[3]))
	mat.set_shader_param("lv_m_out_hi", float(lm[4]))
	# Light Painting: internal blend 23 (multiply-brighten) + intensity gain.
	# The brush alpha must drive the energy LINEARLY, so the edge shaping of
	# the Hard / Smooth modes is bypassed while painting light.
	var lp = bool(layer.get("light_paint", false))
	if lp:
		mat.set_shader_param("color_blend", 23.0)
		mat.set_shader_param("light_gain", float(layer.get("light_intensity", 1.0)))
		mat.set_shader_param("blend_mode", 0.0)
	else:
		mat.set_shader_param("light_gain", 1.0)
	# Fresh backbuffer copy right before this layer draws, only when blending.
	var root = layer.get("node")
	if root != null and is_instance_valid(root) and root is BackBufferCopy:
		root.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT if (lp or int(layer["color_blend"]) > 0 or _grp_light_of(layer)) else BackBufferCopy.COPY_MODE_DISABLED
	var msk: Image = layer["mask"]
	if msk != null:
		mat.set_shader_param("mask_texel", Vector2(1.0 / msk.get_width(), 1.0 / msk.get_height()))
	if int(layer["blend"]) == 1:
		_blur_full_build(layer)


func _remove_layer(entry: Dictionary, idx: int) -> void:
	var layer = entry["layers"][idx]
	if layer["node"] != null and is_instance_valid(layer["node"]):
		layer["node"].queue_free()
	var ln = layer.get("light_node")
	if ln != null and is_instance_valid(ln):
		ln.queue_free()
	var lvp = layer.get("light_vp")
	if lvp != null and is_instance_valid(lvp):
		lvp.queue_free()
	var cvp = layer.get("clip_vp")
	if cvp != null and is_instance_valid(cvp):
		cvp.queue_free()
	entry["layers"].remove(idx)
	_persist()


# Clipping masks (Photoshop-style), stencilled by DD's OBJECTS: the layer
# only shows where props are drawn. Mode 1 uses the object layer at the z
# immediately above the slot ("the assets sitting on this terrain"); mode 2
# uses every object of the level. The props are re-drawn as white-alpha
# silhouettes, accumulated additively in a small GPU viewport that the shader
# samples as the clip mask. Terrain and lights are never part of the stencil.
func _clip_update(entry: Dictionary, layer: Dictionary) -> void:
	var mode = int(layer.get("clip", 0))
	var mat: ShaderMaterial = layer["mat"]
	var vp = layer.get("clip_vp")
	if mode == 0 or entry["level"].get("Objects") == null:
		if vp != null and is_instance_valid(vp):
			vp.queue_free()
		layer["clip_vp"] = null
		mat.set_shader_param("clip_on", 0.0)
		return
	var m: Image = layer["mask"]
	var map_px = Vector2(m.get_width(), m.get_height()) * float(layer["res"])
	var k = min(1.0, 4096.0 / max(map_px.x, map_px.y))
	if vp == null or not is_instance_valid(vp):
		vp = Viewport.new()
		vp.usage = Viewport.USAGE_2D
		vp.disable_3d = true
		vp.transparent_bg = false
		vp.render_target_v_flip = true
		vp.render_target_update_mode = Viewport.UPDATE_ALWAYS
		var bg = ColorRect.new()
		bg.name = "bg"
		bg.color = Color(0, 0, 0, 1)
		vp.add_child(bg)
		var pool = Node2D.new()
		pool.name = "pool"
		vp.add_child(pool)
		entry["node"].add_child(vp)
		layer["clip_vp"] = vp
		# Bilinear filtering on the stencil, otherwise the downscaled
		# viewport pixelates the clipped contours.
		vp.get_texture().flags = Texture.FLAG_FILTER
	vp.size = (map_px * k).ceil()
	vp.get_node("bg").rect_size = Vector2(4194304, 4194304)
	vp.get_node("bg").rect_position = Vector2(-2097152, -2097152)
	vp.canvas_transform = Transform2D.IDENTITY.scaled(Vector2(k, k))
	mat.set_shader_param("clip_mask", vp.get_texture())
	mat.set_shader_param("clip_texel", Vector2(1.0 / max(vp.size.x, 1.0), 1.0 / max(vp.size.y, 1.0)))
	mat.set_shader_param("clip_on", 1.0)
	_clip_sync_sprites(entry, layer)


# White-alpha silhouette material shared by every stencil sprite.
func _clip_sprite_material() -> ShaderMaterial:
	if _clip_mat == null:
		var sh = Shader.new()
		sh.code = "shader_type canvas_item;\nrender_mode blend_add;\nvoid fragment() { COLOR = vec4(texture(TEXTURE, UV).a); }\n"
		_clip_mat = ShaderMaterial.new()
		_clip_mat.shader = sh
	return _clip_mat


# Black "carve" material: erases the stencil where an object drawn ABOVE the
# clipped one sits, so the texture appears BETWEEN the two objects.
func _clip_carve_material() -> ShaderMaterial:
	if _clip_carve_mat == null:
		var sh = Shader.new()
		sh.code = "shader_type canvas_item;\nvoid fragment() { COLOR = vec4(0.0, 0.0, 0.0, texture(TEXTURE, UV).a); }\n"
		_clip_carve_mat = ShaderMaterial.new()
		_clip_carve_mat.shader = sh
	return _clip_carve_mat


# Re-sync the stencil sprites with the level's props (cheap pooled update,
# called on structural refreshes and periodically from tick()).
func _clip_sync_sprites(entry: Dictionary, layer: Dictionary) -> void:
	var vp = layer.get("clip_vp")
	if vp == null or not is_instance_valid(vp):
		return
	var objects = entry["level"].get("Objects")
	if objects == null:
		return
	var mode = int(layer.get("clip", 0))
	# Mode 1 (Same Layer): only the props whose z is EXACTLY the slot's z.
	var target_z = int(layer["z"])
	var pool: Node2D = vp.get_node("pool")
	var props := []
	for p in objects.get_children():
		if not (p is Node2D):
			continue
		if p.has_meta("preview") and bool(p.get_meta("preview")):
			continue
		props.append(p)
	# Reference object (picked with "Select Object"): DD draws same-z props in
	# tree order, so Above / Below / Single are refined by that order around
	# the reference, not only by the z value.
	var single = null
	var single_i = -1
	if layer.get("clip_obj") != null:
		for pi in range(props.size()):
			var p = props[pi]
			if p.has_meta("node_id") and str(p.get_meta("node_id")) == str(layer["clip_obj"]):
				single = p
				single_i = pi
				break
	# Mode 4 (All Objects Above): the stencil objects draw AFTER the slot, so
	# a texture clipped to them would be hidden underneath. The slot's canvas
	# item is therefore lifted just above the highest stencilled object (the
	# logical layer z is untouched).
	if mode == 4:
		var top_z = int(layer["z"])
		for p2 in props:
			if p2.z_index >= int(layer["z"]) and p2.z_index > top_z:
				top_z = p2.z_index
		_clip_node_z(layer, top_z + 1, true)
	elif mode == 3 and single != null:
		# Only the OBJECT's layer matters: render just above it, and keep the
		# slot's logical layer in sync with the object's.
		_clip_node_z(layer, single.z_index + 1, true)
		if not layer.get("grp") and int(layer["z"]) != single.z_index:
			layer["z"] = single.z_index
			_schedule_persist()
			call_deferred("_refresh_layer_list")
	else:
		_clip_node_z(layer, int(layer["z"]), false)
	var i = 0
	for pi in range(props.size()):
		var p = props[pi]
		var carve = false
		if mode == 1 and p.z_index != target_z:
			continue
		elif mode == 2:
			if single != null:
				# Below the picked object in DRAW order (itself included).
				# Same-z props drawn AFTER the reference cannot cover our
				# canvas item reliably (different parents), so they CARVE the
				# stencil instead: the texture disappears under them.
				if p.z_index == single.z_index and pi > single_i:
					carve = true
				elif p.z_index > single.z_index or (p.z_index == single.z_index and pi > single_i):
					continue
			elif p.z_index > int(layer["z"]):
				continue
		elif mode == 4:
			if single != null:
				# Above the picked object in DRAW order (itself included).
				if p.z_index < single.z_index or (p.z_index == single.z_index and pi < single_i):
					continue
			elif p.z_index < int(layer["z"]):
				continue
		elif mode == 3:
			if single == null:
				continue
			if pi == single_i:
				carve = false
			elif p.z_index > single.z_index or (p.z_index == single.z_index and pi > single_i):
				carve = true
			else:
				continue
		var src = p.get("Sprite")
		if src == null or not is_instance_valid(src) or src.texture == null:
			continue
		var spr: Sprite
		if i < pool.get_child_count():
			spr = pool.get_child(i)
		else:
			spr = Sprite.new()
			pool.add_child(spr)
		spr.material = _clip_carve_material() if carve else _clip_sprite_material()
		spr.texture = src.texture
		spr.position = p.position
		spr.rotation = p.rotation
		spr.scale = p.scale
		spr.visible = true
		i += 1
	for j in range(i, pool.get_child_count()):
		pool.get_child(j).visible = false


# Canvas z of a clipped slot. For a group quasi-layer the lift applies to
# every member (relative order preserved through the z rank); when the group
# is not lifted each member falls back to its own logical z.
func _clip_node_z(layer: Dictionary, z: int, lifted: bool) -> void:
	if not layer.get("grp"):
		var n = layer.get("node")
		if n != null and is_instance_valid(n) and n.z_index != z:
			n.z_index = z
		return
	var rank = 0
	for ml in _grp_member_layers(layer):
		var mn = ml.get("node")
		if mn != null and is_instance_valid(mn):
			mn.z_index = (z + rank) if lifted else int(ml["z"])
		rank += 1


# Group clipping stencil: same viewport machinery as the layers, sampled by
# the members through the grp_clip_* uniforms. The group's reference z is
# its topmost member's.
func _grp_clip_update(entry: Dictionary, g: Dictionary) -> void:
	_grp_runtime(g)
	var mode = int(g.get("clip", 0))
	var vp = g.get("clip_vp")
	var members = _grp_member_layers(g)
	if mode == 0 or entry["level"].get("Objects") == null or members.empty():
		if vp != null and is_instance_valid(vp):
			vp.queue_free()
		g["clip_vp"] = null
		_grp_push_params(g)
		for ml in members:
			_clip_update(entry, ml)   # members recover their own canvas z
		return
	g["z"] = int(members[members.size() - 1]["z"])
	var m: Image = g["mask"]
	var map_px = Vector2(m.get_width(), m.get_height()) * float(g["res"])
	var k = min(1.0, 4096.0 / max(map_px.x, map_px.y))
	if vp == null or not is_instance_valid(vp):
		vp = Viewport.new()
		vp.usage = Viewport.USAGE_2D
		vp.disable_3d = true
		vp.transparent_bg = false
		vp.render_target_v_flip = true
		vp.render_target_update_mode = Viewport.UPDATE_ALWAYS
		var bg = ColorRect.new()
		bg.name = "bg"
		bg.color = Color(0, 0, 0, 1)
		vp.add_child(bg)
		var pool = Node2D.new()
		pool.name = "pool"
		vp.add_child(pool)
		entry["node"].add_child(vp)
		g["clip_vp"] = vp
		vp.get_texture().flags = Texture.FLAG_FILTER
	vp.size = (map_px * k).ceil()
	vp.get_node("bg").rect_size = Vector2(4194304, 4194304)
	vp.get_node("bg").rect_position = Vector2(-2097152, -2097152)
	vp.canvas_transform = Transform2D.IDENTITY.scaled(Vector2(k, k))
	_grp_push_params(g)
	_clip_sync_sprites(entry, g)


func _grp_clip_sync(entry: Dictionary, g: Dictionary) -> void:
	var members = _grp_member_layers(g)
	if members.empty():
		return
	g["z"] = int(members[members.size() - 1]["z"])
	_clip_sync_sprites(entry, g)


func _grp_free_clip(g: Dictionary) -> void:
	var vp = g.get("clip_vp")
	if vp != null and is_instance_valid(vp):
		vp.queue_free()
	g["clip_vp"] = null


func _clip_refresh_all(entry: Dictionary) -> void:
	if entry == null:
		return
	for l in entry["layers"]:
		_clip_update(entry, l)
	# Groups last: their member lifts win over the members' own.
	for g in entry.get("groups", []):
		if int(g.get("clip", 0)) > 0:
			_grp_clip_update(entry, g)
		else:
			_grp_free_clip(g)


# Light Painting: our OWN light system, composited in the scene at the slot's
# z. The shader multiplies the backbuffer by (1 + graded texture * intensity),
# which reproduces the DD light look (saturated core, coloured fringe from the
# per-channel clipping, black linework preserved) while respecting the layer
# order: assets ABOVE the slot are not lit.
func _light_update(entry: Dictionary, layer: Dictionary) -> void:
	for k in ["light_node", "light_vp"]:
		var old = layer.get(k)
		if old != null and is_instance_valid(old):
			old.queue_free()
		layer[k] = null
	layer["light_mat"] = null
	if layer["node"] != null and is_instance_valid(layer["node"]):
		layer["node"].visible = bool(layer["visible"])
	_apply_color_params(layer, layer["mat"])
	_groups_sync_shaders(entry)


# Smoothness (world px) is per layer; one small-mask texel = smoothness / 4.


# Smooth blending samples a LIVE downscaled copy of the mask (1 texel =
# BLUR_TEXEL world px) with a 5x5 gaussian in the shader. The small copy is
# updated instantly: full builds pad the mask to a multiple of the factor so
# per-region updates sample the exact same grid.
func _blur_factor(layer: Dictionary, pre: String = "blur") -> int:
	var sm = float(layer["smoothness"])
	if pre == "gblur":
		var g = _grp_of_layer(layer)
		if g != null:
			sm = float(g.get("smoothness", 1536.0))
	var texel = max(32.0, sm * 0.25)
	return int(max(2.0, round(texel / float(layer["res"]))))


func _blur_full_build(layer: Dictionary, pre: String = "blur") -> void:
	var img: Image = layer["mask"]
	var f = _blur_factor(layer, pre)
	var sw = max(2, int(ceil(img.get_width() / float(f))))
	var sh = max(2, int(ceil(img.get_height() / float(f))))
	var padded = Image.new()
	padded.create(sw * f, sh * f, false, Image.FORMAT_RGBA8)
	padded.fill(Color(0, 0, 0, 1))
	padded.blit_rect(img, Rect2(0, 0, img.get_width(), img.get_height()), Vector2.ZERO)
	_replicate_edges(padded, img.get_width(), img.get_height())
	padded.resize(sw, sh, Image.INTERPOLATE_BILINEAR)
	layer[pre + "_small"] = padded
	layer[pre + "_f"] = f
	var t = layer.get(pre + "_tex")
	if t == null:
		t = ImageTexture.new()
		layer[pre + "_tex"] = t
	t.create_from_image(padded, Texture.FLAG_FILTER)
	var bscale = Vector2(float(img.get_width()) / float(sw * f), float(img.get_height()) / float(sh * f))
	var btexel = Vector2(1.0 / sw, 1.0 / sh)
	if pre == "gblur":
		# Member coverage blurred at the GROUP's smoothness (group Smooth edge).
		var gmat: ShaderMaterial = layer["mat"]
		gmat.set_shader_param("grp_mblur", t)
		gmat.set_shader_param("grp_mblur_scale", bscale)
		gmat.set_shader_param("grp_mblur_texel", btexel)
	elif layer.get("grp"):
		# Group quasi-layer: the blur feeds the MEMBERS' grp_* uniforms.
		layer["blur_scale_v"] = bscale
		layer["blur_texel_v"] = btexel
		for gmat in _grp_member_mats(layer):
			gmat.set_shader_param("grp_blur", t)
			gmat.set_shader_param("grp_blur_scale", bscale)
			gmat.set_shader_param("grp_blur_texel", btexel)
	else:
		var mat: ShaderMaterial = layer["mat"]
		mat.set_shader_param("mask_blur", t)
		mat.set_shader_param("blur_scale", bscale)
		mat.set_shader_param("blur_texel", btexel)


# Instant per-stamp refresh of the painted region only.
func _blur_update_region(layer: Dictionary, r: Rect2, pre: String = "blur") -> void:
	var small: Image = layer.get(pre + "_small")
	var f = int(layer.get(pre + "_f", 0))
	if small == null or f <= 0 or f != _blur_factor(layer, pre):
		_blur_full_build(layer, pre)
		return
	var img: Image = layer["mask"]
	var sw = small.get_width()
	var sh = small.get_height()
	var sx0 = int(clamp(floor(r.position.x / f), 0, sw - 1))
	var sy0 = int(clamp(floor(r.position.y / f), 0, sh - 1))
	var sx1 = int(clamp(ceil(r.end.x / f), 1, sw))
	var sy1 = int(clamp(ceil(r.end.y / f), 1, sh))
	var px0 = sx0 * f
	var py0 = sy0 * f
	# Pad the source region to a full multiple of f (edges beyond the mask
	# count as empty, matching the full build).
	var rw = (sx1 - sx0) * f
	var rh = (sy1 - sy0) * f
	var region = Image.new()
	region.create(rw, rh, false, Image.FORMAT_RGBA8)
	region.fill(Color(0, 0, 0, 1))
	var avail_w = min(rw, img.get_width() - px0)
	var avail_h = min(rh, img.get_height() - py0)
	if avail_w <= 0 or avail_h <= 0:
		return
	region.blit_rect(img.get_rect(Rect2(px0, py0, avail_w, avail_h)), Rect2(0, 0, avail_w, avail_h), Vector2.ZERO)
	_replicate_edges(region, avail_w, avail_h)
	region.resize(sx1 - sx0, sy1 - sy0, Image.INTERPOLATE_BILINEAR)
	small.blit_rect(region, Rect2(0, 0, sx1 - sx0, sy1 - sy0), Vector2(sx0, sy0))
	var t: ImageTexture = layer.get(pre + "_tex")
	if t == null:
		_blur_full_build(layer, pre)
		return
	VisualServer.texture_set_data_partial(t.get_rid(), small, sx0, sy0, sx1 - sx0, sy1 - sy0, sx0, sy0, 0, 0)


# Fill the padding on the right/bottom of `img` (beyond w_valid/h_valid) by
# replicating the last valid column/row, so downscaling near the map border
# does not average with emptiness (no fade-out of the blending at map edges).
func _replicate_edges(img: Image, w_valid: int, h_valid: int) -> void:
	var w = img.get_width()
	var h = img.get_height()
	if w_valid < w and w_valid > 0:
		var col = img.get_rect(Rect2(w_valid - 1, 0, 1, h))
		for x in range(w_valid, w):
			img.blit_rect(col, Rect2(0, 0, 1, h), Vector2(x, 0))
	if h_valid < h and h_valid > 0:
		var row_img = img.get_rect(Rect2(0, h_valid - 1, w, 1))
		for y in range(h_valid, h):
			img.blit_rect(row_img, Rect2(0, 0, w, 1), Vector2(0, y))


func _mark_blur_dirty(layer: Dictionary, rect = null) -> void:
	if int(layer["blend"]) == 1:
		if rect == null:
			_blur_full_build(layer)
		else:
			_blur_update_region(layer, rect)
	if not layer.get("grp"):
		# Member of a Smooth group: its coverage blur at the group's smoothness.
		var g = _grp_of_layer(layer)
		if g != null and int(g.get("blend", 0)) == 1:
			if rect == null:
				_blur_full_build(layer, "gblur")
			else:
				_blur_update_region(layer, rect, "gblur")


func _upload_mask(layer: Dictionary) -> void:
	layer["mask_tex"].set_data(layer["mask"])
	_mark_blur_dirty(layer)


# Upload only the touched rectangle (a full set_data of a fine mask is
# tens of MB per frame — that was the lag at high resolution).
func _upload_mask_rect(layer: Dictionary, r: Rect2) -> void:
	var img: Image = layer["mask"]
	var full = Rect2(0, 0, img.get_width(), img.get_height())
	r = r.clip(full)
	if r.size.x <= 0 or r.size.y <= 0:
		return
	VisualServer.texture_set_data_partial(layer["mask_tex"].get_rid(), img,
		int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y),
		int(r.position.x), int(r.position.y), 0, 0)
	_mark_blur_dirty(layer, r)


# ── Colour-settings module host contract ─────────────────────────────────────

func cs_target():
	var g = _sel_grp()
	if g != null:
		_grp_runtime(g)
		return g
	return _selected_layer()


func cs_edit_targets() -> Array:
	var g = _sel_grp()
	if g != null:
		_grp_runtime(g)
		return [g]
	return _edit_targets()


func cs_apply(target: Dictionary) -> void:
	if bool(target.get("grp", false)):
		_grp_push_params(target)
		return
	_apply_color_params(target, target["mat"])


func cs_preview(target) -> void:
	if target != null and not bool(target.get("grp", false)):
		_refresh_row_thumb(target)


func cs_edited(target) -> void:
	if target != null and not bool(target.get("grp", false)):
		_refresh_row_thumb(target)
	_persist()


func cs_all_targets() -> Array:
	if _sel_grp() != null:
		return []   # "apply to all" must never leak group settings into layers
	return _cur_layers()


func cs_texture(target: Dictionary):
	return _load_texture(target["tex"])


func cs_open_changed(on: bool) -> void:
	_color_open = on
	_save_brush_prefs()


# Wrappers kept so existing call sites stay unchanged.
func _apply_colors_to_image(img: Image, layer: Dictionary) -> void:
	_cs.apply_colors_to_image(img, layer, true)


func _apply_colors_to_image_no_levels(img: Image, layer: Dictionary) -> void:
	_cs.apply_colors_to_image(img, layer, false)


# ── Shader ────────────────────────────────────────────────────────────────────

func _build_shader() -> void:
	_shader = Shader.new()
	# The shader lives in its own file so it can be reused by other tools.
	var f = File.new()
	if f.open(_root + "shaders/terrain_layer.shader", File.READ) == OK:
		_shader.code = f.get_as_text()
		f.close()
		_shader_outdated = not ("BTT_GRP_V3" in _shader.code)
		if _shader_outdated:
			printerr("[BetterTerrain] shaders/terrain_layer.shader is OUTDATED. Layer groups will not render -- copy the shader file shipped with this version of the mod.")
	else:
		printerr("[BetterTerrain] shaders/terrain_layer.shader not found")


# ── Textures ──────────────────────────────────────────────────────────────────

func _load_texture(path):
	if path == null or path == "":
		path = DEFAULT_TEX
	if _tex_cache.has(path):
		return _tex_cache[path]
	if str(path).begins_with("color://"):
		var img = Image.new()
		img.create(8, 8, false, Image.FORMAT_RGBA8)
		img.fill(Color(str(path).substr(8)))
		var pt = ImageTexture.new()
		pt.create_from_image(img, Texture.FLAG_REPEAT)
		_tex_cache[path] = pt
		return pt
	var t = ResourceLoader.load(path)
	if t == null or not (t is Texture):
		var img = Image.new()
		if img.load(path) == OK:
			var it = ImageTexture.new()
			it.create_from_image(img, Texture.FLAG_REPEAT | Texture.FLAG_FILTER)
			t = it
	if t == null:
		print("[BetterTerrain] Could not load texture: ", path)
		var img2 = Image.new()
		img2.create(8, 8, false, Image.FORMAT_RGBA8)
		img2.fill(Color(1, 0, 1, 1))
		var ft = ImageTexture.new()
		ft.create_from_image(img2, Texture.FLAG_REPEAT | Texture.FLAG_FILTER)
		t = ft
	_tex_cache[path] = t
	return t


func _display_name(path) -> String:
	if path == null or path == "":
		return "(none)"
	if str(path).begins_with("color://"):
		return "Color " + str(path).substr(8)
	var n = str(path).get_file()
	var dot = n.rfind(".")
	if dot > 0:
		n = n.substr(0, dot)
	# Strip catalog words (terrain, tileset, pattern, floor, texture,
	# seamless) from both ends, with their separators, repeatedly.
	var words = ["terrain", "tileset", "pattern", "floor", "texture", "seamless"]
	var changed = true
	while changed:
		changed = false
		var low = n.to_lower()
		for w in words:
			if low.begins_with(w) and n.length() > w.length():
				var nxt = n.substr(w.length(), 1)
				if nxt == "_" or nxt == "-" or nxt == " " or nxt == ".":
					n = n.substr(w.length() + 1)
					changed = true
					break
			if low.ends_with(w) and n.length() > w.length():
				var prv = n.substr(n.length() - w.length() - 1, 1)
				if prv == "_" or prv == "-" or prv == " " or prv == ".":
					n = n.substr(0, n.length() - w.length() - 1)
					changed = true
					break
	n = n.replace("_", " ").replace("-", " ").strip_edges()
	if n == "":
		n = str(path).get_file()
	return n.capitalize()


func _ensure_catalog() -> void:
	if not _catalog_paths.empty():
		return
	var ed = _g.get("Editor")
	if ed == null:
		return
	var windows = ed.get("Windows")
	if not (windows is Dictionary):
		return
	var tw = windows.get("TerrainWindow")
	if tw == null or not is_instance_valid(tw):
		return
	var tex_menu = _find_item_list(tw, "TextureMenu")
	var pack_list = _find_item_list(tw, "PackList")
	if tex_menu == null or pack_list == null:
		return
	var prev_sel = -1
	var sel = pack_list.get_selected_items()
	if sel.size() > 0:
		prev_sel = sel[0]
	var pack_count = pack_list.get_item_count()
	var seen := {}
	_pack_groups = {}
	_pack_order = []
	for pi in range(pack_count):
		var pname = pack_list.get_item_text(pi)
		pack_list.select(pi)
		pack_list.emit_signal("item_selected", pi)
		var lookup = tex_menu.get("Lookup")
		if not (lookup is Dictionary):
			continue
		var count = tex_menu.get_item_count()
		if not _pack_groups.has(pname):
			_pack_groups[pname] = []
			_pack_order.append(pname)
		for path in lookup:
			var idx = lookup[path]
			if not (idx is int) or idx < 0 or idx >= count:
				continue
			_thumb_by_path[path] = tex_menu.get_item_icon(idx)
			seen[path] = true
			if not (path in _pack_groups[pname]):
				_pack_groups[pname].append(path)
	for g in _pack_groups.keys():
		_pack_groups[g].sort()
	if prev_sel >= 0 and prev_sel < pack_count:
		pack_list.select(prev_sel)
		pack_list.emit_signal("item_selected", prev_sel)
	_catalog_paths = seen.keys()
	_catalog_paths.sort()


func _find_item_list(node, name: String):
	var stack = [node]
	while not stack.empty():
		var n = stack.pop_back()
		if n is ItemList and name in n.name:
			return n
		for c in n.get_children():
			stack.push_back(c)
	return null


# ── Brush ─────────────────────────────────────────────────────────────────────

func _size_from_slider(v: float) -> float:
	return SIZE_MIN * pow(SIZE_RANGE, clamp(v, 0.0, 1.0))


func _slider_from_size(sz: float) -> float:
	return clamp(log(sz / SIZE_MIN) / log(SIZE_RANGE), 0.0, 1.0)


func _set_brush_size(v: float) -> void:
	_brush_size = clamp(v, SIZE_MIN, SIZE_MAX)
	_ui_syncing = true
	if _size_slider != null and is_instance_valid(_size_slider):
		_size_slider.value = _slider_from_size(_brush_size)
	if _size_spin != null and is_instance_valid(_size_spin) and int(_size_spin.value) != int(round(_brush_size)):
		_ui_syncing = true
		_size_spin.value = round(_brush_size)
		_ui_syncing = false
	_ui_syncing = false
	_set_cursor(_tool_active)


func _set_cursor(on: bool) -> void:
	var ui = _g.get("WorldUI")
	if ui == null:
		return
	# Our outline preview replaces DD's circle + yellow dot.
	ui.set("CursorMode", CURSOR_OFF)


# ── Brush library ─────────────────────────────────────────────────────────────
# Brushes are grayscale PNGs (white = full weight). Built-in ones live in the
# mod's brushes/ folder; users can drop their own PNGs in
# user://BetterTerrainTool/brushes/.

func _scan_brushes() -> void:
	_brush_paths = []
	for dir_path in [_root + "brushes/", USER_BRUSH_DIR]:
		var d = Directory.new()
		if dir_path == USER_BRUSH_DIR:
			d.make_dir_recursive(USER_BRUSH_DIR)
		if d.open(dir_path) != OK:
			continue
		d.list_dir_begin(true, true)
		var names := []
		var f = d.get_next()
		while f != "":
			if not d.current_is_dir() and f.get_extension().to_lower() in ["png", "webp", "jpg", "jpeg"]:
				names.append(f)
			f = d.get_next()
		d.list_dir_end()
		names.sort()
		for n in names:
			_brush_paths.append(dir_path + n)
	if _show_light_brushes:
		for lp in _light_texture_paths():
			_brush_paths.append(LIGHT_PREFIX + lp)
	if _brush_idx >= _brush_paths.size():
		_brush_idx = 0
	_load_brush_src()


# Grayscale weight image for a brush entry: a PNG file, or a light texture
# (LIGHT_PREFIX + path) converted on the fly (weight = alpha * luminance).
func _load_brush_image(path: String):
	if _light_img_cache.has(path):
		return _light_img_cache[path]
	var img = Image.new()
	if path.begins_with(LIGHT_PREFIX):
		var real = path.substr(LIGHT_PREFIX.length())
		var src = null
		var t = ResourceLoader.load(real)
		if t != null and t is Texture:
			src = t.get_data()
		if src == null:
			src = Image.new()
			if src.load(real) != OK:
				return null
		src = src.duplicate()
		src.convert(Image.FORMAT_RGBA8)
		if src.get_width() > 256:
			src.resize(256, 256, Image.INTERPOLATE_BILINEAR)
		img.create(src.get_width(), src.get_height(), false, Image.FORMAT_RGBA8)
		src.lock()
		img.lock()
		for y in range(src.get_height()):
			for x in range(src.get_width()):
				var c = src.get_pixel(x, y)
				var v = c.a * (0.299 * c.r + 0.587 * c.g + 0.114 * c.b)
				img.set_pixel(x, y, Color(v, v, v, 1))
		img.unlock()
		src.unlock()
		_light_img_cache[path] = img
		return img
	if img.load(path) != OK:
		# Some formats (notably webp) can fail the extension-based loader in
		# DD's custom build: fall back to decoding the raw bytes.
		var f = File.new()
		if f.open(path, File.READ) != OK:
			return null
		var buf = f.get_buffer(f.get_len())
		f.close()
		var ext = path.get_extension().to_lower()
		var err = FAILED
		if ext == "webp":
			err = img.load_webp_from_buffer(buf)
		elif ext in ["jpg", "jpeg"]:
			err = img.load_jpg_from_buffer(buf)
		elif ext == "png":
			err = img.load_png_from_buffer(buf)
		if err != OK:
			return null
	img.convert(Image.FORMAT_RGBA8)
	return img


func _load_brush_src() -> void:
	_brush_src = null
	_brush_src_path = ""
	if _brush_paths.empty():
		return
	var path = _brush_paths[_brush_idx]
	var img = _load_brush_image(path)
	if img == null:
		printerr("[BetterTerrain] Could not load brush: ", path)
		return
	_brush_src = img
	_brush_src_path = path
	_brush_src_tex = null
	_src_inv = _brush_inverted.has(_brush_key_of(path))
	_brush_variants = {}


func _brush_display_name(path: String) -> String:
	if path.begins_with(LIGHT_PREFIX):
		return "Light: " + path.get_file().get_basename().capitalize()
	var n = path.get_file().get_basename()
	# Strip a leading "NN_" ordering prefix.
	if n.length() > 3 and n[2] == "_" and n.substr(0, 2).is_valid_integer():
		n = n.substr(3)
	return n.capitalize()


# Disk cache file of a brush's neutral 64x64 thumbnail (white, weight in
# alpha, no inversion / badge). The name folds in the source's mtime so an
# edited brush is re-rendered; the md5 keeps it filesystem-safe.
func _thumb_cache_file(path: String) -> String:
	var real = path.substr(LIGHT_PREFIX.length()) if path.begins_with(LIGHT_PREFIX) else path
	var mt = File.new().get_modified_time(real)
	return THUMB_CACHE_DIR + path.md5_text() + "_" + str(mt) + ".png"


# Neutral 64x64 thumbnail image of a brush: from the disk cache when present,
# otherwise rendered from the source once (and cached). Rendering a large
# brush means decoding it fully, which is the expensive part (and what used
# to happen for EVERY brush, synchronously, each time the panel was built).
func _brush_thumb_base(path: String):
	var cf = _thumb_cache_file(path)
	var cached = Image.new()
	if File.new().file_exists(cf) and cached.load(cf) == OK and cached.get_width() == 64 and cached.get_height() == 64:
		cached.convert(Image.FORMAT_RGBA8)
		return cached
	var img = _load_brush_image(path)
	if img == null:
		return null
	if path.begins_with(LIGHT_PREFIX):
		img = img.duplicate()   # the light images are shared through _light_img_cache
	# Downscale FIRST (C++), then convert: the per-pixel work runs on at most
	# 64x64 texels whatever the source resolution.
	var iw = img.get_width()
	var ih = img.get_height()
	var mx = max(iw, ih)
	var tw = int(round(64.0 * iw / mx))
	var th = int(round(64.0 * ih / mx))
	img.resize(tw, th, Image.INTERPOLATE_BILINEAR)
	# White brush on transparent: weight -> alpha.
	img.lock()
	for y in range(th):
		for x in range(tw):
			img.set_pixel(x, y, Color(1, 1, 1, img.get_pixel(x, y).r))
	img.unlock()
	var sq = Image.new()
	sq.create(64, 64, false, Image.FORMAT_RGBA8)
	sq.blit_rect(img, Rect2(0, 0, tw, th), Vector2((64 - tw) / 2, (64 - th) / 2))
	var d = Directory.new()
	d.make_dir_recursive(THUMB_CACHE_DIR)
	sq.save_png(cf)
	return sq


func _brush_thumb(path: String, with_badge := false):
	var img = _brush_thumb_base(path)
	if img == null:
		return null
	if _brush_inverted.has(_brush_key_of(path)):
		# Inversion is applied on the 64x64 thumbnail (cheap), never baked
		# into the disk cache.
		img = img.duplicate()
		img.lock()
		for y in range(64):
			for x in range(64):
				var c = img.get_pixel(x, y)
				img.set_pixel(x, y, Color(1, 1, 1, 1.0 - c.a))
		img.unlock()
	elif with_badge:
		img = img.duplicate()
	if with_badge:
		# Favorite badge (fav1.png) composited top-right, like the Favorites mod.
		var badge = _fav_badge_image(_fav_badge_size())
		if badge != null:
			img.blend_rect(badge, Rect2(0, 0, badge.get_width(), badge.get_height()), Vector2(64 - badge.get_width() - 2, 2))
	var t = ImageTexture.new()
	t.create_from_image(img, Texture.FLAG_FILTER)
	return t


func _flow_alpha() -> float:
	return clamp(_brush_flow * _brush_flow, 0.004, 1.0)


# While idle, pre-build one rotation variant per frame so the first stamps of
# a stroke never have to build brushes (that was the lag at click).
func _tick_prebuild() -> void:
	if not _tool_active:
		return
	var layer = _paint_target()
	if layer == null:
		return
	var res = int(layer["res"])
	var key = _brush_cache_key(res)
	if not _brush_variants.has(key):
		_brush_variants = {}
		_brush_variants[key] = []
	var variants: Array = _brush_variants[key]
	var wanted = ROT_VARIANTS if (_brush_random_rot or _brush_random_ratio) else 1
	if _adjust_active:
		return   # sliders are flying: build nothing until the drag ends
	if _bvp_job != null:
		_brush_gpu_finish()
		return
	# The first stamp of a stroke must match what the preview shows: keep a
	# GPU-built copy of exactly that rotation / ratio ready.
	if _first_variant == null or _first_key != key \
		or abs(float(_first_variant[2]) - _preview_rot) > 0.0001 \
		or abs(float(_first_variant[4]) - _preview_ratio) > 0.0001:
		_brush_gpu_start(key, -1, res, _preview_rot, _preview_ratio)
		return
	# Upgrade a low-res CPU placeholder first (same rotation / ratio).
	for i in range(variants.size()):
		if variants[i].size() > 3 and bool(variants[i][3]):
			_brush_gpu_start(key, i, res, float(variants[i][2]), float(variants[i][4]))
			return
	if variants.size() >= wanted:
		return
	var rot = randf() * TAU if _brush_random_rot else deg2rad(_brush_rot_fixed)
	_brush_gpu_start(key, variants.size(), res, rot, _rand_ratio())


func _rand_ratio() -> float:
	return rand_range(0.5, 2.0) if _brush_random_ratio else _brush_ratio_fixed


func _brush_cache_key(res: int) -> String:
	return "%d|%s|%.3f|%.3f|%.4f|%.1f|%d|%d|%.1f|%.2f" % [res, _brush_src_path, _brush_hardness, _brush_roundness, _flow_alpha(), _brush_size, int(_brush_random_ratio), int(_brush_random_rot), _brush_rot_fixed, _brush_ratio_fixed]


# Select the brush images for the next stamp. With random rotation on, one of
# ROT_VARIANTS pre-built rotated copies is picked at random for EVERY stamp
# (building a rotated brush per stamp would be far too slow for big brushes).
func _pick_brush(res: int) -> void:
	var key = _brush_cache_key(res)
	if not _brush_variants.has(key):
		_brush_variants = {}   # settings changed: drop the old cache
		_brush_variants[key] = []
	var variants: Array = _brush_variants[key]
	var idx = 0
	if _brush_random_rot or _brush_random_ratio:
		idx = randi() % ROT_VARIANTS
	while variants.size() <= idx:
		var rot = randf() * TAU if _brush_random_rot else deg2rad(_brush_rot_fixed)
		variants.append(_build_brush(res, rot, _rand_ratio()))
	var v = variants[idx]
	if v.size() < 6 or int(v[5]) != res:
		# Built for another mask resolution (quality changed mid-way): rebuild.
		v = _build_brush(res, float(v[2]), float(v[4]) if v.size() > 4 else _rand_ratio())
		variants[idx] = v
	_brush_img = v[0]
	_brush_erase_img = v[1]
	_brush_rot = v[2]


# ── Brush preview (semi-transparent stamp following the mouse) ────────────────

func _ensure_preview() -> void:
	if _preview != null and is_instance_valid(_preview):
		return
	var world = _g.get("World")
	if world == null or not (world is Node):
		return
	_preview = Node2D.new()
	_preview.name = "BetterTerrainBrushPreview"
	_preview.z_as_relative = false
	_preview.z_index = 4000
	_preview.modulate = Color(1, 1, 1, 0.9)
	_preview.visible = false
	world.add_child(_preview)


func _update_preview() -> void:
	if not _tool_active or _paint_target() == null or _paint_mode != PAINT_BRUSH or _tex_eyedrop_armed or _clip_pick_armed:
		if _preview != null and is_instance_valid(_preview):
			_preview.visible = false
		return
	_ensure_preview()
	if _preview == null:
		return
	var ui = _g.get("WorldUI")
	if ui == null:
		return
	var mp = ui.get("MousePosition")
	if not (mp is Vector2):
		return
	# Hide the outline while the pointer is over a panel (keeps the UI readable).
	if not _painting:
		var vp = _preview.get_viewport()
		if vp != null and _mouse_over_ui(vp.get_mouse_position()):
			_preview.visible = false
			return
	var zoom = 1.0
	var vp2 = _preview.get_viewport()
	if vp2 != null:
		zoom = vp2.get_canvas_transform().get_scale().x
	var key = "%s|%.3f|%.3f" % [_brush_src_path, _brush_hardness, _brush_roundness]
	if key != _preview_key or _preview.get_child_count() == 0:
		var now = OS.get_ticks_msec()
		if not _adjust_active or now - _adjust_last_rebuild >= 90:
			_adjust_last_rebuild = now
			_preview_key = key
			# Coarse grid while shaping with Alt-drag (7x cheaper), full
			# quality as soon as the drag ends.
			_rebuild_preview_contours(96 if _adjust_active else PREVIEW_GRID)
	var sz = float(PREVIEW_GRID)
	var pscale = _brush_size * 2.0 / sz
	# Thin on-screen line: ~1.3 px, tapering off on small/far brushes so the
	# outline never looks chunky.
	var screen_d = _brush_size * 2.0 * zoom
	# Without antialiasing, sub-pixel widths drop pixels (dotted lines):
	# never go below ~0.9 px on screen.
	var lw_screen = min(1.1, screen_d * 0.008)
	lw_screen = max(lw_screen, 0.9)
	var lw = lw_screen / max(zoom * pscale, 0.0001)
	for ch in _preview.get_children():
		if abs(ch.width - lw) > 0.0005:
			ch.width = lw
	_preview.scale = Vector2(pscale, pscale * _preview_ratio)
	# _build_brush samples the source at R(rot)·p, i.e. the stamp is the source
	# rotated by -rot: mirror that here.
	_preview.rotation = -_preview_rot
	var psp = ui.get("SnappedPosition")
	_preview.position = psp if (psp is Vector2 and not _adjust_active) else (_adjust_anchor if _adjust_active else mp)
	_preview.visible = true


const PREVIEW_THRESHOLD = 0.5
const PREVIEW_GRID = 256
var _dash_script = null


# Runtime script of the dashed falloff-window outline drawn around the brush
# preview (same line style as the contours, but dotted).
func _dash_outline_script():
	if _dash_script != null:
		return _dash_script
	var sc = GDScript.new()
	sc.source_code = """extends Node2D
var pts := []
var width := 1.0 setget set_width
func set_width(w):
	width = w
	update()
func _draw():
	if pts.size() < 2:
		return
	var per = 0.0
	for i in range(pts.size()):
		per += pts[i].distance_to(pts[(i + 1) % pts.size()])
	var dash = clamp(width * 5.0, per / 220.0, per / 28.0)
	var gap = dash * 0.8
	var period = dash + gap
	var acc = 0.0
	for i in range(pts.size()):
		var a = pts[i]
		var b = pts[(i + 1) % pts.size()]
		var seg_len = a.distance_to(b)
		if seg_len <= 0.0001:
			continue
		var dir = (b - a) / seg_len
		var t = 0.0
		var step_floor = period * 0.01
		while t < seg_len:
			var phase = fmod(acc + t, period)
			if phase < dash:
				var run = min(dash - phase, seg_len - t)
				draw_line(a + dir * t, a + dir * (t + max(run, step_floor)), Color(1, 1, 1, 0.75), width)
				t += max(run, step_floor)
			else:
				t += max(period - phase, step_floor)
		acc += seg_len
"""
	sc.reload()
	_dash_script = sc
	return sc


# Boundary of the falloff window (rounded square, corner radius = roundness),
# scaled by the aspect box, in preview-grid coordinates.
func _window_outline_points() -> Array:
	var cr = clamp(_brush_roundness, 0.0, 1.0)
	var asp = _brush_aspect()
	var sz = float(PREVIEW_GRID)
	var c = (sz - 1) * 0.5
	var pts := []
	var b = 1.0 - cr
	# Four rounded corners (quarter arcs), clockwise from top-right.
	var corners = [Vector2(b, -b), Vector2(b, b), Vector2(-b, b), Vector2(-b, -b)]
	var start_ang = [-PI * 0.5, 0.0, PI * 0.5, PI]
	for ci in range(4):
		var cc: Vector2 = corners[ci]
		for j in range(9):
			var ang = start_ang[ci] + (j / 8.0) * PI * 0.5
			var p_ = cc + Vector2(cos(ang), sin(ang)) * cr
			var gp = Vector2(p_.x * asp.x * c, p_.y * asp.y * c)
			# At low roundness the arc points collapse: skip duplicates.
			if pts.empty() or gp.distance_to(pts[pts.size() - 1]) > 0.01:
				pts.append(gp)
	return pts


# The preview is GEOMETRY, not a bitmap: iso-contours of the weight map at the
# threshold (marching squares with linear interpolation), drawn as antialiased
# Line2D loops. Crisp at any zoom and any brush size.
func _rebuild_preview_contours(grid := PREVIEW_GRID) -> void:
	for ch in _preview.get_children():
		_preview.remove_child(ch)
		ch.queue_free()
	var dash = Node2D.new()
	dash.set_script(_dash_outline_script())
	dash.pts = _window_outline_points()
	_preview.add_child(dash)
	var upscale = float(PREVIEW_GRID) / float(grid)
	var sz = grid
	var c = (sz - 1) * 0.5
	var hard = clamp(_brush_hardness, 0.0, 0.999)
	var src: Image = _brush_src
	var nearest = false
	if _adjust_active and src != null:
		# Mip-style downscale (C++, once per drag): grid-sized source sampled
		# with NEAREST -- one get_pixel instead of four + lerps per sample.
		if _adjust_src_small == null:
			_adjust_src_small = src.duplicate()
			_adjust_src_small.resize(grid, grid, Image.INTERPOLATE_BILINEAR)
		src = _adjust_src_small
		nearest = true
	var sw = src.get_width() if src != null else 0
	var sh = src.get_height() if src != null else 0
	var wmap := PoolRealArray()
	wmap.resize(sz * sz)
	var asp = _brush_aspect()
	if src != null:
		src.lock()
	for y in range(sz):
		for x in range(sz):
			var dx = (x - c) / c / asp.x
			var dy = (y - c) / c / asp.y
			var d = _round_metric(dx, dy, clamp(_brush_roundness, 0.0, 1.0))
			var w = 0.0
			if d <= hard:
				w = 1.0
			elif d < 1.0:
				w = 1.0 - (d - hard) / (1.0 - hard)
				w = w * w * (3.0 - 2.0 * w)
				w = pow(w, 1.0 + 2.0 * (1.0 - hard))
			if w > 0.0 and src != null:
				if nearest:
					var nx = int(clamp((dx + 1.0) * 0.5 * sw, 0, sw - 1))
					var ny = int(clamp((dy + 1.0) * 0.5 * sh, 0, sh - 1))
					var nv = src.get_pixel(nx, ny).r
					w *= (1.0 - nv) if _src_inv else nv
				else:
					# Bilinear source sample (nearest gives staircase contours).
					var fx = clamp((dx + 1.0) * 0.5 * sw - 0.5, 0.0, sw - 1.001)
					var fy = clamp((dy + 1.0) * 0.5 * sh - 0.5, 0.0, sh - 1.001)
					var ix = int(fx)
					var iy = int(fy)
					var tx = fx - ix
					var ty = fy - iy
					var w00 = src.get_pixel(ix, iy).r
					var w10 = src.get_pixel(min(ix + 1, sw - 1), iy).r
					var w01 = src.get_pixel(ix, min(iy + 1, sh - 1)).r
					var w11 = src.get_pixel(min(ix + 1, sw - 1), min(iy + 1, sh - 1)).r
					var bv = lerp(lerp(w00, w10, tx), lerp(w01, w11, tx), ty)
					w *= (1.0 - bv) if _src_inv else bv
			wmap[y * sz + x] = w
	if src != null:
		src.unlock()
	for entry in _marching_squares_loops(wmap, sz, PREVIEW_THRESHOLD):
		var loop = entry[0]
		var closed = bool(entry[1])
		var line = Line2D.new()
		line.default_color = Color(1, 1, 1, 0.9)
		# Godot 3's antialiased Line2D generates garbage fins (random flashing
		# chords) on dense polylines -- keep it OFF.
		line.antialiased = false
		var pts = PoolVector2Array()
		for pnt in loop:
			pts.append(Vector2((pnt.x - c) * upscale, (pnt.y - c) * upscale))
		if closed:
			pts.append(pts[0])
		line.points = pts
		_preview.add_child(line)


# Marching squares at `iso`, returns an Array of loops (Array of Vector2 in
# grid px). Segment endpoints are hashed on edge ids so loops chain exactly.
func _marching_squares_loops(wmap: PoolRealArray, sz: int, iso: float) -> Array:
	var segs := []          # [edge_id_a, pos_a, edge_id_b, pos_b]
	var by_edge := {}       # edge_id -> [seg indices]
	for y in range(sz - 1):
		var row = y * sz
		for x in range(sz - 1):
			var v0 = wmap[row + x]
			var v1 = wmap[row + x + 1]
			var v2 = wmap[row + sz + x + 1]
			var v3 = wmap[row + sz + x]
			var m = 0
			if v0 > iso:
				m |= 1
			if v1 > iso:
				m |= 2
			if v2 > iso:
				m |= 4
			if v3 > iso:
				m |= 8
			if m == 0 or m == 15:
				continue
			var e_top = "h%d_%d" % [x, y]
			var e_right = "v%d_%d" % [x + 1, y]
			var e_bottom = "h%d_%d" % [x, y + 1]
			var e_left = "v%d_%d" % [x, y]
			var p_top = Vector2(x + _iso_t(v0, v1, iso), y)
			var p_right = Vector2(x + 1, y + _iso_t(v1, v2, iso))
			var p_bottom = Vector2(x + _iso_t(v3, v2, iso), y + 1)
			var p_left = Vector2(x, y + _iso_t(v0, v3, iso))
			var cell_segs := []
			match m:
				1:
					cell_segs = [[e_left, p_left, e_top, p_top]]
				2:
					cell_segs = [[e_top, p_top, e_right, p_right]]
				3:
					cell_segs = [[e_left, p_left, e_right, p_right]]
				4:
					cell_segs = [[e_right, p_right, e_bottom, p_bottom]]
				5:
					cell_segs = [[e_left, p_left, e_top, p_top], [e_right, p_right, e_bottom, p_bottom]]
				6:
					cell_segs = [[e_top, p_top, e_bottom, p_bottom]]
				7:
					cell_segs = [[e_left, p_left, e_bottom, p_bottom]]
				8:
					cell_segs = [[e_bottom, p_bottom, e_left, p_left]]
				9:
					cell_segs = [[e_bottom, p_bottom, e_top, p_top]]
				10:
					cell_segs = [[e_top, p_top, e_right, p_right], [e_bottom, p_bottom, e_left, p_left]]
				11:
					cell_segs = [[e_bottom, p_bottom, e_right, p_right]]
				12:
					cell_segs = [[e_right, p_right, e_left, p_left]]
				13:
					cell_segs = [[e_right, p_right, e_top, p_top]]
				14:
					cell_segs = [[e_top, p_top, e_left, p_left]]
			for sg in cell_segs:
				var idx = segs.size()
				segs.append(sg)
				for eid in [sg[0], sg[2]]:
					if not by_edge.has(eid):
						by_edge[eid] = []
					by_edge[eid].append(idx)
	# Chain segments into loops. Edges shared by anything other than exactly
	# two segments are non-manifold (ambiguous saddles): treated as breaks,
	# and a chain is only marked closed when it truly comes back to its
	# starting edge -- otherwise it stays open (no long closing chords).
	var used := {}
	var loops := []
	for i in range(segs.size()):
		if used.has(i):
			continue
		used[i] = true
		var loop := [segs[i][1], segs[i][3]]
		var start_edge = segs[i][0]
		var cur_edge = segs[i][2]
		var closed = false
		var guard = segs.size() * 2
		while guard > 0:
			guard -= 1
			if cur_edge == start_edge:
				closed = true
				break
			var users = by_edge.get(cur_edge, [])
			if users.size() != 2:
				break
			var nxt = -1
			for j in users:
				if not used.has(j):
					nxt = j
					break
			if nxt < 0:
				break
			used[nxt] = true
			if segs[nxt][0] == cur_edge:
				loop.append(segs[nxt][3])
				cur_edge = segs[nxt][2]
			else:
				loop.append(segs[nxt][1])
				cur_edge = segs[nxt][0]
		if loop.size() >= 3:
			loops.append([loop, closed])
	return loops


func _iso_t(a: float, b: float, iso: float) -> float:
	if abs(b - a) < 0.00001:
		return 0.5
	return clamp((iso - a) / (b - a), 0.0, 1.0)


# Build the brush images for the given layer resolution and rotation:
#   weight = brush PNG (rotated, nearest sample) * radial/hardness falloff.
# Returns [paint Image, erase Image, rotation].
func _build_brush(res: int, rot: float, ratio := 1.0) -> Array:
	var full_r = max(1.0, _brush_size / float(res))
	# Big brushes at fine resolution: build small, then upscale in C++.
	var r = min(full_r, float(BRUSH_BUILD_MAX_R))
	# Ratios > 1 stretch the ellipse beyond the base radius: enlarge the square.
	# Even size + pixel-centre sampling: the painted span is exactly 2r px
	# (a 256 px square brush covers one 256 px cell, no missing/extra pixel).
	# Low roundness + rotation: the rotated square's corners stick out of the
	# 2r canvas (up to sqrt(2) at 45 deg) -- grow it or they get cropped.
	var rotf = lerp(abs(cos(rot)) + abs(sin(rot)), 1.0, clamp(_brush_roundness, 0.0, 1.0))
	var sz = int(max(2, round(r * 2.0 * max(1.0, ratio) * rotf)))
	var paint = Image.new()
	paint.create(sz, sz, false, Image.FORMAT_RGBA8)
	var erase = Image.new()
	erase.create(sz, sz, false, Image.FORMAT_RGBA8)
	var c = sz * 0.5 - 0.5
	var hard = clamp(_brush_hardness, 0.0, 0.999)
	var rnd = clamp(_brush_roundness, 0.0, 1.0)
	var src: Image = _brush_src
	var sw = src.get_width() if src != null else 0
	var sh = src.get_height() if src != null else 0
	var asp = _brush_aspect()
	var cs = cos(rot)
	var sn = sin(rot)
	paint.lock()
	erase.lock()
	if src != null:
		src.lock()
	for y in range(sz):
		for x in range(sz):
			var dx = (x - c) / r
			var dy = (y - c) / r
			# Rotate, then squash one axis by the ratio (rotated ellipse).
			var u = dx * cs - dy * sn
			var v = (dx * sn + dy * cs) / ratio
			# Non-square sources keep their aspect: the ellipse is inscribed
			# in the source rect (long side = brush size).
			var ua = u / asp.x
			var va = v / asp.y
			var d = _round_metric(ua, va, rnd)
			var w = 0.0
			if d <= hard:
				w = 1.0
			elif d < 1.0:
				w = 1.0 - (d - hard) / (1.0 - hard)
				w = w * w * (3.0 - 2.0 * w)   # smoothstep
				w = pow(w, 1.0 + 2.0 * (1.0 - hard))   # much softer at low hardness
			if w > 0.0 and src != null:
				# Map [-1,1] -> source pixels (clamped).
				var sx = int(clamp((ua + 1.0) * 0.5 * sw, 0, sw - 1))
				var sy = int(clamp((va + 1.0) * 0.5 * sh, 0, sh - 1))
				var sv = src.get_pixel(sx, sy).r
				w *= (1.0 - sv) if _src_inv else sv
			var a = w * _flow_alpha()
			paint.set_pixel(x, y, Color(1, 1, 1, a))
			erase.set_pixel(x, y, Color(0, 0, 0, a))
	if src != null:
		src.unlock()
	paint.unlock()
	erase.unlock()
	if full_r > r:
		var full_sz = int(max(2, round(full_r * 2.0 * max(1.0, ratio) * rotf)))
		paint.resize(full_sz, full_sz, Image.INTERPOLATE_BILINEAR)
		erase.resize(full_sz, full_sz, Image.INTERPOLATE_BILINEAR)
	# 4th slot: true = low-res CPU placeholder, to be replaced by the GPU build;
	# 6th: the mask resolution the stamp was built for.
	return [paint, erase, rot, full_r > r, ratio, res]


# Rounded-square distance: 0 at the centre, 1 on the boundary of a unit
# square whose corners are rounded with radius = roundness (1 = circle).
func _round_metric(x: float, y: float, cr: float) -> float:
	var qx = abs(x) - (1.0 - cr)
	var qy = abs(y) - (1.0 - cr)
	var ox = max(qx, 0.0)
	var oy = max(qy, 0.0)
	return 1.0 - cr + sqrt(ox * ox + oy * oy) + min(max(qx, qy), 0.0)


func _brush_aspect() -> Vector2:
	if _brush_src == null:
		return Vector2(1, 1)
	var sw = float(_brush_src.get_width())
	var sh = float(_brush_src.get_height())
	var m = max(sw, sh)
	return Vector2(sw / m, sh / m)


# ── GPU brush builder ────────────────────────────────────────────────────────
# Big brushes were built at 129 px on the CPU then upscaled (blurry / blocky).
# The same maths now runs in a shader inside two offscreen viewports (paint /
# erase) at the real stamp size, with bilinear sampling of the source. Readback
# takes one frame, so variants start as CPU placeholders and get upgraded.
const BRUSH_GPU_MAX = 4096

var _bvp := []                # [paint_vp, erase_vp]
var _bvp_mats := []           # ShaderMaterials of the two ColorRects
var _bvp_job = null           # pending readback: {key, idx, rot, ratio, sz, full_sz}
var _brush_src_tex: ImageTexture = null
var _first_variant = null     # GPU-built stamp matching the preview's rot / ratio
var _first_key := ""

func _brush_vp_ensure() -> bool:
	if not _bvp.empty() and is_instance_valid(_bvp[0]) and is_instance_valid(_bvp[1]):
		return true
	if _g == null or _g.Editor == null:
		return false
	_bvp = []
	_bvp_mats = []
	var sh = Shader.new()
	sh.code = """shader_type canvas_item;
render_mode blend_disabled;
uniform sampler2D src;
uniform float has_src = 0.0;
uniform float rgb_val = 1.0;
uniform float rot = 0.0;
uniform float ratio = 1.0;
uniform float hard = 0.5;
uniform float flow = 1.0;
uniform float roundness = 1.0;
uniform float invert_src = 0.0;
uniform vec2 aspect = vec2(1.0, 1.0);
uniform float r = 64.0;
uniform float sz = 129.0;
void fragment() {
	float c = sz * 0.5;
	vec2 px = UV * sz;
	float dx = (px.x - c) / r;
	float dy = (px.y - c) / r;
	float cs = cos(rot);
	float sn = sin(rot);
	float u = dx * cs - dy * sn;
	float v = (dx * sn + dy * cs) / ratio;
	float ua = u / aspect.x;
	float va = v / aspect.y;
	vec2 q = abs(vec2(ua, va)) - vec2(1.0 - roundness);
	float d = 1.0 - roundness + length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
	float w = 0.0;
	if (d <= hard) {
		w = 1.0;
	} else if (d < 1.0) {
		w = 1.0 - (d - hard) / (1.0 - hard);
		w = w * w * (3.0 - 2.0 * w);
		w = pow(w, 1.0 + 2.0 * (1.0 - hard));
	}
	if (w > 0.0 && has_src > 0.5) {
		vec2 suv = clamp(vec2((ua + 1.0) * 0.5, (va + 1.0) * 0.5), vec2(0.0), vec2(1.0));
		float sr = texture(src, suv).r;
		w *= mix(sr, 1.0 - sr, invert_src);
	}
	COLOR = vec4(vec3(rgb_val), w * flow);
}
"""
	for i in range(2):
		var vp = Viewport.new()
		vp.usage = Viewport.USAGE_2D
		vp.disable_3d = true
		vp.transparent_bg = true
		vp.render_target_v_flip = true
		vp.render_target_update_mode = Viewport.UPDATE_DISABLED
		vp.size = Vector2(4, 4)
		var cr = ColorRect.new()
		cr.name = "rect"
		cr.color = Color(1, 1, 1, 1)
		var m = ShaderMaterial.new()
		m.shader = sh
		m.set_shader_param("rgb_val", 1.0 if i == 0 else 0.0)
		cr.material = m
		vp.add_child(cr)
		_g.Editor.add_child(vp)
		_bvp.append(vp)
		_bvp_mats.append(m)
	return true


func _brush_src_texture() -> ImageTexture:
	if _brush_src == null:
		return null
	if _brush_src_tex == null:
		_brush_src_tex = ImageTexture.new()
		_brush_src_tex.create_from_image(_brush_src, Texture.FLAG_FILTER | Texture.FLAG_MIPMAPS)
	return _brush_src_tex


# Start the GPU build of one variant (readback happens next frame).
func _brush_gpu_start(key: String, idx: int, res: int, rot: float, ratio: float) -> void:
	if not _brush_vp_ensure():
		return
	var full_r = max(1.0, _brush_size / float(res))
	var rotf = lerp(abs(cos(rot)) + abs(sin(rot)), 1.0, clamp(_brush_roundness, 0.0, 1.0))
	var full_sz = int(max(2, round(full_r * 2.0 * max(1.0, ratio) * rotf)))
	var sz = min(full_sz, BRUSH_GPU_MAX)
	var r = full_r * float(sz) / float(full_sz)
	var tex = _brush_src_texture()
	for i in range(2):
		var vp: Viewport = _bvp[i]
		vp.size = Vector2(sz, sz)
		vp.get_node("rect").rect_size = Vector2(sz, sz)
		var m: ShaderMaterial = _bvp_mats[i]
		if tex != null:
			m.set_shader_param("src", tex)
		m.set_shader_param("has_src", 1.0 if tex != null else 0.0)
		m.set_shader_param("rot", rot)
		m.set_shader_param("ratio", ratio)
		m.set_shader_param("hard", clamp(_brush_hardness, 0.0, 0.999))
		m.set_shader_param("roundness", clamp(_brush_roundness, 0.0, 1.0))
		m.set_shader_param("invert_src", 1.0 if _src_inv else 0.0)
		m.set_shader_param("flow", _flow_alpha())
		m.set_shader_param("aspect", _brush_aspect())
		m.set_shader_param("r", r)
		m.set_shader_param("sz", float(sz))
		vp.render_target_update_mode = Viewport.UPDATE_ONCE
	_bvp_job = {"key": key, "idx": idx, "rot": rot, "ratio": ratio, "sz": sz, "full_sz": full_sz, "first": idx < 0, "res": res}


# Read the finished build back and install it in the variant cache.
func _brush_gpu_finish() -> void:
	var job = _bvp_job
	_bvp_job = null
	if job == null or _bvp.empty():
		return
	if not _brush_variants.has(job["key"]):
		return   # settings changed meanwhile: discard
	var variants: Array = _brush_variants[job["key"]] if not bool(job.get("first", false)) else []
	var imgs := []
	for i in range(2):
		var img: Image = _bvp[i].get_texture().get_data()
		if img == null:
			return
		img.convert(Image.FORMAT_RGBA8)
		if int(job["full_sz"]) > int(job["sz"]):
			img.resize(int(job["full_sz"]), int(job["full_sz"]), Image.INTERPOLATE_BILINEAR)
		imgs.append(img)
	var v = [imgs[0], imgs[1], job["rot"], false, job["ratio"], int(job.get("res", 0))]
	if bool(job.get("first", false)):
		_first_variant = v
		_first_key = job["key"]
		return
	var idx = int(job["idx"])
	if idx < variants.size():
		variants[idx] = v
	else:
		variants.append(v)


# ── GPU stroke compositing (Per Stroke / Non-additive modes) ─────────────────
# The CPU per-pixel loops could not keep up with big brushes. A persistent
# offscreen viewport (mask resolution) accumulates the MAX brush weight of the
# stroke: each stamp is a sprite whose shader reads the viewport's own
# backbuffer and writes max(prev, brush). The layer shader previews the
# composite live; on release a second viewport composes before + accum into
# the final mask, which is read back once (undo / blur / persistence as usual).
var _gs_vp: Viewport = null          # accumulation viewport
var _gs_cvp: Viewport = null         # compose viewport
var _gs_cmat: ShaderMaterial = null
var _gs_stamp_mat: ShaderMaterial = null
var _gs_nodes := []                  # [[frame, node], ...] stamp nodes to free after render
var _gs_active := false
var _gs_finishing := false
var _gs_layer = null
var _gs_frame := 0

func _gs_ensure(w: int, h: int) -> bool:
	if _g == null or _g.Editor == null:
		return false
	if _gs_vp == null or not is_instance_valid(_gs_vp):
		_gs_vp = Viewport.new()
		_gs_vp.usage = Viewport.USAGE_2D
		_gs_vp.disable_3d = true
		_gs_vp.transparent_bg = false
		_gs_vp.render_target_v_flip = true
		_gs_vp.render_target_update_mode = Viewport.UPDATE_DISABLED
		_g.Editor.add_child(_gs_vp)
		_gs_vp.get_texture().flags = Texture.FLAG_FILTER
		var sh = Shader.new()
		sh.code = "shader_type canvas_item;\nrender_mode blend_disabled;\nvoid fragment() {\n\tfloat prev = texture(SCREEN_TEXTURE, SCREEN_UV).r;\n\tfloat a = texture(TEXTURE, UV).a;\n\tCOLOR = vec4(vec3(max(prev, a)), 1.0);\n}\n"
		_gs_stamp_mat = ShaderMaterial.new()
		_gs_stamp_mat.shader = sh
	if _gs_cvp == null or not is_instance_valid(_gs_cvp):
		_gs_cvp = Viewport.new()
		_gs_cvp.usage = Viewport.USAGE_2D
		_gs_cvp.disable_3d = true
		_gs_cvp.transparent_bg = false
		_gs_cvp.render_target_v_flip = true
		_gs_cvp.render_target_update_mode = Viewport.UPDATE_DISABLED
		var cr = ColorRect.new()
		cr.name = "rect"
		var csh = Shader.new()
		csh.code = "shader_type canvas_item;\nrender_mode blend_disabled;\nuniform sampler2D before;\nuniform sampler2D acc;\nuniform float mode = 0.0;\nuniform float erase = 0.0;\nvoid fragment() {\n\tfloat b = texture(before, UV).r;\n\tfloat a = texture(acc, UV).r;\n\tfloat v;\n\tif (erase > 0.5) { v = max(b - a, 0.0); }\n\telse if (mode < 0.5) { v = max(b, a); }\n\telse { v = mix(b, 1.0, a); }\n\tCOLOR = vec4(vec3(v), 1.0);\n}\n"
		_gs_cmat = ShaderMaterial.new()
		_gs_cmat.shader = csh
		cr.material = _gs_cmat
		_gs_cvp.add_child(cr)
		_g.Editor.add_child(_gs_cvp)
	if _gs_vp.size != Vector2(w, h):
		_gs_vp.size = Vector2(w, h)
	if _gs_cvp.size != Vector2(w, h):
		_gs_cvp.size = Vector2(w, h)
		_gs_cvp.get_node("rect").rect_size = Vector2(w, h)
	return true


func _gs_uses_gpu() -> bool:
	return _stroke_mode == MODE_PER_STROKE or _stroke_mode == MODE_NON_ADDITIVE


func _gs_begin(layer: Dictionary) -> bool:
	var m: Image = layer["mask"]
	if not _gs_ensure(m.get_width(), m.get_height()):
		return false
	_gs_active = true
	_gs_layer = layer
	# Clear once, then keep accumulating across frames. The engine clears to
	# the project's clear colour (not black), so a black rect is drawn on the
	# first frame only -- it is freed like a stamp afterwards.
	_gs_vp.render_target_clear_mode = Viewport.CLEAR_MODE_ONLY_NEXT_FRAME
	_gs_vp.render_target_update_mode = Viewport.UPDATE_ALWAYS
	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 1)
	bg.rect_position = Vector2.ZERO
	bg.rect_size = Vector2(m.get_width(), m.get_height())
	_gs_vp.add_child(bg)
	_gs_nodes.append([_gs_frame, bg])
	_gs_begin_frame = _gs_frame
	_gs_shown = false
	var mat: ShaderMaterial = layer["mat"]
	mat.set_shader_param("stroke_tex", _gs_vp.get_texture())
	mat.set_shader_param("stroke_mode", 1.0 if _stroke_mode == MODE_PER_STROKE else 0.0)
	mat.set_shader_param("stroke_erase", 1.0 if _erasing else 0.0)
	return true


# Brush paint image -> cached texture in the variant (index 5).
func _gs_brush_texture(img: Image) -> ImageTexture:
	if _gs_tex_cache.has(img):
		return _gs_tex_cache[img]
	var t = ImageTexture.new()
	t.create_from_image(img, 0)
	if _gs_tex_cache.size() > 64:
		_gs_tex_cache = {}
	_gs_tex_cache[img] = t
	return t

var _gs_tex_cache := {}

func _gs_stamp(at: Vector2) -> void:
	if not _gs_active or _gs_vp == null:
		return
	var mk: Image = _gs_layer["mask"]
	if _gs_vp.size != Vector2(mk.get_width(), mk.get_height()):
		return   # mask resized during the stroke: ignore the stamp
	var tex = _gs_brush_texture(_brush_img)
	var bw = _brush_img.get_width()
	var bh = _brush_img.get_height()
	var bbc = BackBufferCopy.new()
	bbc.copy_mode = BackBufferCopy.COPY_MODE_RECT
	bbc.rect = Rect2(at, Vector2(bw, bh))
	_gs_vp.add_child(bbc)
	var spr = Sprite.new()
	spr.texture = tex
	spr.centered = false
	spr.position = at
	spr.material = _gs_stamp_mat
	_gs_vp.add_child(spr)
	_gs_nodes.append([_gs_frame, bbc])
	_gs_nodes.append([_gs_frame, spr])


# Per frame: free the stamp nodes once the frame that drew them has rendered,
# then drive the end-of-stroke sequence (all stamps rendered -> compose ->
# readback) so every step sees the previous one's output.
var _gs_compose_frame := -1
var _gs_begin_frame := -1
var _gs_shown := false

func _gs_tick() -> void:
	_gs_frame += 1
	if _gs_active and not _gs_shown and _gs_frame > _gs_begin_frame + 1 and _gs_layer != null:
		# The accumulator's first (black) frame has rendered: safe to preview.
		_gs_layer["mat"].set_shader_param("stroke_on", 1.0)
		_gs_shown = true
	var keep := []
	for e in _gs_nodes:
		if int(e[0]) < _gs_frame - 1:
			if is_instance_valid(e[1]):
				e[1].queue_free()
		else:
			keep.append(e)
	_gs_nodes = keep
	if not _gs_finishing:
		return
	if _gs_compose_frame < 0:
		if _gs_nodes.empty():   # last stamps rendered: compose now
			_gs_vp.render_target_update_mode = Viewport.UPDATE_DISABLED
			_gs_cmat.set_shader_param("before", _gs_layer["mask_tex"])
			_gs_cmat.set_shader_param("acc", _gs_vp.get_texture())
			_gs_cmat.set_shader_param("mode", 1.0 if _gs_mode_ps else 0.0)
			_gs_cmat.set_shader_param("erase", 1.0 if _gs_erase else 0.0)
			_gs_cvp.render_target_update_mode = Viewport.UPDATE_ONCE
			_gs_compose_frame = _gs_frame
	elif _gs_frame > _gs_compose_frame:
		_gs_finalize()


var _gs_mode_ps := false
var _gs_erase := false

# Mouse released: the accumulation keeps rendering until the last stamps are
# in, then _gs_tick composes and reads the final mask back.
func _gs_end() -> void:
	if not _gs_active:
		return
	_gs_mode_ps = _stroke_mode == MODE_PER_STROKE
	_gs_erase = _erasing
	_gs_compose_frame = -1
	_gs_finishing = true
	_gs_active = false


func _gs_finalize() -> void:
	_gs_finishing = false
	var layer = _gs_layer
	_gs_layer = null
	if layer == null or _gs_cvp == null:
		return
	var img: Image = _gs_cvp.get_texture().get_data()
	if img != null:
		img.convert(Image.FORMAT_RGBA8)
		layer["mask"] = img
		_upload_mask(layer)
		if _stroke_before != null:
			_record(layer, _stroke_before, img.duplicate())
		layer["dirty"] = true
		_schedule_persist()
	_stroke_before = null
	layer["mat"].set_shader_param("stroke_on", 0.0)


# ── Stroke ────────────────────────────────────────────────────────────────────

func _stroke_begin() -> void:
	if _multi_selected():
		return   # several slots selected: painting is disabled
	var layer = _paint_target()
	if layer == null:
		return
	_painting = true
	_tool_active = true
	if _gs_finishing:
		_painting = false
		return   # previous stroke still being read back (one frame)
	if layer.get("grp"):
		# Group fusion mask: CPU pipeline only (partial mask uploads already
		# give a live preview through the members' grp_mask sampling).
		_stroke_group_guid = int(layer["uid"])
		_stroke_layer_uid = -1
	else:
		_stroke_group_guid = -1
		_stroke_layer_uid = layer["uid"]
	_stroke_before = layer["mask"].duplicate()
	_stroke_accum = null
	if _stroke_group_guid < 0 and _gs_uses_gpu() and _gs_begin(layer):
		pass
	elif _stroke_mode == MODE_PER_STROKE:
		_stroke_accum = Image.new()
		_stroke_accum.create(layer["mask"].get_width(), layer["mask"].get_height(), false, Image.FORMAT_RGBA8)
		_stroke_accum.fill(Color(0, 0, 0, 0))
	_last_paint_pos = Vector2(INF, INF)
	_stroke_lock_axis = null
	_stroke_lock_anchor = null
	# Shift held at the click: connect with a straight stamped line from the
	# end of the previous stroke (Photoshop-style shift-click).
	if Input.is_key_pressed(KEY_SHIFT) and _last_paint_world is Vector2:
		var lres = int(layer["res"])
		_last_paint_pos = _last_paint_world / float(lres)
	_frame_counter = 0
	_stroke_first_stamp = true
	_paint_step()


func _stroke_end() -> void:
	if not _painting:
		return
	_painting = false
	if _brush_random_rot:
		_preview_rot = randf() * TAU   # roll the next stroke's rotation now, so the preview shows it
	else:
		_preview_rot = deg2rad(_brush_rot_fixed)
	_preview_ratio = _rand_ratio()
	_sync_random_sliders()
	var layer = _stroke_target()
	if layer != null and _last_paint_pos.x != INF:
		_last_paint_world = _last_paint_pos * float(layer["res"])
	if _gs_active:
		_gs_end()   # record / persist happen in _gs_finalize after readback
	elif layer != null and _stroke_before != null:
		_record(layer, _stroke_before, layer["mask"].duplicate())
		layer["dirty"] = true
		_schedule_persist()
		_stroke_before = null
	_stroke_accum = null


func _paint_step() -> void:
	var layer = _stroke_target()
	if layer == null:
		_painting = false
		return
	var ui = _g.get("WorldUI")
	if ui == null:
		return
	var mp = ui.get("MousePosition")
	if not (mp is Vector2):
		return
	var res = int(layer["res"])
	var sp = ui.get("SnappedPosition")
	if sp is Vector2:
		mp = sp
	# Shift: lock the stroke to horizontal / vertical / 45 deg, decided by the
	# first movement direction (Photoshop-style).
	if Input.is_key_pressed(KEY_SHIFT):
		if _stroke_lock_anchor == null:
			_stroke_lock_anchor = mp
		if _stroke_lock_axis == null:
			var dv: Vector2 = mp - _stroke_lock_anchor
			if dv.length() >= 8.0:
				var ang = stepify(dv.angle(), PI * 0.25)
				_stroke_lock_axis = Vector2(cos(ang), sin(ang))
		if _stroke_lock_axis != null:
			mp = _stroke_lock_anchor + _stroke_lock_axis * (mp - _stroke_lock_anchor).dot(_stroke_lock_axis)
	else:
		_stroke_lock_axis = null
		_stroke_lock_anchor = null
	if _stroke_first_stamp and (_brush_random_rot or _brush_random_ratio):
		# The first stamp must match the rotation/ratio the preview was showing.
		var v = null
		if _first_variant != null and _first_key == _brush_cache_key(res) \
			and _first_variant.size() > 5 and int(_first_variant[5]) == res \
			and abs(float(_first_variant[2]) - _preview_rot) < 0.0001 \
			and abs(float(_first_variant[4]) - _preview_ratio) < 0.0001:
			v = _first_variant
		else:
			v = _build_brush(res, _preview_rot, _preview_ratio)
		_brush_img = v[0]
		_brush_erase_img = v[1]
		_brush_rot = v[2]
		_stroke_first_stamp = false
	else:
		_pick_brush(res)
	var img: Image = layer["mask"]
	# Brush centre in mask px (float, so spacing is measured precisely).
	var cur = mp / float(res)
	var half = (_brush_img.get_width() - 1) * 0.5
	var spacing = max(1.0, half * STAMP_SPACING)
	var stamps := []
	_frame_counter += 1
	if _last_paint_pos.x == INF:
		stamps.append(cur)
	else:
		# Stamp every `spacing` px along the path since the last stamp — and
		# ONLY then (unless Continuous Paint is on): a stationary brush does
		# not keep accumulating, so the flow slider behaves like a real paint
		# program.
		var from = _last_paint_pos
		var dist = from.distance_to(cur)
		var n = int(floor(dist / spacing))
		for i in range(1, n + 1):
			stamps.append(from.linear_interpolate(cur, float(i) * spacing / dist))
		if n == 0:
			if _brush_continuous and _frame_counter % CONTINUOUS_INTERVAL == 0:
				stamps.append(cur)
			else:
				return
		else:
			cur = stamps[stamps.size() - 1]
	var dirty = Rect2()
	var first = true
	for p in stamps:
		# Variant sizes differ (random ratio): centre from the CURRENT image.
		var bw = _brush_img.get_width()
		var at = (p - Vector2(bw, bw) * 0.5).round()
		var sr = Rect2(at, Vector2(bw, bw))
		if first:
			dirty = sr
			first = false
		else:
			dirty = dirty.merge(sr)
		if _gs_active:
			_gs_stamp(at)
		elif _stroke_mode == MODE_NON_ADDITIVE:
			_stamp_max(img, at)
		elif _stroke_mode == MODE_PER_STROKE and _stroke_accum != null:
			_stamp_non_additive(img, at)
		else:
			var b = _brush_erase_img if _erasing else _brush_img
			img.blend_rect(b, Rect2(0, 0, b.get_width(), b.get_height()), at)
		_pick_brush(res)   # new random rotation for the next stamp
	_last_paint_pos = cur
	if not _gs_active:
		_upload_mask_rect(layer, dirty)


# Non-additive stamp: per pixel, the stroke's accumulated weight is the MAX of
# all stamps so far (not the sum), and the mask is re-derived from the
# stroke-start snapshot: mask = lerp(before, target, accum).
# Per-pixel stamps work on a CROPPED copy of the brush area as raw bytes
# (PoolByteArray): no Color allocation, no get/set_pixel call per texel, and
# the whole-mask images are only touched through C++ get_rect / blit_rect.
func _stamp_region(img: Image, at: Vector2) -> Array:
	var b: Image = _brush_img
	var full = Rect2(0, 0, img.get_width(), img.get_height())
	var r = Rect2(at, Vector2(b.get_width(), b.get_height())).clip(full)
	if r.size.x <= 0 or r.size.y <= 0:
		return []
	var off = r.position - at
	return [r, off]


# "Per stroke": per pixel, the stroke's accumulated weight is the MAX of all
# stamps so far (not the sum) and the mask is re-derived from the
# stroke-start snapshot: mask = lerp(before, target, accum).
func _stamp_non_additive(img: Image, at: Vector2) -> void:
	var reg = _stamp_region(img, at)
	if reg.empty():
		return
	var r: Rect2 = reg[0]
	var off: Vector2 = reg[1]
	var w = int(r.size.x)
	var h = int(r.size.y)
	var bw = _brush_img.get_width()
	var target = 0 if _erasing else 255
	var bd = _brush_img.get_data()
	var cur = img.get_rect(r)
	var cd = cur.get_data()
	var ad = _stroke_accum.get_rect(r).get_data()
	var bfd = _stroke_before.get_rect(r).get_data()
	var changed = false
	for y in range(h):
		var brow = (int(off.y) + y) * bw + int(off.x)
		var row = y * w
		for x in range(w):
			var a = bd[(brow + x) * 4 + 3]
			if a == 0:
				continue
			var i = (row + x) * 4
			var acc = ad[i + 3]
			if a <= acc:
				continue
			ad[i + 3] = a
			var base = bfd[i]
			var v = int(round(base + (target - base) * (a / 255.0)))
			if _erasing:
				v = max(0, base - a)
			cd[i] = v
			cd[i + 1] = v
			cd[i + 2] = v
			changed = true
	if not changed:
		return
	cur.create_from_data(w, h, false, Image.FORMAT_RGBA8, cd)
	img.blit_rect(cur, Rect2(0, 0, w, h), r.position)
	var acc_img = Image.new()
	acc_img.create_from_data(w, h, false, Image.FORMAT_RGBA8, ad)
	_stroke_accum.blit_rect(acc_img, Rect2(0, 0, w, h), r.position)


# Fully non-additive: paint = max(mask, weight), erase = min(mask, 1 - weight).
func _stamp_max(img: Image, at: Vector2) -> void:
	var reg = _stamp_region(img, at)
	if reg.empty():
		return
	var r: Rect2 = reg[0]
	var off: Vector2 = reg[1]
	var w = int(r.size.x)
	var h = int(r.size.y)
	var bw = _brush_img.get_width()
	var bd = _brush_img.get_data()
	var cur = img.get_rect(r)
	var cd = cur.get_data()
	var changed = false
	for y in range(h):
		var brow = (int(off.y) + y) * bw + int(off.x)
		var row = y * w
		for x in range(w):
			var a = bd[(brow + x) * 4 + 3]
			if a == 0:
				continue
			var i = (row + x) * 4
			var c = cd[i]
			var v = c
			if _erasing:
				v = max(0, c - a)
			elif a > c:
				v = a
			if v != c:
				cd[i] = v
				cd[i + 1] = v
				cd[i + 2] = v
				changed = true
	if not changed:
		return
	cur.create_from_data(w, h, false, Image.FORMAT_RGBA8, cd)
	img.blit_rect(cur, Rect2(0, 0, w, h), r.position)


# ── Presets / copy-paste (layer palettes: textures + z + opacity + quality +
#    colour settings, no painted data) ─────────────────────────────────────
const PRESETS_PATH = "user://BetterTerrainTool/presets.json"
var _preset_dropdown: OptionButton = null
var _preset_name_edit: LineEdit = null
var _paste_btn: Button = null
var _clipboard := []

func _build_presets_ui(align) -> void:
	var lbl = Label.new()
	lbl.text = "Layer presets"
	align.add_child(_rm(lbl))
	var prow = HBoxContainer.new()
	_preset_dropdown = OptionButton.new()
	_preset_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_dropdown.clip_text = true
	_preset_dropdown.hint_tooltip = "Saved layer palettes."
	prow.add_child(_preset_dropdown)
	var load_btn = Button.new()
	load_btn.text = "Load"
	load_btn.hint_tooltip = "Add the preset's layers to the current level."
	load_btn.connect("pressed", self, "_on_preset_apply")
	prow.add_child(load_btn)
	var del_btn = Button.new()
	var trash = _load_icon(_root + "icons/trash.png", 0.75)
	if trash != null:
		del_btn.icon = trash
	else:
		del_btn.text = "X"
	del_btn.hint_tooltip = "Delete the selected preset."
	del_btn.connect("pressed", self, "_on_preset_delete")
	prow.add_child(del_btn)
	align.add_child(_rm(prow))
	var srow = HBoxContainer.new()
	_preset_name_edit = LineEdit.new()
	_preset_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_name_edit.placeholder_text = "Preset name"
	srow.add_child(_preset_name_edit)
	var save_btn = Button.new()
	save_btn.text = "Save"
	save_btn.hint_tooltip = "Save the current level's layers as a preset (overwrites if the name exists)."
	save_btn.connect("pressed", self, "_on_preset_save")
	srow.add_child(save_btn)
	align.add_child(_rm(srow))
	_refresh_preset_dropdown()


func _palette_of_current() -> Array:
	var out := []
	for l in _cur_layers():
		var d = {"name": l["name"], "auto_name": bool(l["auto_name"]), "tex": l["tex"],
			"z": int(l["z"]), "opacity": float(l["opacity"]), "res": int(l["res"]), "cb2": true}
		for k in COLOR_KEYS:
			d[k] = _cv(l[k])
		out.append(d)
	return out


func _add_palette(items: Array) -> void:
	var entry = _cur_entry()
	if entry == null:
		return
	var last = null
	for d in items:
		if not (d is Dictionary):
			continue
		var layer = _new_layer(entry, str(d.get("name", "")), str(d.get("tex", DEFAULT_TEX)),
			int(d.get("z", -450)), float(d.get("opacity", 1.0)), true, int(d.get("res", DEFAULT_RES)))
		layer["auto_name"] = bool(d.get("auto_name", false))
		for k in COLOR_KEYS:
			layer[k] = _cv(d.get(k, COLOR_DEFAULTS[k]))
		if bool(d.get("smooth", false)):
			layer["blend"] = 2   # legacy field
		if not bool(d.get("cb2", false)):
			layer["color_blend"] = _migrate_cb(int(layer["color_blend"]))
		_apply_color_params(layer, layer["mat"])
		last = layer
	if last != null:
		_sel_uid = last["uid"]
	_schedule_persist()
	_refresh_layer_list()


func _on_copy_layers() -> void:
	_clipboard = _palette_of_current()
	if _paste_btn != null:
		_paste_btn.disabled = _clipboard.empty()


func _on_paste_layers() -> void:
	if not _clipboard.empty():
		_add_palette(_clipboard)


# Copy-value: dict/array colour settings (levels) must never be shared
# between two layers.
func _cv(v):
	if v is Dictionary:
		return v.duplicate(true)
	if v is Array:
		return v.duplicate(true)
	return v


func _migrate_cb(i: int) -> int:
	return CB_MIGRATE[i] if (i >= 0 and i < CB_MIGRATE.size()) else 0


func _load_presets() -> Dictionary:
	var f = File.new()
	if f.open(PRESETS_PATH, File.READ) != OK:
		return {}
	var pr = JSON.parse(f.get_as_text())
	f.close()
	if pr.error == OK and pr.result is Dictionary:
		return pr.result
	return {}


func _save_presets(d: Dictionary) -> void:
	Directory.new().make_dir_recursive("user://BetterTerrainTool")
	var f = File.new()
	if f.open(PRESETS_PATH, File.WRITE) == OK:
		f.store_string(JSON.print(d, "\t"))
		f.close()


func _refresh_preset_dropdown(select_name := "") -> void:
	if _preset_dropdown == null:
		return
	_preset_dropdown.clear()
	var names = _load_presets().keys()
	names.sort()
	for i in range(names.size()):
		_preset_dropdown.add_item(names[i])
		if names[i] == select_name:
			_preset_dropdown.select(i)


func _selected_preset_name() -> String:
	if _preset_dropdown == null or _preset_dropdown.selected < 0:
		return ""
	return _preset_dropdown.get_item_text(_preset_dropdown.selected)


func _on_preset_save() -> void:
	var name = _preset_name_edit.text.strip_edges()
	if name == "":
		name = _selected_preset_name()
	if name == "":
		return
	var d = _load_presets()
	d[name] = _palette_of_current()
	_save_presets(d)
	_preset_name_edit.text = ""
	_refresh_preset_dropdown(name)


func _on_preset_apply() -> void:
	var name = _selected_preset_name()
	if name == "":
		return
	var d = _load_presets()
	if d.has(name) and d[name] is Array:
		_add_palette(d[name])


func _on_preset_delete() -> void:
	var name = _selected_preset_name()
	if name == "":
		return
	var d = _load_presets()
	d.erase(name)
	_save_presets(d)
	_refresh_preset_dropdown()


# ── Paint modes ───────────────────────────────────────────────────────────────

# Icon of a toggle button as a centred TextureRect, tinted DD-blue while the
# button is pressed (like the vanilla toolbar icons).
func _icon_button_set_icon(b: Button, ic: Texture) -> void:
	var icr = TextureRect.new()
	icr.name = "ic"
	icr.texture = ic
	icr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	icr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icr.anchor_right = 1.0
	icr.anchor_bottom = 1.0
	icr.modulate = ACTIVE_ICON_COLOR if b.pressed else Color(1, 1, 1)
	b.add_child(icr)
	b.connect("toggled", self, "_on_icon_button_toggled", [b])


func _on_icon_button_toggled(on: bool, b: Button) -> void:
	var icr = b.get_node_or_null("ic")
	if icr != null:
		icr.modulate = ACTIVE_ICON_COLOR if on else Color(1, 1, 1)


func _on_paint_mode_toggled(pressed: bool, mode: int) -> void:
	if not pressed:
		return
	if _painting:
		_stroke_end()
	_paint_mode = mode
	_apply_paint_mode()


func _apply_paint_mode() -> void:
	if _paint_mode != PAINT_MOVE:
		_move_cancel()
	var ui = _g.get("WorldUI") if _g != null else null
	if ui != null:
		if _paint_mode == PAINT_DRAW and _tool_active:
			if _draw_saved_cursor == null:
				_draw_saved_cursor = ui.get("CursorMode")
			ui.set("CursorMode", 1)   # Point
		else:
			_draw_cancel(ui)
	# Fill and Polygonal Shape paint flat coverage: brushes are meaningless
	# there, so the Brushes tab is hidden and Textures is forced.
	var no_brush = _paint_mode == PAINT_BUCKET or _paint_mode == PAINT_DRAW
	if _rp_tab_row != null and is_instance_valid(_rp_tab_row):
		_rp_tab_row.visible = not no_brush
	if _shape_sub_row != null and is_instance_valid(_shape_sub_row):
		_shape_sub_row.visible = _paint_mode == PAINT_DRAW
	if no_brush and _rp_tab != 0 and _rp_tab_btns.size() > 0:
		_rp_tab_btns[0].pressed = true   # switches to Textures via the handler
	var bucket = _paint_mode == PAINT_BUCKET
	# The Textures tab is useful in every mode: keep the panel visible.
	_set_right_panel_visible(_tool_active)
	for r in _square_rows:
		if is_instance_valid(r):
			r.visible = _paint_mode == PAINT_SQUARE
	if _bucket_opts != null and is_instance_valid(_bucket_opts):
		_bucket_opts.visible = bucket
	_set_bucket_cursor(_tool_active and bucket)
	if _square_preview != null and is_instance_valid(_square_preview):
		_square_preview.visible = false


func _update_bucket_cursor() -> void:
	var want = _tool_active and _paint_mode == PAINT_BUCKET
	if want and _input_listener != null and is_instance_valid(_input_listener):
		var vp = _input_listener.get_viewport()
		if vp != null and _mouse_over_ui(vp.get_mouse_position()):
			want = false
	_set_bucket_cursor(want)


func _set_bucket_cursor(on: bool) -> void:
	if on == _bucket_cursor_on:
		return
	_bucket_cursor_on = on
	if on and _bucket_cursor_tex != null:
		var sz = _bucket_cursor_tex.get_size()
		Input.set_custom_mouse_cursor(_bucket_cursor_tex, Input.CURSOR_ARROW, Vector2(0, sz.y))
	else:
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)


# Square brush: side = _square_cells grid cells, in whole mask pixels, snapped
# to the mask grid (or centred on the snap point when snapping is on). Hard
# edges, full weight.
func _square_rect(layer: Dictionary, mp: Vector2) -> Rect2:
	var res = int(layer["res"])
	var side = max(1, int(round(_square_cells * _square_cell_px() / res)))
	var snapped = _snap_point(mp)
	if snapped != null:
		var corner = (snapped - Vector2(side, side) * 0.5 * res) / res
		return Rect2(int(round(corner.x)), int(round(corner.y)), side, side)
	var cx = int(floor(mp.x / res))
	var cy = int(floor(mp.y / res))
	var lo = side / 2
	return Rect2(cx - lo, cy - lo, side, side)


# Snap target for the square brush: Custom Snap (snappy_mod) when its custom
# snap is on AND DD's snap is on; else DD's own grid snap; null when snap is off.
func _snap_point(mp: Vector2):
	if _g.Editor == null or _g.Editor.get("IsSnapping") != true:
		return null
	var snappy = _get_snappy_mod()
	if snappy != null and snappy.get("custom_snap_enabled") and snappy.has_method("get_snapped_position"):
		return snappy.get_snapped_position(mp)
	var wui = _g.get("WorldUI")
	if wui != null and wui.has_method("GetSnappedPosition"):
		var p = wui.GetSnappedPosition(mp)
		if p is Vector2:
			return p
	return null


var _snappy_ref = null
var _snappy_searched := false

func _get_snappy_mod():
	if _snappy_ref != null and is_instance_valid(_snappy_ref):
		return _snappy_ref
	if _snappy_searched:
		return null
	_snappy_searched = true
	var api = _g.get("API")
	if api != null and typeof(api) == TYPE_OBJECT:
		var sm = api.get("snappy_mod")
		if sm != null and sm.has_method("get_snapped_position"):
			_snappy_ref = sm
			return sm
	var toolset = _g.Editor.get("Toolset")
	if toolset != null:
		var toolbars = toolset.get("Toolbars")
		if toolbars is Dictionary:
			for key in toolbars.keys():
				var found = _find_snappy_from_panel(toolbars[key])
				if found != null:
					_snappy_ref = found
					return found
	return null


func _find_snappy_from_panel(node):
	if node == null or not is_instance_valid(node) or not (node is Node):
		return null
	if node is BaseButton:
		for sig_name in ["pressed", "toggled"]:
			for conn in node.get_signal_connection_list(sig_name):
				var target = conn.get("target")
				if target != null and target.has_method("get_snapped_position"):
					return target
	for child in node.get_children():
		var found = _find_snappy_from_panel(child)
		if found != null:
			return found
	return null


func _square_paint(layer: Dictionary, mp: Vector2) -> void:
	var img: Image = layer["mask"]
	var r = _square_rect(layer, mp).clip(Rect2(0, 0, img.get_width(), img.get_height()))
	if r.size.x <= 0 or r.size.y <= 0:
		return
	var v = 0.0 if _erasing else 1.0
	var block = Image.new()
	block.create(int(r.size.x), int(r.size.y), false, Image.FORMAT_RGBA8)
	block.fill(Color(v, v, v, 1))
	img.blit_rect(block, Rect2(0, 0, r.size.x, r.size.y), r.position)
	_upload_mask_rect(layer, r)


func _update_square_preview() -> void:
	var show = _tool_active and _paint_mode == PAINT_SQUARE and _paint_target() != null
	if not show:
		if _square_preview != null and is_instance_valid(_square_preview):
			_square_preview.visible = false
		return
	if _square_preview == null or not is_instance_valid(_square_preview):
		_square_preview = Line2D.new()
		_square_preview.width = 2.0
		_square_preview.default_color = Color(1, 1, 0, 0.9)
		_square_preview.z_as_relative = false
		_square_preview.z_index = 4000
		_g.World.add_child(_square_preview)
	var ui = _g.get("WorldUI")
	var mp = ui.get("MousePosition") if ui != null else null
	if not (mp is Vector2):
		return
	var vp = _square_preview.get_viewport()
	if not _painting and vp != null and _mouse_over_ui(vp.get_mouse_position()):
		_square_preview.visible = false
		return
	var layer = _paint_target()
	var res = float(layer["res"])
	var r = _square_rect(layer, mp)
	var a = r.position * res
	var b = r.end * res
	_square_preview.points = PoolVector2Array([a, Vector2(b.x, a.y), b, Vector2(a.x, b.y), a])
	# Constant 2 px on screen whatever the zoom.
	if vp != null:
		var zoom = vp.get_canvas_transform().get_scale().x
		if zoom > 0.0:
			_square_preview.width = 2.0 / zoom
	_square_preview.visible = true


# ── Bucket fill ───────────────────────────────────────────────────────────────
# Same model as the Unofficial Patch terrain bucket: region bounded by the
# enabled barrier types (region_geometry.gd), rasterised with fractional
# coverage into the layer's mask (soft edge = anti-aliasing only).

func _bucket_click(erase: bool):
	if _multi_selected():
		return
	if _filling:
		print("[BetterTerrain] Bucket: a fill is already running.")
		return
	var layer = _paint_target()
	if layer == null:
		print("[BetterTerrain] Bucket: no layer selected.")
		return
	if _region_geo == null:
		printerr("[BetterTerrain] Bucket: library/region_geometry.gd failed to load.")
		return
	var ui = _g.get("WorldUI")
	var mp = ui.get("MousePosition") if ui != null else null
	if not (mp is Vector2):
		return
	_filling = true
	var st = _bucket_fill(layer, mp, erase)
	if st is GDScriptFunctionState:
		yield(st, "completed")
	_filling = false


func _bucket_fill(layer: Dictionary, mp: Vector2, erase: bool):
	var tree = _g.Editor.get_tree()
	var progress = null
	if _progress_script != null:
		progress = _progress_script.new()
		progress._g = _g
		progress.start("Filling layer…")
		progress.set_progress(0.0, "Computing fill region…")
		yield(tree, "idle_frame")
	var region = _region_geo.compute_region_async(mp, _cb_walls.pressed, _cb_paths.pressed, _cb_patterns.pressed, progress, 0.0, 0.6)
	if region is GDScriptFunctionState:
		region = yield(region, "completed")
	if progress != null and region.get("cancelled") == true:
		progress.close()
		return
	var outer = region.outer
	if outer.size() < 3:
		if progress != null:
			progress.close()
		print("[BetterTerrain] Bucket: no region under the click.")
		return
	var polys := []
	if abs(BUCKET_REACH) > 0.01:
		for p in Geometry.offset_polygon_2d(outer, BUCKET_REACH, Geometry.JOIN_MITER):
			if p.size() >= 3:
				polys.append(_region_geo._to_array(p))
	if polys.empty():
		polys = [outer]
	var img: Image = layer["mask"]
	var res = float(layer["res"])
	var tw = img.get_width()
	var th = img.get_height()
	var minw = polys[0][0]
	var maxw = polys[0][0]
	for poly in polys:
		for p in poly:
			minw.x = min(minw.x, p.x)
			minw.y = min(minw.y, p.y)
			maxw.x = max(maxw.x, p.x)
			maxw.y = max(maxw.y, p.y)
	var x0 = int(clamp(floor(minw.x / res) - 1, 0, tw - 1))
	var x1 = int(clamp(ceil(maxw.x / res) + 1, 0, tw - 1))
	var y0 = int(clamp(floor(minw.y / res) - 1, 0, th - 1))
	var y1 = int(clamp(ceil(maxw.y / res) + 1, 0, th - 1))
	var w = x1 - x0 + 1
	var h = y1 - y0 + 1
	var cov = _compute_coverage(polys, x0, y0, w, h, res, BUCKET_SUPERSAMPLE, progress)
	if cov is GDScriptFunctionState:
		cov = yield(cov, "completed")
	if cov == null:
		if progress != null:
			progress.close()
		return
	if progress != null:
		progress.set_progress(1.0, "Done")
		yield(tree, "idle_frame")
		progress.close()
	var before = img.duplicate()
	var target = 0.0 if erase else 1.0
	img.lock()
	for yy in range(h):
		for xx in range(w):
			var wgt = cov[yy * w + xx]
			if wgt <= 0.0:
				continue
			var x = x0 + xx
			var y = y0 + yy
			var cur = img.get_pixel(x, y).r
			var v = lerp(cur, target, wgt)
			img.set_pixel(x, y, Color(v, v, v, 1))
	img.unlock()
	_upload_mask_rect(layer, Rect2(x0, y0, w, h))
	_record(layer, before, img.duplicate())
	layer["dirty"] = true
	_schedule_persist()


# Fractional coverage of each mask texel by the even-odd union of `polys`
# (scanline rasterisation, SS x SS sub-samples). Mask texel (x, y) covers
# world [x*res, (x+1)*res). Returns null when cancelled.
func _compute_coverage(polys: Array, x0: int, y0: int, w: int, h: int, res: float, SS: int, progress):
	var tree = _g.Editor.get_tree()
	var counts := []
	counts.resize(w * h)
	for i in range(w * h):
		counts[i] = 0
	var sub = res / SS
	var bx0 = x0 * res
	var by0 = y0 * res
	var max_cc = w * SS - 1
	var sub_rows = h * SS
	var xs := []
	for r in range(sub_rows):
		if progress != null and progress.pump():
			progress.set_progress(0.6 + 0.38 * float(r) / max(1, sub_rows), "Rasterizing… %d / %d" % [r, sub_rows])
			yield(tree, "idle_frame")
			if progress.cancelled:
				return null
		var wy = by0 + (r + 0.5) * sub
		var trow = r / SS
		xs.clear()
		for poly in polys:
			var n = poly.size()
			if n < 3:
				continue
			var j = n - 1
			for k in range(n):
				var a = poly[k]
				var b = poly[j]
				if (a.y > wy) != (b.y > wy):
					var t = (wy - a.y) / (b.y - a.y)
					xs.append(a.x + t * (b.x - a.x))
				j = k
		if xs.size() < 2:
			continue
		xs.sort()
		var base = trow * w
		var p = 0
		while p + 1 < xs.size():
			var cc0 = int(ceil((xs[p] - bx0) / sub - 0.5))
			var cc1 = int(floor((xs[p + 1] - bx0) / sub - 0.5))
			if bx0 + (cc1 + 0.5) * sub >= xs[p + 1]:
				cc1 -= 1
			if cc0 < 0:
				cc0 = 0
			if cc1 > max_cc:
				cc1 = max_cc
			var tc = cc0 / SS
			while tc * SS <= cc1:
				var lo = tc * SS
				var hi = lo + SS - 1
				if lo < cc0:
					lo = cc0
				if hi > cc1:
					hi = cc1
				counts[base + tc] += (hi - lo + 1)
				tc += 1
			p += 2
	var cov := []
	cov.resize(w * h)
	var inv = 1.0 / float(SS * SS)
	for i in range(w * h):
		cov[i] = float(counts[i]) * inv
	return cov


func _fill_layer(value: float) -> void:
	var layer = _paint_target()
	if layer == null:
		return
	var before = layer["mask"].duplicate()
	layer["mask"].fill(Color(value, value, value, 1))
	_upload_mask(layer)
	_record(layer, before, layer["mask"].duplicate())
	layer["dirty"] = true
	_schedule_persist()


# ── Undo ──────────────────────────────────────────────────────────────────────

func _record(layer: Dictionary, before: Image, after: Image) -> void:
	if layer.get("grp"):
		_record_op({"type": "gmask", "level_id": _cur_level_id, "guid": int(layer["uid"]),
			"before": before, "after": after})
		return
	if _record_script == null:
		return
	var hist = _g.Editor.get("History")
	if hist == null or not hist.has_method("CreateCustomRecord"):
		return
	var rec = _record_script.new()
	rec.driver = self
	rec.level_id = _cur_level_id
	rec.layer_uid = layer["uid"]
	rec.before = before
	rec.after = after
	hist.CreateCustomRecord(rec)


func _record_op(op: Dictionary) -> void:
	if _op_record_script == null:
		return
	var hist = _g.Editor.get("History")
	if hist == null or not hist.has_method("CreateCustomRecord"):
		return
	var rec = _op_record_script.new()
	rec.driver = self
	rec.op = op
	hist.CreateCustomRecord(rec)


# Everything needed to recreate a layer (in-memory Image reference included).
func _serialize_layer(layer: Dictionary) -> Dictionary:
	var d = {
		"uid": int(layer["uid"]), "name": layer["name"], "auto_name": bool(layer["auto_name"]),
		"tex": layer["tex"], "z": int(layer["z"]), "opacity": float(layer["opacity"]),
		"visible": bool(layer["visible"]), "res": int(layer["res"]),
		"mask": (layer["mask"] as Image).duplicate(),
	}
	for k in COLOR_KEYS:
		d[k] = _cv(layer[k])
	d["light_paint"] = bool(layer.get("light_paint", false))
	d["light_intensity"] = float(layer.get("light_intensity", 1.0))
	d["clip"] = int(layer.get("clip", 0))
	d["clip_z"] = layer.get("clip_z")
	d["clip_obj"] = layer.get("clip_obj")
	d["gen"] = layer.get("gen")
	return d


func _restore_layer(level_id: int, d: Dictionary) -> void:
	var entry = _levels.get(level_id)
	if entry == null:
		return
	var layer = _new_layer(entry, str(d["name"]), str(d["tex"]), int(d["z"]),
		float(d["opacity"]), bool(d["visible"]), int(d["res"]), d["mask"])
	layer["auto_name"] = bool(d["auto_name"])
	layer["uid"] = int(d["uid"])
	_next_uid = max(_next_uid, int(d["uid"]) + 1)
	for k in COLOR_KEYS:
		layer[k] = _cv(d.get(k, COLOR_DEFAULTS[k]))
	layer["light_paint"] = bool(d.get("light_paint", false))
	layer["light_intensity"] = float(d.get("light_intensity", 1.0))
	layer["clip"] = int(d.get("clip", 0))
	layer["clip_z"] = d.get("clip_z")
	layer["clip_obj"] = d.get("clip_obj")
	layer["gen"] = d.get("gen") if d.get("gen") is Dictionary else null
	_light_update(entry, layer)
	_clip_update(entry, layer)
	_apply_color_params(layer, layer["mat"])
	_upload_mask(layer)


func _drop_group_membership(uid: int) -> void:
	var g = _group_of(uid)
	if g != null:
		g["members"].erase(uid)
		if g["members"].empty():
			_cur_groups().erase(g)


func _delete_layer_by_uid(level_id: int, uid: int) -> void:
	_drop_group_membership(uid)
	var entry = _levels.get(level_id)
	if entry == null:
		return
	for i in range(entry["layers"].size()):
		if int(entry["layers"][i]["uid"]) == uid:
			_remove_layer(entry, i)
			break


# Called by the op undo record.
func apply_layer_op(op: Dictionary, is_undo: bool) -> void:
	var t = str(op.get("type"))
	var level_id = int(op.get("level_id", -1))
	if t == "multi":
		# One history entry for several ops (multi-delete, delete group).
		var ops: Array = op["ops"]
		if is_undo:
			for i in range(ops.size() - 1, -1, -1):
				apply_layer_op(ops[i], true)
		else:
			for o in ops:
				apply_layer_op(o, false)
		return
	if t == "add":
		if is_undo:
			_delete_layer_by_uid(level_id, int(op["layer"]["uid"]))
		else:
			_restore_layer(level_id, op["layer"])
	elif t == "group":
		_apply_group_op(op, is_undo)
	elif t == "remove":
		if is_undo:
			_restore_layer(level_id, op["layer"])
			# Back into its group, when the layer was grouped and the group
			# still exists.
			var rg = _group_in_level(level_id, int(op.get("group", -1)))
			if rg != null and not rg["members"].has(int(op["layer"]["uid"])):
				rg["members"].append(int(op["layer"]["uid"]))
		else:
			_delete_layer_by_uid(level_id, int(op["layer"]["uid"]))
	elif t == "tex":
		var layer = _find_layer(level_id, int(op["uid"]))
		if layer != null:
			_set_layer_texture(layer, str(op["before"] if is_undo else op["after"]))
	elif t == "gmask":
		var g3 = _group_in_level(level_id, int(op["guid"]))
		if g3 != null:
			_grp_runtime(g3)
			var src = op["before"] if is_undo else op["after"]
			if src is Image:
				g3["mask"].copy_from(src)
				_upload_mask(g3)
				g3["dirty"] = true
	elif t == "gclip":
		var gc = _group_in_level(level_id, int(op["guid"]))
		var entry_gc = _levels.get(level_id)
		if gc != null and entry_gc != null:
			var gst = op["before"] if is_undo else op["after"]
			gc["clip"] = int(gst["clip"])
			gc["clip_z"] = null
			gc["clip_obj"] = gst.get("clip_obj")
			_grp_clip_update(entry_gc, gc)
	elif t == "clip_pick":
		var layer2 = _find_layer(level_id, int(op["uid"]))
		if layer2 != null:
			var st = op["before"] if is_undo else op["after"]
			layer2["z"] = int(st["z"])
			layer2["clip"] = int(st["clip"])
			layer2["clip_z"] = st["clip_z"]
			layer2["clip_obj"] = st.get("clip_obj")
			if layer2["node"] != null and is_instance_valid(layer2["node"]):
				layer2["node"].z_index = int(st["z"])
			var entry2 = _levels.get(level_id)
			if entry2 != null:
				_clip_update(entry2, layer2)
	if level_id == _cur_level_id:
		if _sel_uid != -1 and _find_layer(level_id, _sel_uid) == null:
			_sel_uid = -1
		_refresh_layer_list()
	_schedule_persist()


# Called by the undo record.
func restore_mask(level_id: int, uid: int, img: Image) -> void:
	var layer = _find_layer(level_id, uid)
	if layer == null:
		return
	layer["mask"].copy_from(img)
	_upload_mask(layer)
	layer["dirty"] = true
	_schedule_persist()


# ── Map resize ────────────────────────────────────────────────────────────────

# DD does not expose the resize offset to GDScript: read the dialog's Left /
# Top spinboxes when its OK button fires, so the masks can be shifted by the
# same amount as the map content (cells added on the left / top push
# everything right / down; removed ones crop).
func _hook_resize_dialog() -> void:
	if _resize_hooked or _g == null or _g.Editor == null:
		return
	var dlg = _g.Editor.get_node_or_null("Windows/ChangeMapSize")
	if dlg == null:
		return
	var ok = dlg.get_node_or_null("Margins/VAlign/Buttons/OkayButton")
	if ok == null:
		ok = dlg.find_node("OkayButton", true, false)
	if ok == null:
		return
	ok.connect("pressed", self, "_on_resize_ok_pressed", [dlg])
	_resize_hooked = true


func _on_resize_ok_pressed(dlg) -> void:
	# The spinboxes are looked up by name anywhere under the dialog: mods
	# (map_resize_fix) re-parent DD's GridContainer into their own layout.
	var lsb = dlg.find_node("LeftSpinBox", true, false)
	var tsb = dlg.find_node("TopSpinBox", true, false)
	if lsb == null and tsb == null:
		print("[BetterTerrain] map resize: Left/Top spinboxes not found")
		return
	_resize_cells = Vector2(float(lsb.value) if lsb != null else 0.0, float(tsb.value) if tsb != null else 0.0)
	print("[BetterTerrain] map resize requested, left/top cells: ", _resize_cells)


# World-pixel shift of the existing content for the pending resize (zero
# when none): cells added on the left / top push everything right / down.
func _pending_shift_px() -> Vector2:
	if _resize_cells == Vector2.ZERO:
		return Vector2.ZERO
	var cell = Vector2(256, 256)
	var wui = _g.get("WorldUI") if _g != null else null
	if wui != null and wui.get("CellSize") is Vector2:
		cell = wui.get("CellSize")
	return _resize_cells * cell


# Fit a mask to (w, h) texels WITHOUT stretching: pad with `fill`, shifting
# the old content by `shift_px` world pixels (negative = crop).
func _fit_mask(old: Image, w: int, h: int, res: int, shift_px: Vector2, fill: Color) -> Image:
	if old.get_width() == w and old.get_height() == h and shift_px == Vector2.ZERO:
		return old
	var img = Image.new()
	img.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(fill)
	img.blit_rect(old, Rect2(0, 0, old.get_width(), old.get_height()), (shift_px / float(res)).round())
	return img


func _check_map_resize() -> void:
	_hook_resize_dialog()
	var wx = _woxels()
	if wx == Vector2.ZERO:
		return
	if _map_size == Vector2.ZERO:
		_map_size = wx
		return
	if wx == _map_size:
		return
	_map_size = wx
	var shift_px = _pending_shift_px()
	print("[BetterTerrain] map size changed to ", wx, ", shifting masks by ", shift_px, " px")
	for lid in _levels.keys():
		var entry = _levels[lid]
		for layer in entry["layers"]:
			var res = int(layer["res"])
			var w = max(1, int(ceil(wx.x / res)))
			var h = max(1, int(ceil(wx.y / res)))
			var img = _fit_mask(layer["mask"], w, h, res, shift_px, Color(0, 0, 0, 1))
			layer["mask"] = img
			layer["mask_tex"].create_from_image(img, Texture.FLAG_FILTER)
			var pts = PoolVector2Array([Vector2(0, 0), Vector2(wx.x, 0), Vector2(wx.x, wx.y), Vector2(0, wx.y)])
			layer["poly"].polygon = pts
			layer["poly"].uv = pts
			layer["mat"].set_shader_param("map_size", wx)
			layer["mat"].set_shader_param("mask", layer["mask_tex"])
			layer["dirty"] = true
		for g in entry.get("groups", []):
			if not (g.get("mask") is Image):
				continue
			_grp_runtime(g)
			var gres = int(g.get("res", DEFAULT_RES))
			var gimg = _fit_mask(g["mask"], max(1, int(ceil(wx.x / gres))), max(1, int(ceil(wx.y / gres))), gres, shift_px, Color(1, 1, 1, 1))
			g["mask"] = gimg
			g["mask_tex"].create_from_image(gimg, Texture.FLAG_FILTER)
			if int(g.get("blend", 0)) == 1:
				_blur_full_build(g)
			g["dirty"] = true
		_groups_sync_shaders(entry)
	_schedule_persist()


# ── Persistence (Global.ModMapData) ───────────────────────────────────────────

func _mmd():
	if _g == null:
		return null
	var m = _g.get("ModMapData")
	return m if m is Dictionary else null


# Mask PNG encoding is the expensive part (seconds for a fine mask), so:
#   - it is debounced (PERSIST_DELAY after the last change),
#   - it runs in a background Thread on a copy of the masks,
#   - metadata (z, opacity, names...) is written immediately.
func _schedule_persist() -> void:
	_persist_timer = PERSIST_DELAY
	_persist()   # metadata now; masks keep their previous encoding until the job lands


func _tick_persist(delta: float) -> void:
	if _encode_thread != null and not _encode_thread.is_alive():
		_encode_thread.wait_to_finish()
		_encode_thread = null
		_persist()
		if _encode_pending:
			_encode_pending = false
			_persist_timer = 0.0
	if _persist_timer < 0.0:
		return
	_persist_timer -= delta
	if _persist_timer > 0.0:
		return
	_persist_timer = -1.0
	if _encode_thread != null:
		_encode_pending = true   # a job is running: redo once it is done
		return
	var jobs := []
	for lid in _levels.keys():
		for layer in _levels[lid]["layers"]:
			if layer["dirty"] or layer["b64"] == "":
				jobs.append([layer, layer["mask"].duplicate()])
				layer["dirty"] = false
		for g in _levels[lid].get("groups", []):
			if g.get("mask") is Image and (bool(g.get("dirty", false)) or str(g.get("b64", "")) == ""):
				jobs.append([g, g["mask"].duplicate()])
				g["dirty"] = false
	if jobs.empty():
		return
	_encode_thread = Thread.new()
	if _encode_thread.start(self, "_encode_job", jobs) != OK:
		_encode_thread = null
		for j in jobs:
			j[0]["b64"] = _encode_mask(j[1])
		_persist()


func _encode_job(jobs: Array) -> void:
	for j in jobs:
		j[0]["b64"] = _encode_mask(j[1])


func _persist() -> void:
	var mmd = _mmd()
	if mmd == null:
		return
	var data = mmd.get(EMBED_KEY, {})
	if not (data is Dictionary):
		data = {}
	var levels = data.get("levels", {})
	if not (levels is Dictionary):
		levels = {}
	for lid in _levels.keys():
		var arr := []
		for layer in _levels[lid]["layers"]:
			arr.append({
				"name": layer["name"], "auto_name": bool(layer["auto_name"]), "tex": layer["tex"], "z": int(layer["z"]),
				"opacity": float(layer["opacity"]), "visible": bool(layer["visible"]),
				"hue": float(layer["hue"]), "saturation": float(layer["saturation"]),
				"lightness": float(layer["lightness"]), "gamma": float(layer["gamma"]), "contrast": float(layer["contrast"]),
				"tint_color": str(layer["tint_color"]), "tint_amount": float(layer["tint_amount"]),
				"tex_rot": float(layer["tex_rot"]), "tex_scale": float(layer["tex_scale"]),
				"tex_off_x": float(layer["tex_off_x"]), "tex_off_y": float(layer["tex_off_y"]), "blend": int(layer["blend"]),
				"smoothness": float(layer["smoothness"]), "color_blend": int(layer["color_blend"]),
				"levels": _cv(layer["levels"]),
				"light_paint": bool(layer.get("light_paint", false)),
				"light_intensity": float(layer.get("light_intensity", 1.0)),
				"clip": int(layer.get("clip", 0)),
				"clip_z": layer.get("clip_z"),
				"clip_obj": layer.get("clip_obj"),
				"gen": layer.get("gen"),
				"res": int(layer["res"]), "w": layer["mask"].get_width(),
				"h": layer["mask"].get_height(), "mask": layer["b64"],
			})
		var garr := []
		for g in _levels[lid].get("groups", []):
			var gd = {"uid": int(g["uid"]), "name": str(g["name"]),
				"members": g["members"].duplicate(), "open": bool(g["open"]), "visible": bool(g["visible"]),
				"opacity": float(g.get("opacity", 1.0)), "blend": int(g.get("blend", 0)),
				"smoothness": float(g.get("smoothness", 1536.0)), "res": int(g.get("res", DEFAULT_RES))}
			for ck in GRP_CS_KEYS:
				if g.has(ck):
					gd[ck] = g[ck].duplicate(true) if g[ck] is Dictionary else g[ck]
			if g.get("mask") is Image:
				gd["w"] = g["mask"].get_width()
				gd["h"] = g["mask"].get_height()
				gd["mask"] = str(g.get("b64", ""))
			garr.append(gd)
		levels[str(lid)] = {"layers": arr, "groups": garr}
	data["v"] = 3   # v2: coverage moved to red; v3: reordered color_blend list
	data["levels"] = levels
	data["hide_vanilla"] = _hide_vanilla
	mmd[EMBED_KEY] = data


func _encode_mask(img: Image) -> String:
	# Coverage lives in the red channel and the masks are always grey
	# (R = G = B, A = 1): a single-channel PNG holds exactly the same data
	# at ~60% of the RGBA size. The loader converts back to RGBA8.
	var l8 = img.duplicate()
	l8.convert(Image.FORMAT_L8)
	if l8.has_method("save_png_to_buffer"):
		return Marshalls.raw_to_base64(l8.save_png_to_buffer())
	img = l8
	# Older Godot: round-trip through a temp file.
	var tmp = "user://better_terrain_tool_tmp.png"
	img.save_png(tmp)
	var f = File.new()
	if f.open(tmp, File.READ) != OK:
		return ""
	var bytes = f.get_buffer(f.get_len())
	f.close()
	Directory.new().remove(tmp)
	return Marshalls.raw_to_base64(bytes)


func _load_level_from_embed(lid: int, entry: Dictionary) -> void:
	var mmd = _mmd()
	if mmd == null:
		return
	var data = mmd.get(EMBED_KEY)
	if not (data is Dictionary):
		data = mmd.get(LEGACY_EMBED_KEY)   # maps saved by the "Terrain Layers" prototype
	if not (data is Dictionary):
		return
	if data.has("hide_vanilla"):
		_hide_vanilla = bool(data.get("hide_vanilla", false))
		if _hide_vanilla_check != null and is_instance_valid(_hide_vanilla_check):
			_ui_syncing = true
			_hide_vanilla_check.pressed = _hide_vanilla
			_ui_syncing = false
		call_deferred("_apply_hide_vanilla")
	var legacy_alpha = int(data.get("v", 1)) < 2
	var levels = data.get("levels", {})
	if not (levels is Dictionary):
		return
	var ld = levels.get(str(lid))
	if not (ld is Dictionary):
		return
	var arr = ld.get("layers", [])
	if not (arr is Array):
		return
	var entry_g = _levels.get(lid)
	if entry_g != null:
		entry_g["groups"] = []
		for gd in ld.get("groups", []):
			if gd is Dictionary:
				var mm := []
				for m in gd.get("members", []):
					mm.append(int(m))
				var ng = {"uid": int(gd["uid"]), "name": str(gd["name"]),
					"members": mm, "open": bool(gd.get("open", true)), "visible": bool(gd.get("visible", true)),
					"opacity": float(gd.get("opacity", 1.0)), "blend": int(gd.get("blend", 0)),
					"smoothness": float(gd.get("smoothness", 1536.0)), "res": int(gd.get("res", DEFAULT_RES))}
				for ck in GRP_CS_KEYS:
					if gd.has(ck):
						ng[ck] = gd[ck].duplicate(true) if gd[ck] is Dictionary else gd[ck]
				var gb64 = str(gd.get("mask", ""))
				if gb64 != "":
					var gimg = Image.new()
					if gimg.load_png_from_buffer(Marshalls.base64_to_raw(gb64)) == OK:
						if gimg.get_format() != Image.FORMAT_RGBA8:
							gimg.convert(Image.FORMAT_RGBA8)
						ng["mask"] = gimg
						ng["b64"] = gb64
				entry_g["groups"].append(ng)
				_next_group_uid = max(_next_group_uid, int(gd["uid"]) + 1)
	for d in arr:
		if not (d is Dictionary):
			continue
		var mask = null
		var b64 = str(d.get("mask", ""))
		if b64 != "":
			var img = Image.new()
			if img.load_png_from_buffer(Marshalls.base64_to_raw(b64)) == OK:
				if img.get_format() != Image.FORMAT_RGBA8:
					img.convert(Image.FORMAT_RGBA8)
				if legacy_alpha:
					_convert_alpha_to_red(img)
				mask = img
		var layer = _new_layer(entry, str(d.get("name", "")), str(d.get("tex", DEFAULT_TEX)),
			int(d.get("z", -450)), float(d.get("opacity", 1.0)), bool(d.get("visible", true)),
			int(d.get("res", DEFAULT_RES)), mask)
		layer["b64"] = b64
		layer["auto_name"] = bool(d.get("auto_name", false))
		for k in COLOR_KEYS:
			layer[k] = _cv(d.get(k, COLOR_DEFAULTS[k]))
		if bool(d.get("smooth", false)):
			layer["blend"] = 2   # legacy field
		if int(data.get("v", 1)) < 3:
			layer["color_blend"] = _migrate_cb(int(layer["color_blend"]))
		layer["light_paint"] = bool(d.get("light_paint", false))
		layer["light_intensity"] = float(d.get("light_intensity", 1.0))
		layer["clip"] = int(d.get("clip", 0))
		layer["clip_z"] = d.get("clip_z")
		layer["clip_obj"] = d.get("clip_obj")
		layer["gen"] = d.get("gen") if d.get("gen") is Dictionary else null
		_light_update(entry, layer)
		_clip_update(entry, layer)
		_apply_color_params(layer, layer["mat"])
		layer["dirty"] = mask == null
		if layer["dirty"]:
			_schedule_persist()
	_groups_sync_shaders(entry)


# Prototype maps stored coverage in alpha; move it to red (alpha = 1).
func _convert_alpha_to_red(img: Image) -> void:
	img.lock()
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var a = img.get_pixel(x, y).a
			img.set_pixel(x, y, Color(a, a, a, 1))
	img.unlock()


# ── Tool panel ────────────────────────────────────────────────────────────────

func _register_tool() -> void:
	if _g.Editor == null or _g.Editor.Toolset == null:
		return
	_tool_panel = _g.Editor.Toolset.CreateModTool(self, TOOL_CATEGORY, TOOL_ID, TOOL_NAME, _root + "icons/better_terrain_tool.png")
	if _tool_panel == null:
		printerr("[BetterTerrain] CreateModTool failed")
		return
	_place_toolbar_button()
	var align = _tool_panel.Align

	# ── Paint mode (Brush / Square / Bucket) ──
	_tool_panel.BeginSection(false)
	var mode_row = HBoxContainer.new()
	var grp = ButtonGroup.new()
	_mode_buttons = []
	mode_row.alignment = BoxContainer.ALIGN_CENTER
	var mode_defs = [
		["brush_round.png", "Brush", PAINT_BRUSH, "Brush"],
		["draw.png", "Shape — rectangle, ellipse or polygon coverage. Right click = erase, Alt = draw from centre, Shift = 1:1.", PAINT_DRAW, "Shape"],
		["bucket.png", "Fill — fill the region (bounded by walls / paths / patterns) under the click", PAINT_BUCKET, "Fill"],
		["move.png", "Move — drag the selected layer's coverage on the canvas (content pushed past the map edge is lost)", PAINT_MOVE, "Move"],
	]
	for d in mode_defs:
		var b = Button.new()
		b.toggle_mode = true
		b.group = grp
		b.focus_mode = Control.FOCUS_NONE
		b.hint_tooltip = d[1]
		b.rect_min_size = Vector2(30, 27)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # share the row's full width
		var ic = _load_icon(_root + "icons/" + d[0], 0.8)
		if ic != null:
			_icon_button_set_icon(b, ic)
		else:
			b.text = d[3]
		b.connect("toggled", self, "_on_paint_mode_toggled", [d[2]])
		mode_row.add_child(b)
		_mode_buttons.append(b)
	_mode_buttons[0].pressed = true
	align.add_child(_rm(mode_row))
	var sub_row = HBoxContainer.new()
	_shape_sub_row = sub_row
	sub_row.visible = false
	var sgrp = ButtonGroup.new()
	_shape_btns = []
	var sub_defs = [
		["shape_rect.png", "Rectangle", 0],
		["shape_oval.png", "Ellipse", 1],
		["shape_poly.png", "Polygon — click to place points, Shift+click for curves, click the first point or double-click to close.", 2],
	]
	for d in sub_defs:
		var b = Button.new()
		b.toggle_mode = true
		b.group = sgrp
		b.focus_mode = Control.FOCUS_NONE
		b.hint_tooltip = d[1]
		var ic = _load_icon(_root + "icons/" + d[0])
		if ic != null:
			b.rect_min_size = Vector2(ic.get_width() + 10, ic.get_height() + 8)
			_icon_button_set_icon(b, ic)
		else:
			b.text = d[1].substr(0, 1)
		b.connect("toggled", self, "_on_shape_sub_toggled", [d[2]])
		sub_row.add_child(b)
		_shape_btns.append(b)
	_shape_btns[0].pressed = true
	align.add_child(_rm(sub_row))
	_bucket_opts = VBoxContainer.new()
	_bucket_opts.visible = false
	var lbl_sb = Label.new()
	lbl_sb.text = "Stopped by:"
	_bucket_opts.add_child(lbl_sb)
	var cb_row = HBoxContainer.new()
	_cb_walls = CheckBox.new()
	_cb_walls.text = "Walls"
	_cb_walls.pressed = true
	cb_row.add_child(_cb_walls)
	_cb_paths = CheckBox.new()
	_cb_paths.text = "Paths"
	_cb_paths.pressed = true
	cb_row.add_child(_cb_paths)
	_cb_patterns = CheckBox.new()
	_cb_patterns.text = "Patterns"
	_cb_patterns.pressed = false
	cb_row.add_child(_cb_patterns)
	_bucket_opts.add_child(cb_row)
	align.add_child(_rm(_bucket_opts))
	_tool_panel.EndSection()

	# ── Layer ──
	_tool_panel.BeginSection(false)
	align.add_child(_rm(_sep()))
	_hide_icon = _load_icon(_root + "icons/hide.png", 0.65)
	_eye_icon = _load_icon(_root + "icons/eye.png", 0.65)
	_blend_icons = [_load_icon(_root + "icons/blend_normal.png"), _load_icon(_root + "icons/blend_smooth.png"), _load_icon(_root + "icons/blend_hard.png")]
	_blend_mix_icon = _load_icon(_root + "icons/blend_mix.png")
	var all_row = HBoxContainer.new()
	var all_lbl = Label.new()
	all_lbl.text = "Terrain Layers"
	all_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	all_row.add_child(all_lbl)
	var add_btn = Button.new()
	add_btn.rect_min_size = Vector2(28, 27)
	var add_ic = _load_icon(_root + "icons/add.png", 0.65)
	if add_ic != null:
		add_btn.icon = add_ic
	else:
		add_btn.text = "+"
	add_btn.hint_tooltip = "Add a layer"
	add_btn.connect("pressed", self, "_on_add_layer")
	all_row.add_child(add_btn)
	var rm_btn = Button.new()
	rm_btn.rect_min_size = Vector2(28, 27)
	var rm_ic = _load_icon(_root + "icons/remove.png", 0.65)
	if rm_ic != null:
		rm_btn.icon = rm_ic
	else:
		rm_btn.text = "-"
	rm_btn.hint_tooltip = "Remove the selected layer"
	rm_btn.connect("pressed", self, "_on_remove_layer")
	all_row.add_child(rm_btn)
	_blend_all_btn = Button.new()
	_blend_all_btn.rect_min_size = Vector2(28, 27)
	_blend_all_btn.hint_tooltip = "Blending of ALL layers: cycles Mix / Smooth / Hard / Normal.\nMix restores each layer's own mode. New layers inherit the forced mode."
	_blend_all_btn.connect("pressed", self, "_on_blend_all_cycle")
	all_row.add_child(_blend_all_btn)
	_all_eye_btn = Button.new()
	_all_eye_btn.rect_min_size = Vector2(28, 27)
	_all_eye_btn.hint_tooltip = "Show / hide every layer of the level."
	_all_eye_btn.connect("pressed", self, "_on_all_visibility_pressed")
	all_row.add_child(_all_eye_btn)
	_header_pad = Control.new()
	_header_pad.rect_min_size = Vector2(0, 0)
	all_row.add_child(_header_pad)
	align.add_child(_rm(all_row))
	align.add_child(_rm(_sep()))
	_update_all_eye_button()
	_layer_group = ButtonGroup.new()
	var scroll = ScrollContainer.new()
	_layer_scroll = scroll
	scroll.rect_min_size = Vector2(0, max(LAYER_LIST_MIN_H, _layer_list_h))
	scroll.scroll_horizontal_enabled = false
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_layer_rows = VBoxContainer.new()
	_layer_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_layer_rows.add_constant_override("separation", 2)
	scroll.add_child(_layer_rows)
	align.add_child(_rm(scroll))
	# Horizontal drag strip under the list: resize it vertically.
	var vgrab = _mk_vgrab("Drag to resize the layer list", "_on_layer_list_grab_input")
	align.add_child(_rm(vgrab))
	align.add_child(_rm(_sep()))
	_props_top = VBoxContainer.new()
	align.add_child(_rm(_props_top))
	var row2 = HBoxContainer.new()
	var fill_btn = _mk_btn("Fill", "_on_fill")
	var fill_ic = _load_icon(_root + "icons/fill.png", 0.65)
	if fill_ic != null:
		fill_btn.icon = fill_ic
	row2.add_child(_framed(fill_btn))
	var clear_btn = _mk_btn("Clear", "_on_clear")
	var clear_ic = _load_icon(_root + "icons/clear.png", 0.65)
	if clear_ic != null:
		clear_btn.icon = clear_ic
	row2.add_child(_framed(clear_btn))
	# One row: [icon + "Procedural Generation" button] [cog].
	var ogrow = HBoxContainer.new()
	var ogb1 = _mk_btn("Procedural Generation", "_on_organic_fill")
	_og_gen_btn = ogb1
	ogb1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ogb1.align = Button.ALIGN_CENTER
	var ogic_t = _load_icon(_root + "icons/organic_generation.png")
	if ogic_t != null:
		ogb1.icon = ogic_t
	ogb1.hint_tooltip = "Fill the selection (layer, multi-selection or every layer of the selected group) with procedural coverage."
	ogrow.add_child(_framed(ogb1))
	var ocog = Button.new()
	ocog.toggle_mode = true
	var ocog_ic = _load_icon(_root + "icons/cog.png", 0.5)
	if ocog_ic != null:
		ocog.icon = ocog_ic
	else:
		ocog.text = "*"
	ocog.hint_tooltip = "Show / hide the organic generation settings."
	ocog.connect("toggled", self, "_on_organic_cog_toggled")
	ogrow.add_child(ocog)
	_organic_box = VBoxContainer.new()
	_organic_box.visible = false
	_og_scale_slider = _mk_slider(0.25, 4.0, 0.05, _organic_scale, "_on_organic_scale")
	_slider_resettable(_og_scale_slider, 1.0)
	_og_scale_slider.hint_tooltip = "Size of the organic blobs."
	_og_scale_spin = _mk_spin(0.25, 4.0, 0.05, _organic_scale, "_on_organic_scale_spin")
	var ogr1 = _labeled("Blob size", _og_scale_slider)
	ogr1.add_child(_og_scale_spin)
	ogr1.add_child(_reset_btn("_on_slider_reset", [_og_scale_slider, 1.0]))
	_organic_box.add_child(ogr1)
	_og_detail_slider = _mk_slider(0.0, 1.0, 0.01, _organic_detail, "_on_organic_detail")
	_slider_resettable(_og_detail_slider, 0.65)
	_og_detail_slider.hint_tooltip = "High-frequency detail carving the edges and the inside."
	_og_detail_spin = _mk_spin(0.0, 1.0, 0.01, _organic_detail, "_on_organic_detail_spin")
	var ogr2 = _labeled("Detail", _og_detail_slider)
	ogr2.add_child(_og_detail_spin)
	ogr2.add_child(_reset_btn("_on_slider_reset", [_og_detail_slider, 0.65]))
	_organic_box.add_child(ogr2)
	_og_cov_slider = _mk_slider(0, 100, 1, _organic_coverage, "_on_organic_coverage")
	_slider_resettable(_og_cov_slider, 55)
	_og_cov_slider.hint_tooltip = "Approximate percentage of the layer covered."
	_og_cov_spin = _mk_spin(0, 100, 1, _organic_coverage, "_on_organic_coverage_spin")
	var ogr3 = _labeled("Coverage %", _og_cov_slider)
	ogr3.add_child(_og_cov_spin)
	ogr3.add_child(_reset_btn("_on_slider_reset", [_og_cov_slider, 55]))
	_organic_box.add_child(ogr3)
	_og_post_slider = _mk_slider(0, 100, 1, 55, "_on_post_cov_slider")
	_og_post_slider.hint_tooltip = "Re-threshold the generated noise of the selected layer(s) at another coverage (same blobs, applied on release)."
	# Applied on release: through drag_ended when the engine build has it,
	# and through the slider's own mouse release otherwise.
	if _og_post_slider.has_signal("drag_ended"):
		_og_post_slider.connect("drag_ended", self, "_on_post_cov_drag_ended")
	_og_post_slider.connect("gui_input", self, "_on_post_cov_gui_input")
	_og_post_spin = _mk_spin(0, 100, 1, 55, "_on_post_cov_spin")
	_og_post_row = _labeled("Coverage %", _og_post_slider)
	_og_post_row.add_child(_og_post_spin)
	_og_post_row.visible = false
	_props_top.add_child(row2)
	_organic_ui = [_sep(), ogrow, _og_post_row, _organic_box]
	align.add_child(_rm(_sep()))
	_props_box = VBoxContainer.new()
	align.add_child(_rm(_props_box))
	_z_slider = _mk_slider(-600, 1200, 10, -450, "_on_z_changed")
	_z_spin = _mk_spin(-600, 1200, 1, -450, "_on_z_changed")
	_z_spin.rect_min_size = Vector2(56, 0)
	_z_row = _labeled("Layer", _z_slider)
	var zrow = _z_row
	zrow.add_child(_z_spin)
	var prev_b = Button.new()
	prev_b.text = "<"
	prev_b.rect_min_size = Vector2(24, 0)
	prev_b.hint_tooltip = "Jump to the previous layer defined in the map (Terrain, Caves, User Layer 1, ...)."
	prev_b.connect("pressed", self, "_on_jump_layer", [-1])
	zrow.add_child(prev_b)
	var next_b = Button.new()
	next_b.text = ">"
	next_b.rect_min_size = Vector2(24, 0)
	next_b.hint_tooltip = "Jump to the next layer defined in the map."
	next_b.connect("pressed", self, "_on_jump_layer", [1])
	zrow.add_child(next_b)
	_props_box.add_child(zrow)
	_opacity_slider = _mk_slider(0, 1, 0.01, 1.0, "_on_opacity_changed")
	_slider_resettable(_opacity_slider, 1.0)
	# (reset button added on the row below)
	_opacity_spin = _mk_spin(0, 100, 1, 100, "_on_opacity_spin_changed")
	_opacity_spin.suffix = "%"
	var orow = _labeled("Opacity", _opacity_slider)
	orow.add_child(_opacity_spin)
	orow.add_child(_reset_btn("_on_slider_reset", [_opacity_slider, 1.0]))
	_props_box.add_child(orow)
	_smooth_row = HBoxContainer.new()
	var smlbl = Label.new()
	smlbl.text = "Smoothness"
	smlbl.rect_min_size = Vector2(84, 0)
	_smooth_row.add_child(smlbl)
	_smooth_slider = _mk_slider(64, 2048, 32, 1536, "_on_smoothness_changed")
	_slider_resettable(_smooth_slider, 1536)
	_smooth_row.add_child(_smooth_slider)
	_smooth_spin = _mk_spin(64, 2048, 32, 1536, "_on_smoothness_spin")
	_smooth_row.add_child(_smooth_spin)
	_smooth_link_btn = Button.new()
	_smooth_link_btn.toggle_mode = true
	_smooth_link_btn.pressed = _smooth_linked
	var link_ic = _load_icon(_root + "icons/link.png", 0.5)
	if link_ic != null:
		_smooth_link_btn.icon = link_ic
	else:
		_smooth_link_btn.text = "∞"
	_smooth_link_btn.hint_tooltip = "Link: apply this smoothness to every layer of the level."
	_smooth_link_btn.connect("toggled", self, "_on_smooth_link_toggled")
	_smooth_row.add_child(_smooth_link_btn)
	_props_box.add_child(_smooth_row)
	for c in _organic_ui:
		_props_box.add_child(c)
	_props_box.add_child(_sep())
	_clip_check = CheckButton.new()
	_clip_check.text = "Clipping Mask"
	_clip_check.align = Button.ALIGN_CENTER
	var cpic_t = _load_icon(_root + "icons/clipping.png")
	if cpic_t != null:
		_clip_check.icon = cpic_t
	_clip_check.hint_tooltip = "The slot only shows where the target objects are drawn (Photoshop-style clipping mask)."
	_clip_check.connect("toggled", self, "_on_clip_check_toggled")
	_props_box.add_child(_clip_check)
	_clip_box = VBoxContainer.new()
	_clip_box.visible = false
	var cprow = HBoxContainer.new()
	_clip_mode_opt = OptionButton.new()
	# Item ids = internal clip codes; display order: all / same / single.
	_clip_mode_opt.add_item("All Objects Below", 2)
	_clip_mode_opt.add_item("All Objects Above", 4)
	_clip_mode_opt.add_item("Same Layer", 1)
	_clip_mode_opt.add_item("Single Object", 3)
	_clip_mode_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_clip_mode_opt.connect("item_selected", self, "_on_clip_mode_selected")
	cprow.add_child(_clip_mode_opt)
	_clip_pick_btn = Button.new()
	_clip_pick_btn.text = "Select Object"
	_clip_pick_btn.toggle_mode = true
	_clip_pick_btn.hint_tooltip = "Click an object on the map: the slot clips to that object's layer, and moves to that layer's z."
	_clip_pick_btn.connect("toggled", self, "_on_clip_pick_toggled")
	cprow.add_child(_clip_pick_btn)
	_clip_box.add_child(cprow)
	_props_box.add_child(_clip_box)
	_props_box.add_child(_sep())
	_light_check = CheckButton.new()
	_light_check.text = "Light Painting"
	_light_check.align = Button.ALIGN_CENTER
	var li_ic = _load_icon(_root + "icons/light.png")
	if li_ic != null:
		_light_check.icon = li_ic
	_light_check.hint_tooltip = "The slot becomes a painted LIGHT: additive light-pass compositing (like the Light tool), darkness reacts to it."
	_light_check.connect("toggled", self, "_on_light_paint_toggled")
	_props_box.add_child(_light_check)
	_light_box = VBoxContainer.new()
	_light_box.visible = false
	_light_slider = _mk_slider(0.0, 10.0, 0.05, 1.0, "_on_light_intensity_changed")
	_slider_resettable(_light_slider, 1.0)
	_light_spin = _mk_spin(0.0, 10.0, 0.05, 1.0, "_on_light_intensity_spin")
	var lirow2 = _labeled("Intensity", _light_slider)
	lirow2.add_child(_light_spin)
	lirow2.add_child(_reset_btn("_on_slider_reset", [_light_slider, 1.0]))
	_light_box.add_child(lirow2)
	_props_box.add_child(_light_box)
	_props_box.add_child(_sep())
	_cs.build(_props_box)
	_cs.set_open(_color_open)
	_props_box.add_child(_sep())
	_transform_toggle = CheckButton.new()
	_transform_toggle.text = "Transform"
	_transform_toggle.align = Button.ALIGN_CENTER
	var tf_ic = _load_icon(_root + "icons/transform.png")
	if tf_ic != null:
		_transform_toggle.icon = tf_ic
	_transform_toggle.pressed = _transform_open
	_transform_toggle.connect("toggled", self, "_on_transform_toggle")
	_attach_chevron(_transform_toggle, _transform_open)
	_props_box.add_child(_transform_toggle)
	_transform_box = VBoxContainer.new()
	_transform_box.visible = _transform_open
	_props_box.add_child(_transform_box)
	_transform_box.add_child(_cs.param_row("Rotation", "tex_rot", -180, 180, 1, 0))
	_transform_box.add_child(_cs.param_row("Scale", "tex_scale", 0.25, 4, 0.01, 1))
	_transform_box.add_child(_cs.param_row("Offset X", "tex_off_x", -512, 512, 1, 0))
	_transform_box.add_child(_cs.param_row("Offset Y", "tex_off_y", -512, 512, 1, 0))
	_props_box.add_child(_sep())
	_hide_vanilla_check = CheckButton.new()
	_hide_vanilla_check.text = "Hide Vanilla Terrain"
	_hide_vanilla_check.align = Button.ALIGN_CENTER
	_hide_vanilla_check.hint_tooltip = "Hides Dungeondraft's own terrain on every level, plus its Terrain tool (saved with the map)."
	_hide_vanilla_check.connect("toggled", self, "_on_hide_vanilla_toggled")
	_props_box.add_child(_hide_vanilla_check)
	_tool_panel.EndSection()

	# ── Square size (brush settings live in the right panel) ──
	_tool_panel.BeginSection(false)
	var sq_sep = _rm(_sep())
	align.add_child(sq_sep)
	_square_rows.append(sq_sep)
	_square_slider = _mk_slider(0.25, 8, 0.25, _square_cells, "_on_square_size_changed")
	_slider_resettable(_square_slider, 1.0)
	_square_spin = _mk_spin(0.25, 32, 0.25, _square_cells, "_on_square_size_changed")
	var size_row_left = _labeled("Size", _square_slider)
	size_row_left.add_child(_square_spin)
	size_row_left = _rm(size_row_left)
	align.add_child(size_row_left)
	_square_rows.append(size_row_left)
	_tool_panel.EndSection()

	# ── Presets / copy-paste ──
	_tool_panel.BeginSection(false)
	align.add_child(_rm(_sep()))
	_build_presets_ui(align)
	_tool_panel.EndSection()

	# ── Bottom: notes ──
	_tool_panel.BeginSection(false)
	align.add_child(_rm(_sep()))
	_tool_panel.CreateNote("Left click: paint. Right click or Alt+click: erase.")
	_tool_panel.EndSection()

	_build_right_panel()
	_sync_props()


# ── Right panel: brush library (sits in Editor/VPartition/Panels like DD's own
# ObjectLibraryPanel, so it takes width from the map instead of overlapping it)
func _build_right_panel() -> void:
	var host = _find_right_host()
	if host == null:
		printerr("[BetterTerrain] Right panel host not found; brushes unavailable")
		return
	_right_panel = PanelContainer.new()
	_right_panel.name = "BetterTerrainBrushPanel"
	var sb = StyleBoxFlat.new()
	sb.set_bg_color(Color(0, 0, 0, 0.4))
	_right_panel.add_stylebox_override("panel", sb)
	_right_panel.visible = false
	# 3 columns of 90 px + inner margins (10 + 6) + list padding/scrollbar.
	_right_min_w = 316 * max(OS.get_screen_dpi() / 96.0, 1.0)
	_apply_right_width()
	host.add_child(_right_panel)
	host.move_child(_right_panel, host.get_child_count() - 1)
	var prow = HBoxContainer.new()
	prow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_right_panel.add_child(prow)
	# Thin drag strip on the left edge, same trick as the native library panels.
	var grabber = VBoxContainer.new()
	grabber.rect_min_size = Vector2(5, 0)
	grabber.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	grabber.hint_tooltip = "Drag to resize"
	grabber.connect("gui_input", self, "_on_right_grabber_input")
	prow.add_child(grabber)
	var margin = MarginContainer.new()
	margin.add_constant_override("margin_left", 5)
	margin.add_constant_override("margin_right", 6)
	margin.add_constant_override("margin_top", 6)
	margin.add_constant_override("margin_bottom", 6)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	prow.add_child(margin)
	# The tab content lives in a ScrollContainer: it still fills the panel by
	# default, but once the brush library is stretched taller than the panel
	# (grip under the list) the whole content scrolls instead of clipping.
	_rp_scroll = ScrollContainer.new()
	_rp_scroll.scroll_horizontal_enabled = false
	_rp_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rp_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(_rp_scroll)
	var box = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_constant_override("separation", 6)
	_rp_scroll.add_child(box)
	var tab_row = HBoxContainer.new()
	_rp_tab_row = tab_row
	var tgrp = ButtonGroup.new()
	_rp_tab_btns = []
	for i in range(2):
		var tb = Button.new()
		tb.text = ["Textures", "Brushes"][i]
		tb.toggle_mode = true
		tb.group = tgrp
		tb.focus_mode = Control.FOCUS_NONE
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # 50% each
		tb.connect("toggled", self, "_on_rp_tab_toggled", [i])
		tab_row.add_child(tb)
		_rp_tab_btns.append(tb)
	box.add_child(tab_row)
	_tab_textures = VBoxContainer.new()
	_tab_textures.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab_textures.add_constant_override("separation", 6)
	box.add_child(_tab_textures)
	_build_textures_tab(_tab_textures)
	_tab_brushes = VBoxContainer.new()
	_tab_brushes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab_brushes.add_constant_override("separation", 6)
	box.add_child(_tab_brushes)
	box = _tab_brushes   # everything below belongs to the Brushes tab
	_rp_tab_btns[clamp(_rp_tab, 0, 1)].pressed = true
	_tab_textures.visible = _rp_tab == 0
	_tab_brushes.visible = _rp_tab == 1
	_brush_search = LineEdit.new()
	_brush_search.placeholder_text = "Search brushes..."
	_brush_search.connect("text_changed", self, "_on_brush_search")
	box.add_child(_brush_search)
	# Brush favorites / hidden are the tool's own data: the view button is
	# always there (the Favorites mod only lends its icons / badge).
	_brush_mode_btn = Button.new()
	_brush_mode_btn.hint_tooltip = "Cycle brush view: All / Favorites / Hidden"
	_brush_mode_btn.connect("pressed", self, "_on_brush_mode_cycle")
	box.add_child(_brush_mode_btn)
	_brush_count_lbl = _mk_count_label()
	box.add_child(_brush_count_lbl)
	_update_brush_mode_button()
	_brush_list = ItemList.new()
	_grid_list_setup(_brush_list)
	_brush_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_brush_list.rect_min_size = Vector2(0, _brush_list_h)
	_brush_list.connect("item_selected", self, "_on_brush_selected")
	_brush_list.connect("item_rmb_selected", self, "_on_brush_rmb")
	_brush_list.allow_rmb_select = true
	box.add_child(_brush_list)
	box.add_child(_mk_vgrab("Drag to resize the brush library (double-click to reset)", "_on_brush_list_grab_input"))
	box.add_child(_sep())
	_size_slider = _mk_slider(0, 1, 0.01, _slider_from_size(_brush_size), "_on_size_changed")
	_slider_resettable(_size_slider, 0.5)
	_size_spin = _mk_spin(SIZE_MIN, SIZE_MAX, 1, round(_brush_size), "_on_size_spin")
	var srow = _labeled("Size", _size_slider)
	srow.add_child(_size_spin)
	srow.add_child(_reset_btn("_on_slider_reset", [_size_slider, 0.5]))
	box.add_child(srow)
	_hardness_slider = _mk_slider(0, 1, 0.01, _brush_hardness, "_on_hardness_changed")
	_slider_resettable(_hardness_slider, 0.5)
	_hard_spin = _mk_spin(0, 1, 0.01, _brush_hardness, "_on_hardness_spin")
	var hrow = _labeled("Hardness", _hardness_slider)
	hrow.add_child(_hard_spin)
	hrow.add_child(_reset_btn("_on_slider_reset", [_hardness_slider, 0.5]))
	box.add_child(hrow)
	_round_slider = _mk_slider(0, 1, 0.01, _brush_roundness, "_on_roundness_changed")
	_slider_resettable(_round_slider, 1.0)
	_round_slider.hint_tooltip = "Shape of the brush window: 0 = square, 1 = round, softened corners in between."
	_round_spin = _mk_spin(0, 1, 0.01, _brush_roundness, "_on_roundness_spin")
	var rndrow = _labeled("Roundness", _round_slider)
	rndrow.add_child(_round_spin)
	rndrow.add_child(_reset_btn("_on_slider_reset", [_round_slider, 1.0]))
	box.add_child(rndrow)
	_flow_slider = _mk_slider(0, 1, 0.01, _brush_flow, "_on_flow_changed")
	_slider_resettable(_flow_slider, 0.7)
	_flow_spin = _mk_spin(0, 1, 0.01, _brush_flow, "_on_flow_spin")
	var frow = _labeled("Intensity", _flow_slider)
	frow.add_child(_flow_spin)
	frow.add_child(_reset_btn("_on_slider_reset", [_flow_slider, 0.7]))
	box.add_child(frow)
	_mode_option = OptionButton.new()
	_mode_option.add_item("Additive", MODE_ADDITIVE)
	_mode_option.add_item("Per stroke", MODE_PER_STROKE)
	_mode_option.add_item("Non-additive", MODE_NON_ADDITIVE)
	_mode_option.set_item_tooltip(0, "Every stamp adds paint, even when passing again over the same spot during one stroke.")
	_mode_option.set_item_tooltip(1, "Within one stroke a pixel never exceeds the brush weight; lift the mouse and click again to add more.")
	_mode_option.set_item_tooltip(2, "A pixel never exceeds the brush weight, whatever the number of strokes (max compositing).")
	_mode_option.selected = _stroke_mode
	_mode_option.connect("item_selected", self, "_on_mode_selected")
	box.add_child(_labeled("Stroke", _mode_option))
	_rot_slider = _mk_slider(0, 360, 1, _brush_rot_fixed, "_on_rot_slider_changed")
	_slider_resettable(_rot_slider, 0.0)
	_rot_spin = _mk_spin(0, 360, 1, _brush_rot_fixed, "_on_rot_spin")
	var rrow = _labeled("Rotation", _rot_slider)
	rrow.add_child(_rot_spin)
	_rot_check = _mk_random_btn(_brush_random_rot, "_on_rot_toggled", "Random rotation at every stamp (the slider is ignored).")
	rrow.add_child(_rot_check)
	rrow.add_child(_reset_btn("_on_slider_reset", [_rot_slider, 0.0]))
	box.add_child(rrow)
	_ratio_slider = _mk_slider(0.5, 2.0, 0.01, _brush_ratio_fixed, "_on_ratio_slider_changed")
	_slider_resettable(_ratio_slider, 1.0)
	_ratio_spin = _mk_spin(0.5, 2.0, 0.01, _brush_ratio_fixed, "_on_ratio_spin")
	var rarow = _labeled("Ratio", _ratio_slider)
	rarow.add_child(_ratio_spin)
	_ratio_check = _mk_random_btn(_brush_random_ratio, "_on_ratio_toggled", "Random ratio at every stamp (the slider is ignored).")
	rarow.add_child(_ratio_check)
	rarow.add_child(_reset_btn("_on_slider_reset", [_ratio_slider, 1.0]))
	box.add_child(rarow)
	_continuous_check = CheckButton.new()
	_continuous_check.text = "Continuous paint"
	_continuous_check.hint_tooltip = "Keep stamping every %d frames while the button is held, even if the mouse does not move." % CONTINUOUS_INTERVAL
	_continuous_check.pressed = _brush_continuous
	_continuous_check.connect("toggled", self, "_on_continuous_toggled")
	box.add_child(_continuous_check)
	box.add_child(_sep())
	_res_option = OptionButton.new()
	for i in range(RES_OPTIONS.size()):
		_res_option.add_item(RES_LABELS[i])
		_res_option.set_item_tooltip(i, "%d map px per mask px" % RES_OPTIONS[i])
	_res_option.selected = max(0, RES_OPTIONS.find(DEFAULT_RES))
	_res_option.hint_tooltip = "Mask resolution of the selected layer."
	_res_option.connect("item_selected", self, "_on_res_changed")
	box.add_child(_labeled("Quality", _res_option))
	_lib_size_row = HBoxContainer.new()
	var lirow = _lib_size_row
	var lilbl = Label.new()
	lilbl.text = "Library icon size"
	lirow.add_child(lilbl)
	_lib_size_slider = _mk_slider(32, 320, 2, _lib_icon_size, "_on_lib_icon_size_changed")
	_slider_resettable(_lib_size_slider, 64)
	lirow.add_child(_lib_size_slider)
	_lib_size_spin = _mk_spin(32, 320, 2, _lib_icon_size, "_on_lib_icon_size_spin")
	lirow.add_child(_lib_size_spin)
	box.add_child(lirow)
	# When the _Lib mod-config page manages the size, hide the in-panel row.
	_lib_size_row.visible = not Engine.has_meta(LIB_SIZE_META)
	box.add_child(_sep())
	var lights = CheckButton.new()
	lights.text = "Display light shapes"
	lights.hint_tooltip = "Also list the Light tool's textures (currently available packs) as brushes."
	lights.pressed = _show_light_brushes
	lights.connect("toggled", self, "_on_light_brushes_toggled")
	box.add_child(lights)
	var note = Label.new()
	note.text = "Custom brushes: drop grayscale PNGs in the User Folder --> BetterTerrainTool/brushes"
	note.autowrap = true
	note.modulate = Color(1, 1, 1, 0.6)
	var sf = _scaled_font(note.get_font("font"), 0.75)
	if sf != null:
		note.add_font_override("font", sf)
	box.add_child(note)
	_populate_brush_list()


# DD's PanelHeadingFont.tres is a shared resource: never resize the cached
# instance (it would grow every panel heading). Duplicate it and derive the
# size from the theme's label font so it tracks DD's UI scale.
func _heading_font():
	var ref = 0
	var theme = _g.get("Theme")
	if theme != null and theme is Theme and theme.has_font("font", "Label"):
		var lf = theme.get_font("font", "Label")
		if lf != null and lf.get("size") != null:
			ref = int(lf.size)
	if ref <= 0:
		ref = 16
	var f = load("res://ui/fonts/PanelHeadingFont.tres")
	if f == null:
		return null
	f = f.duplicate()
	if f.get("size") != null:
		f.size = int(round(ref * 1.6))
	return f


func _scaled_font(base, scale: float):
	if base == null or not (base is DynamicFont):
		return null
	var f = base.duplicate()
	f.size = max(8, int(round(int(base.size) * scale)))
	return f


func _on_light_brushes_toggled(on: bool) -> void:
	_show_light_brushes = on
	_save_brush_prefs()
	_scan_brushes()
	_populate_brush_list()


func _light_texture_paths() -> Array:
	var out := []
	var seen := {}
	# 1) the Light tool's library (covers asset packs)
	var tools = _g.Editor.get("Tools")
	if tools is Dictionary:
		var lt = tools.get("LightTool")
		if lt != null and is_instance_valid(lt):
			var controls = lt.get("Controls")
			if controls is Dictionary:
				var lst = controls.get("Texture")
				if lst != null and is_instance_valid(lst) and lst is ItemList:
					for i in range(lst.get_item_count()):
						var m = lst.get_item_metadata(i)
						if m is String and m != "" and not seen.has(m):
							seen[m] = true
							out.append(m)
	# 2) fallback: DD's built-in folder
	if out.empty():
		var d = Directory.new()
		if d.open("res://textures/lights") == OK:
			d.list_dir_begin(true, true)
			var f = d.get_next()
			while f != "":
				if f.get_extension().to_lower() == "png":
					out.append("res://textures/lights/" + f)
				f = d.get_next()
			d.list_dir_end()
	return out


func _on_brush_search(_text: String) -> void:
	_populate_brush_list()


func _find_right_host():
	var ed = _g.Editor
	if ed == null:
		return null
	var node = null
	var olp = ed.get("ObjectLibraryPanel")
	if olp != null and is_instance_valid(olp):
		node = olp.get_parent()
	if node == null:
		node = ed.get_node_or_null("VPartition/Panels/HSplit")
	# HSplit only lays out two children: climb to the plain box (Panels).
	var guard = 3
	while node != null and is_instance_valid(node) and node is SplitContainer and guard > 0:
		node = node.get_parent()
		guard -= 1
	if node == null or not is_instance_valid(node):
		node = ed.get_node_or_null("VPartition/Panels")
	return node


func _set_right_panel_visible(on: bool) -> void:
	if _right_panel != null and is_instance_valid(_right_panel):
		_right_panel.visible = on


func _sep() -> HSeparator:
	var h = HSeparator.new()
	h.rect_min_size = Vector2(0, 12)
	return h


# Right margin so the left panel's controls don't touch the panel edge.
func _rm(ctrl: Control) -> MarginContainer:
	var mc = MarginContainer.new()
	mc.add_constant_override("margin_left", 0)
	mc.add_constant_override("margin_top", 0)
	mc.add_constant_override("margin_bottom", 0)
	mc.add_constant_override("margin_right", 10)
	mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mc.add_child(ctrl)
	return mc


# 28 px thumbnail for dropdown menus (DD's thumbnails are too big for a popup).
func _small_thumb(path):
	if _small_thumbs.has(path):
		return _small_thumbs[path]
	var t = _thumb_for(path)
	var st = null
	if t != null and t is Texture:
		var img = t.get_data()
		if img != null:
			img = img.duplicate()
			img.resize(28, 28, Image.INTERPOLATE_BILINEAR)
			st = ImageTexture.new()
			st.create_from_image(img, Texture.FLAG_FILTER)
	if st != null:
		_small_thumbs[path] = st
	return st


# Wraps a control in a subtle 1 px translucent grey frame.
func _framed(ctrl: Control) -> PanelContainer:
	var pc = PanelContainer.new()
	var sb = StyleBoxFlat.new()
	sb.draw_center = false
	sb.border_color = Color(0.5, 0.5, 0.5, 0.5)
	sb.set_border_width_all(1)
	sb.content_margin_left = 1
	sb.content_margin_right = 1
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	pc.add_stylebox_override("panel", sb)
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_child(ctrl)
	return pc


func _mk_btn(text: String, handler: String, binds := []) -> Button:
	var b = Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.connect("pressed", self, handler, binds)
	return b


func _mk_slider(mn, mx, st, val, handler: String) -> HSlider:
	var s = HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = st
	s.value = val
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.connect("value_changed", self, handler)
	return s


func _slider_resettable(sl: Range, def) -> void:
	sl.hint_tooltip = "Right click: reset"
	sl.connect("gui_input", self, "_on_slider_reset_input", [sl, def])


func _on_slider_reset_input(event, sl, def) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == BUTTON_RIGHT:
		sl.value = def


var _reset_icon = null

func _reset_btn(handler: String, binds := []) -> Button:
	var b = Button.new()
	if _reset_icon == null:
		_reset_icon = _load_icon(_root + "icons/reset.png", 0.5)
	if _reset_icon != null:
		b.icon = _reset_icon
	else:
		b.text = "R"
	b.hint_tooltip = "Reset"
	b.connect("pressed", self, handler, binds)
	return b


func _on_slider_reset(sl, def) -> void:
	sl.value = def


func _refresh_row_thumb(layer: Dictionary) -> void:
	var r = _row_by_uid.get(int(layer["uid"]))
	if r != null and r.has("thumb") and is_instance_valid(r["thumb"]):
		r["thumb"].icon = _row_thumb(layer)


func _on_smoothness_changed(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_smooth_spin.value = v
	_ui_syncing = false
	_apply_smoothness(v)


func _on_smoothness_spin(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_smooth_slider.value = v
	_ui_syncing = false
	_apply_smoothness(v)


func _apply_smoothness(v: float) -> void:
	var gsm = _sel_grp()
	if gsm != null:
		# Group selected: Smoothness shapes the GROUP's smooth edge.
		_grp_runtime(gsm)
		gsm["smoothness"] = v
		if int(gsm["blend"]) == 1:
			_blur_full_build(gsm)
			_grp_push_params(gsm)
		_persist()
		return
	if _smooth_linked:
		for l in _cur_layers():
			l["smoothness"] = v
			if int(l["blend"]) == 1:
				_blur_full_build(l)
		_persist()
	else:
		for layer in _edit_targets():
			layer["smoothness"] = v
			_apply_color_params(layer, layer["mat"])
		_persist()


func _on_smooth_link_toggled(on: bool) -> void:
	_smooth_linked = on
	_save_brush_prefs()
	if on and _selected_layer() != null:
		_apply_smoothness(float(_selected_layer()["smoothness"]))


func _on_hide_vanilla_toggled(on: bool) -> void:
	if _ui_syncing:
		return
	_hide_vanilla = on
	_apply_hide_vanilla()
	_schedule_persist()


# Hide / show DD's own terrain (every level) and its Terrain toolbar button.
# The terrain is both hidden AND disabled (the Terrain tool's Enabled
# setting), like unchecking Enable in the vanilla tool.
func _apply_hide_vanilla() -> void:
	if _g == null or _g.World == null or not is_instance_valid(_g.World):
		return
	var seen := []
	var levels = _g.World.get("Levels")
	if levels != null:
		for lvl in levels:
			seen.append(lvl)
	for lid in _levels.keys():
		var e = _levels[lid]
		if e.get("level") != null and not seen.has(e["level"]):
			seen.append(e["level"])
	var curl = _current_level()
	if curl != null and not seen.has(curl):
		seen.append(curl)
	for lvl in seen:
		if lvl == null or not is_instance_valid(lvl):
			continue
		var terrain = lvl.get("Terrain")
		if terrain != null and is_instance_valid(terrain):
			terrain.visible = not _hide_vanilla
			terrain.set("Enabled", not _hide_vanilla)
	var toolset = _g.Editor.Toolset if _g.Editor != null else null
	if toolset != null:
		var toolbars = toolset.get("Toolbars")
		if toolbars is Dictionary and toolbars.has(TOOL_CATEGORY):
			var btn = _find_toolbar_button(toolbars[TOOL_CATEGORY], "TerrainBrush")
			if btn != null and is_instance_valid(btn):
				btn.visible = not _hide_vanilla


# Replaces the CheckButton ON/OFF switch with a down.png chevron docked at
# the right edge (flipped upward when the section is open).
func _attach_chevron(btn: Button, open: bool) -> void:
	var ch = TextureRect.new()
	ch.name = "chev"
	var ic = _load_icon(_root + "icons/down.png", 0.6)
	if ic != null:
		ch.texture = ic
	ch.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	ch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ch.anchor_left = 1.0
	ch.anchor_right = 1.0
	ch.anchor_top = 0.0
	ch.anchor_bottom = 1.0
	ch.margin_left = -30
	ch.margin_right = -6
	ch.flip_v = open
	btn.add_child(ch)
	# Hide the theme's switch graphics: keep only icon + text + chevron.
	for st in ["on", "off", "on_disabled", "off_disabled"]:
		btn.add_icon_override(st, ImageTexture.new())


func _on_transform_toggle(on: bool) -> void:
	var chv = _transform_toggle.get_node_or_null("chev")
	if chv != null:
		chv.flip_v = on
	_transform_open = on
	if _transform_box != null and is_instance_valid(_transform_box):
		_transform_box.visible = on
	_save_brush_prefs()


# ── custom slider drawing / input ────────────────────────────────────────────
# "in": three handles (black, gamma, white). The gamma handle sits at the
# value that maps to 0.5 (t = 0.5^gamma), like Photoshop.
# "out": two handles (output black / white).

func _mk_spin(mn, mx, st, val, handler: String) -> SpinBox:
	var sp = SpinBox.new()
	sp.min_value = mn
	sp.max_value = mx
	sp.step = st
	sp.value = val
	sp.rect_min_size = Vector2(64, 0)
	sp.connect("value_changed", self, handler)
	return sp


func _labeled(text: String, ctrl: Control) -> HBoxContainer:
	var row = HBoxContainer.new()
	var l = Label.new()
	l.text = text
	l.rect_min_size = Vector2(84, 0)
	row.add_child(l)
	ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ctrl)
	return row


func _refresh_layer_list() -> void:
	var _scroll_keep = 0
	if _layer_scroll != null and is_instance_valid(_layer_scroll):
		_scroll_keep = _layer_scroll.scroll_vertical
	if _layer_rows == null or not is_instance_valid(_layer_rows):
		return
	_ensure_catalog()   # thumbnails (may run before the tool is first enabled)
	for c in _layer_rows.get_children():
		_layer_rows.remove_child(c)
		c.queue_free()
	_row_by_uid = {}
	_grp_row_btn = {}
	var layers = _cur_layers().duplicate()
	layers.sort_custom(self, "_sort_by_z_asc")
	if _sel_group < 0 and _selected_layer() == null and not layers.empty():
		_sel_uid = layers[0]["uid"]
	var groups_done := {}
	var rh = _row_h()
	for layer in layers:
		var uid = int(layer["uid"])
		var lg = _group_of(uid)
		if lg != null and not groups_done.has(int(lg["uid"])):
			groups_done[int(lg["uid"])] = true
			_add_group_header_row(lg)
		if lg != null and not bool(lg["open"]):
			continue   # folded group: member rows hidden
		var row = HBoxContainer.new()
		if lg != null:
			var ind = Control.new()
			ind.rect_min_size = Vector2(14, 0)
			row.add_child(ind)
		if int(layer.get("clip", 0)) > 0:
			if _clip_icon_layer == null:
				_clip_icon_layer = _load_icon(_root + "icons/clipping_layer.png")
			if _clip_icon_all == null:
				_clip_icon_all = _load_icon(_root + "icons/clipping_all.png")
			if _clip_icon_single == null:
				_clip_icon_single = _load_icon(_root + "icons/clipping_single.png")
			if _clip_icon_above == null:
				_clip_icon_above = _load_icon(_root + "icons/clipping_above.png")
			var cic = TextureRect.new()
			match int(layer["clip"]):
				2:
					cic.texture = _clip_icon_all
				4:
					cic.texture = _clip_icon_above
				3:
					cic.texture = _clip_icon_single
				_:
					cic.texture = _clip_icon_layer
			cic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
			cic.rect_min_size = Vector2(20, rh)
			match int(layer["clip"]):
				1:
					cic.hint_tooltip = "Clipped to the same layer"
				2:
					cic.hint_tooltip = "Clipped to all objects below"
				4:
					cic.hint_tooltip = "Clipped to all objects above"
				3:
					cic.hint_tooltip = "Clipped to a single object"
			row.add_child(cic)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var thumb = _mk_dnd_button(uid)
		thumb.icon = _row_thumb(layer)
		thumb.expand_icon = true
		# No stylebox padding: the preview fills the whole 56x56 button, so the
		# only space left between two slots is the rows' 2 px separation.
		for st in ["normal", "hover", "pressed", "focus", "disabled"]:
			thumb.add_stylebox_override(st, StyleBoxEmpty.new())
		thumb.rect_min_size = Vector2(rh, rh)
		thumb.hint_tooltip = "Change this layer's texture"
		thumb.connect("pressed", self, "_on_row_thumb_pressed", [uid])
		row.add_child(thumb)
		var btn = _mk_dnd_button(uid)
		btn.toggle_mode = true
		btn.group = _layer_group
		btn.flat = false
		btn.align = Button.ALIGN_LEFT
		btn.clip_text = true
		btn.rect_min_size = Vector2(0, rh)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.text = " " + _layer_label(layer)
		btn.pressed = uid == _sel_uid
		if _sel_multi.has(uid) and uid != _sel_uid:
			# The ButtonGroup only allows one "pressed" row: secondary
			# selections borrow the pressed stylebox so they read the same.
			btn.add_stylebox_override("normal", btn.get_stylebox("pressed"))
			btn.add_stylebox_override("hover", btn.get_stylebox("pressed"))
		btn.connect("pressed", self, "_on_layer_row_pressed", [uid])
		btn.connect("gui_input", self, "_on_row_btn_gui_input", [uid])
		row.add_child(btn)
		var bicon = _mk_dnd_button(uid)
		var bmode = int(layer["blend"])
		if bmode >= 0 and bmode < _blend_icons.size() and _blend_icons[bmode] != null:
			bicon.icon = _blend_icons[bmode]
		else:
			bicon.text = ["N", "S", "H"][bmode]
		bicon.hint_tooltip = "Blending: " + ["Normal", "Smooth", "Hard"][bmode] + " (click to cycle)"
		bicon.rect_min_size = Vector2(28, rh)
		bicon.expand_icon = false
		if _compact_rows:
			_compact_icon_button(bicon, rh)
		bicon.connect("pressed", self, "_on_row_blend_pressed", [uid])
		row.add_child(bicon)
		var hide = _mk_dnd_button(uid)
		hide.toggle_mode = true
		hide.pressed = not bool(layer["visible"])
		hide.icon = _hide_icon if hide.pressed else _eye_icon
		hide.hint_tooltip = "Hide / show this layer"
		hide.rect_min_size = Vector2(28, rh)
		if _compact_rows:
			_compact_icon_button(hide, rh)
		hide.connect("toggled", self, "_on_layer_hide_toggled", [uid])
		row.add_child(hide)
		row.modulate = Color(1, 1, 1, 1.0 if layer["visible"] else 0.5)
		_layer_rows.add_child(row)
		_row_by_uid[uid] = {"btn": btn, "hide": hide, "row": row, "thumb": thumb}
	if _sel_uid != _scroll_last_sel:
		_scroll_last_sel = _sel_uid
		_scroll_to_sel = 2   # layout is ready a frame later
	else:
		# Rebuilding empties the ScrollContainer for a frame, which clamps the
		# scroll back to 0: restore the previous position instead of jumping.
		_scroll_restore_v = _scroll_keep
		_scroll_restore = 2
	_update_blend_all_label()
	_clip_refresh_all(_cur_entry())
	_groups_sync_shaders(_cur_entry())
	_sync_props()


func _on_right_grabber_input(event) -> void:
	if _right_panel == null or not is_instance_valid(_right_panel):
		return
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT and not event.pressed:
			_save_brush_prefs()
		return
	if not (event is InputEventMouseMotion):
		return
	if not Input.is_mouse_button_pressed(BUTTON_LEFT):
		return
	var local = _right_panel.get_local_mouse_position()
	_panel_w_right = max(_right_panel.rect_min_size.x - local.x - _rp_sb_extra, _right_min_w)
	_apply_right_width()


# Right panel width = the user's width, widened by the panel scrollbar when
# that one is showing (so the grid keeps all its columns).
func _apply_right_width() -> void:
	if _right_panel == null or not is_instance_valid(_right_panel):
		return
	_right_panel.rect_min_size = Vector2(max(_right_min_w, _panel_w_right) + _rp_sb_extra, 0)


func _tick_right_scrollbar() -> void:
	if _rp_scroll == null or not is_instance_valid(_rp_scroll):
		return
	var sb = _rp_scroll.get_v_scrollbar()
	var want = sb.rect_size.x if (sb != null and sb.visible) else 0.0
	if abs(want - _rp_sb_extra) > 0.5:
		_rp_sb_extra = want
		_apply_right_width()


# Horizontal drag strip (thin centred line) resizing the control above it.
func _mk_vgrab(tip: String, handler: String) -> HBoxContainer:
	var vgrab = HBoxContainer.new()
	vgrab.rect_min_size = Vector2(0, 6)
	vgrab.mouse_default_cursor_shape = Control.CURSOR_VSIZE
	vgrab.hint_tooltip = tip
	vgrab.connect("gui_input", self, handler)
	var vline = ColorRect.new()
	vline.color = Color(1, 1, 1, 0.15)
	vline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vline.rect_min_size = Vector2(48, 2)
	vline.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vline.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vgrab.alignment = BoxContainer.ALIGN_CENTER
	vgrab.add_child(vline)
	return vgrab


# Small grey "N Favorites | M Hidden" label, like the Favorites mod's.
func _mk_count_label() -> Label:
	var lbl = Label.new()
	lbl.align = Label.ALIGN_CENTER
	lbl.modulate = Color(0.72, 0.72, 0.72)
	var f = lbl.get_font("font")
	if f is DynamicFont:
		var sf = f.duplicate()
		sf.size = int(max(8, floor(f.size * 0.85)))
		lbl.add_font_override("font", sf)
	return lbl


func _update_brush_count_label() -> void:
	if _brush_count_lbl == null or not is_instance_valid(_brush_count_lbl):
		return
	var favc = 0
	var hidc = 0
	for p in _brush_paths:
		var k = _brush_key_of(p)
		if _brush_fav.has(k):
			favc += 1
		if _brush_hidden.has(k):
			hidc += 1
	_brush_count_lbl.text = str(favc) + " Favorites | " + str(hidc) + " Hidden"


func _update_tex_count_label() -> void:
	if _tex_count_lbl == null or not is_instance_valid(_tex_count_lbl):
		return
	var favc = 0
	var hidc = 0
	for p in _tex_tab_paths():
		if _is_fav(p):
			favc += 1
		if _tex_hidden.has(p):
			hidc += 1
	_tex_count_lbl.text = str(favc) + " Favorites | " + str(hidc) + " Hidden"


# Brush library grip: drag sets a minimum height (the list keeps filling the
# panel when that is taller); double-click resets to "fit the panel".
func _on_brush_list_grab_input(event) -> void:
	if _brush_list == null or not is_instance_valid(_brush_list):
		return
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed and event.doubleclick:
			_brush_list_h = 0.0
			_brush_list.rect_min_size = Vector2(0, 0)
			_save_brush_prefs()
		elif not event.pressed:
			_save_brush_prefs()
		return
	if not (event is InputEventMouseMotion) or not Input.is_mouse_button_pressed(BUTTON_LEFT):
		return
	var h = clamp(_brush_list.get_local_mouse_position().y, 120.0, 4000.0)
	_brush_list.rect_min_size = Vector2(0, h)
	_brush_list_h = h


# ── left panel resize: floating grip on the tool panel's right edge ──────────

func _ensure_left_grip() -> void:
	if _left_grip != null and is_instance_valid(_left_grip):
		return
	if _g.Editor == null:
		return
	_left_grip = Control.new()
	_left_grip.name = "BTTLeftGrip"
	_left_grip.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	_left_grip.mouse_filter = Control.MOUSE_FILTER_STOP
	_left_grip.hint_tooltip = "Drag to resize"
	var grip = ColorRect.new()
	grip.color = Color(1, 1, 1, 0.15)
	grip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grip.anchor_top = 0.5
	grip.anchor_bottom = 0.5
	grip.anchor_left = 0.5
	grip.anchor_right = 0.5
	grip.margin_left = -1
	grip.margin_right = 1
	grip.margin_top = -24
	grip.margin_bottom = 24
	_left_grip.add_child(grip)
	_left_grip.connect("gui_input", self, "_on_left_grip_input")
	_g.Editor.add_child(_left_grip)


func _on_left_grip_input(event) -> void:
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		_left_dragging = event.pressed
		if not event.pressed:
			_panel_w_left = _tool_panel.rect_min_size.x
			_save_brush_prefs()


func _tick_left_grip() -> void:
	if _left_grip == null or not is_instance_valid(_left_grip):
		return
	var visible = _tool_panel != null and is_instance_valid(_tool_panel) \
		and _tool_panel is Control and _tool_panel.is_visible_in_tree()
	_left_grip.visible = visible
	if not visible:
		_left_dragging = false
		return
	if _left_dragging:
		if not Input.is_mouse_button_pressed(BUTTON_LEFT):
			_left_dragging = false
			_panel_w_left = _tool_panel.rect_min_size.x
			_save_brush_prefs()
		else:
			var r = _tool_panel.get_global_rect()
			var mx = _tool_panel.get_viewport().get_mouse_position().x
			_tool_panel.rect_min_size.x = clamp(mx - r.position.x, _left_min_w, 1200.0)
	# Follow the panel's right edge (also while its width changes).
	var pr = _tool_panel.get_global_rect()
	_left_grip.rect_global_position = Vector2(pr.position.x + pr.size.x - 3, pr.position.y)
	_left_grip.rect_size = Vector2(7, pr.size.y)


func _layer_list_content_h() -> float:
	if _layer_rows != null and is_instance_valid(_layer_rows):
		# Mid-rebuild (rows not laid out yet): unknown, do not collapse.
		if _layer_rows.rect_size.y < 1.0 and _layer_rows.get_child_count() > 0:
			return 800.0
		return _layer_rows.rect_size.y + 6.0
	return 800.0


# Smallest allowed list height: the usual minimum, or in compact mode the
# rows' own height when they are shorter (the list hugs its content).
func _layer_list_floor() -> float:
	if _compact_rows:
		return max(_row_h() + 6.0, min(LAYER_LIST_MIN_H, _layer_list_content_h()))
	return LAYER_LIST_MIN_H


# Never taller than the rows it contains (no point resizing into emptiness).
func _layer_list_max_h() -> float:
	return max(_layer_list_floor(), min(_layer_list_content_h(), 800.0))


# Keep the list between its floor and its content height, around the height
# the user chose with the grip (which is preserved across modes).
func _clamp_layer_list_height() -> void:
	if _layer_scroll == null or not is_instance_valid(_layer_scroll):
		return
	var want = clamp(max(_layer_list_h, LAYER_LIST_MIN_H), _layer_list_floor(), _layer_list_max_h())
	if abs(_layer_scroll.rect_min_size.y - want) > 0.5:
		_layer_scroll.rect_min_size.y = want


func _on_layer_list_grab_input(event) -> void:
	if _layer_scroll == null or not is_instance_valid(_layer_scroll):
		return
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT and not event.pressed:
			_layer_list_h = _layer_scroll.rect_min_size.y
			_save_brush_prefs()
		return
	if not (event is InputEventMouseMotion):
		return
	if not Input.is_mouse_button_pressed(BUTTON_LEFT):
		return
	var local = _layer_scroll.get_local_mouse_position()
	var h = clamp(local.y, _layer_list_floor(), _layer_list_max_h())
	_layer_scroll.rect_min_size.y = h
	_layer_list_h = h


# ── Minor Utils integration ──────────────────────────────────────────────────
# Adds a "Better Terrain Tool" entry to Minor Utils' shortcut-button list
# (button + settings row + shortcut), WITHOUT modifying Minor Utils: we drive
# its own public builders on its live instance and let it persist the entry
# in its own config. On later sessions Minor Utils rebuilds the entry itself;
# we only re-apply the icon (its loader cannot read filesystem paths).

func _try_minor_utils() -> void:
	var mu = _find_minor_utils()
	if mu == null:
		return
	var cfg = mu.get("ui_config")
	if not (cfg is Dictionary) or not (cfg.get("buttons") is Array):
		return
	if mu.get("tool_panel") == null:
		return
	_mu_done = true
	var tex = _mu_icon()
	for entry in cfg["buttons"]:
		if not (entry is Dictionary) or str(entry.get("tool_reference")) != TOOL_ID:
			continue
		_mu_patch_icons(entry, tex)
		return
	var config = {
		"icon_path": _root + "icons/better_terrain_tool.png",
		"tool_reference": TOOL_ID,
		"tool_display_name": TOOL_NAME,
		"order_id": cfg["buttons"].size(),
		"shortcut_key_value": "",
		"shortcut_key_active": false,
		"visible": true,
	}
	cfg["buttons"].append(config)
	mu.make_shortcut_button(config)
	mu.make_config_entry_for_button(config)
	_mu_patch_icons(config, tex)
	mu._save_config_file()
	print("[BetterTerrain] Registered in Minor Utils' shortcut buttons.")


func _find_minor_utils():
	var save_btn = _g.Editor.get("saveButton")
	if save_btn == null or not is_instance_valid(save_btn):
		return null
	for conn in save_btn.get_signal_connection_list("pressed"):
		var target = conn.get("target")
		if target != null and target.has_method("make_shortcut_button") \
			and target.has_method("make_config_entry_for_button"):
			return target
	return null


func _mu_icon():
	var img = Image.new()
	if img.load(_root + "icons/better_terrain_tool.png") != OK:
		return null
	img.convert(Image.FORMAT_RGBA8)
	img.resize(40, 40, Image.INTERPOLATE_BILINEAR)
	var t = ImageTexture.new()
	t.create_from_image(img, Texture.FLAG_FILTER)
	return t


func _mu_patch_icons(entry: Dictionary, tex) -> void:
	if tex == null:
		return
	var btn = entry.get("button")
	if btn != null and is_instance_valid(btn):
		btn.icon = tex
	var hbox = entry.get("config_hbox")
	if hbox != null and is_instance_valid(hbox) and hbox.get_child_count() > 0:
		var ic = hbox.get_child(0)
		if ic is TextureRect:
			ic.texture = tex


func _sync_header_pad() -> void:
	if _header_pad == null or not is_instance_valid(_header_pad):
		return
	if _layer_scroll == null or not is_instance_valid(_layer_scroll):
		return
	# sb.visible is not reliable: decide from the actual content overflow.
	var needed = _layer_rows != null and is_instance_valid(_layer_rows) \
		and _layer_rows.rect_size.y > _layer_scroll.rect_size.y + 1.0
	var w = 0.0
	if needed:
		var sb = _layer_scroll.get_v_scrollbar()
		w = sb.rect_size.x if (sb != null and sb.rect_size.x > 0.0) else 12.0
	if _header_pad.rect_min_size.x != w:
		_header_pad.rect_min_size.x = w
	_header_pad.visible = w > 0.0


func _tick_scroll_to_selected() -> void:
	if _scroll_restore > 0:
		_scroll_restore -= 1
		if _scroll_restore == 0 and _layer_scroll != null and is_instance_valid(_layer_scroll):
			_layer_scroll.scroll_vertical = _scroll_restore_v
	if _scroll_to_sel <= 0:
		return
	_scroll_to_sel -= 1
	if _scroll_to_sel > 0:
		return
	if _layer_scroll == null or not is_instance_valid(_layer_scroll):
		return
	var r = _row_by_uid.get(_sel_uid)
	if r == null or not is_instance_valid(r["row"]):
		return
	var row = r["row"]
	var top = row.rect_position.y
	var bottom = top + row.rect_size.y
	var view_h = _layer_scroll.rect_size.y
	var cur = _layer_scroll.scroll_vertical
	if top < cur:
		_layer_scroll.scroll_vertical = int(top)
	elif bottom > cur + view_h:
		_layer_scroll.scroll_vertical = int(bottom - view_h)


# Thumbnail for any texture path: the native library thumbnail when known,
# otherwise one generated from the texture itself (patterns / tilesets before
# their catalog is scanned, textures from unloaded lists, ...).
func _thumb_for(path):
	if path == null or path == "":
		return null
	if str(path).begins_with("color://"):
		return _load_texture(path)
	var t = _thumb_by_path.get(path, null)
	if t != null:
		return t
	var tex = _load_texture(path)
	if tex == null:
		return null
	var img = tex.get_data()
	if img == null:
		return null
	img = img.duplicate()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var sz = min(128, min(img.get_width(), img.get_height()))
	img.resize(sz, sz, Image.INTERPOLATE_BILINEAR)
	var st = ImageTexture.new()
	st.create_from_image(img, Texture.FLAG_FILTER)
	_thumb_by_path[path] = st
	return st


# 40 px thumbnail for the layer rows.
const THUMB_COLOR_KEYS = ["hue", "saturation", "lightness", "gamma", "contrast", "tint_color", "tint_amount"]
const ROW_H = 56
const ROW_THUMB = 52


# Row height of the layer list: the full thumbnail height, or in compact
# mode the natural height of a text button (the label's own height).
func _row_h() -> float:
	if not _compact_rows:
		return float(ROW_H)
	var probe = Button.new()
	probe.text = "Xg"
	var h = probe.get_combined_minimum_size().y
	probe.free()
	return max(h, 18.0)


# Compact rows: strip the buttons' stylebox padding so the icon fills the
# whole (small) button instead of a fraction of it.
func _compact_icon_button(b: Button, rh: float) -> void:
	b.expand_icon = true
	b.rect_min_size = Vector2(rh, rh)
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		var sb = b.get_stylebox(st)
		if sb == null:
			continue
		sb = sb.duplicate()
		for m in [MARGIN_LEFT, MARGIN_TOP, MARGIN_RIGHT, MARGIN_BOTTOM]:
			sb.set_default_margin(m, 0)
		b.add_stylebox_override(st, sb)


func _toggle_compact_rows() -> void:
	_compact_rows = not _compact_rows
	_save_brush_prefs()
	_refresh_layer_list()


func _row_thumb(layer: Dictionary):
	var key = "row:" + str(layer["tex"])
	for k in THUMB_COLOR_KEYS:
		key += "|" + str(layer[k])
	key += "|" + str(layer.get("levels"))
	if _small_thumbs.has(key):
		return _small_thumbs[key]
	var t = _thumb_for(layer["tex"])
	var st = null
	if t != null and t is Texture:
		var img = t.get_data()
		if img != null:
			img = img.duplicate()
			if img.get_format() != Image.FORMAT_RGBA8:
				img.convert(Image.FORMAT_RGBA8)
			img.resize(ROW_THUMB, ROW_THUMB, Image.INTERPOLATE_BILINEAR)
			_apply_colors_to_image(img, layer)
			_draw_thumb_border(img)
			st = ImageTexture.new()
			st.create_from_image(img, Texture.FLAG_FILTER)
	if st != null:
		_small_thumbs[key] = st   # never cache a miss (catalog may not be scanned yet)
	return st


func _load_icon(path: String, scale := 1.0):
	var img = Image.new()
	if img.load(path) != OK:
		return null
	if scale != 1.0:
		img.resize(max(1, int(img.get_width() * scale)), max(1, int(img.get_height() * scale)), Image.INTERPOLATE_BILINEAR)
	var t = ImageTexture.new()
	t.create_from_image(img, Texture.FLAG_FILTER)
	return t


# uid of the layer whose row thumbnail contains the given screen point, or -1.
func _thumb_at(screen_pos: Vector2) -> int:
	for uid in _row_by_uid.keys():
		var r = _row_by_uid[uid]
		if r.has("thumb") and is_instance_valid(r["thumb"]) and r["thumb"].is_visible_in_tree():
			if r["thumb"].get_global_rect().has_point(screen_pos):
				return int(uid)
	return -1


func _use_popup_picker() -> bool:
	return Engine.has_meta(POPUP_META) and bool(Engine.get_meta(POPUP_META))


func _on_row_thumb_pressed(uid: int) -> void:
	if not _use_popup_picker():
		# Right-panel mode (default): the thumbnail focuses the Textures tab.
		# A plain click on a thumbnail is a single selection (no Ctrl/Shift
		# handling here), so any multi/group selection is replaced.
		if _sel_uid != uid or _multi_selected() or _sel_group != -1:
			_sel_uid = uid
			_sel_multi = [uid]
			_sel_group = -1
			_refresh_layer_list()
			_sync_props()
		if _rp_tab_btns.size() > 0 and is_instance_valid(_rp_tab_btns[0]):
			_rp_tab_btns[0].pressed = true   # switches to the Textures tab
		# Reflect THIS slot's texture kind in the tab, whatever it was before:
		# plain colour -> Use Plain Color ON; pattern -> plain OFF + patterns
		# shown, so the texture is actually visible in the grid.
		var layer2 = _selected_layer()
		if layer2 != null:
			var texp = str(layer2["tex"])
			if not texp.begins_with("color://"):
				_ensure_pattern_catalog()
				if _pattern_paths.has(texp) and not _show_patterns:
					_on_show_patterns_toggled(true)
		_sync_props()
		_populate_tex_list()
		call_deferred("_scroll_tex_list_to_selected")
		return
	_legacy_row_thumb_pressed(uid)


func _legacy_row_thumb_pressed(uid: int) -> void:
	# Re-clicking the SAME slot's preview while its picker is open closes it;
	# clicking another slot's preview switches the picker to that slot.
	if _picker_win != null and is_instance_valid(_picker_win) and _picker_win.visible and _picker_uid == uid:
		_picker_win.hide()
		return
	if _sel_uid != uid:
		_sel_uid = uid
		_refresh_layer_list()
		_sync_props()
	_picker_uid = uid
	_on_pick_texture()


func _draw_thumb_border(img: Image) -> void:
	var grey = Color(0.75, 0.75, 0.75, 1.0)
	var w = img.get_width()
	var h = img.get_height()
	img.lock()
	for x in range(w):
		img.set_pixel(x, 0, grey)
		img.set_pixel(x, h - 1, grey)
	for y in range(h):
		img.set_pixel(0, y, grey)
		img.set_pixel(w - 1, y, grey)
	img.unlock()


# Drag & drop a row onto another to reorder: the dragged layer takes the first
# FREE z above (drop on the upper half) or below (lower half) the target row.
# set_drag_forwarding() only accepts Controls, so the row buttons carry a tiny
# script that overrides the drag callbacks and delegates back here.
var _dnd_script = null

func _mk_dnd_button(uid: int) -> Button:
	var b = Button.new()
	b.set_script(_row_dnd_script())
	b.set_meta("btt_uid", uid)
	b.handler = self
	return b


func _row_dnd_script():
	if _dnd_script != null:
		return _dnd_script
	var sc = GDScript.new()
	sc.source_code = """extends Button
var handler = null
func get_drag_data(_pos):
	if handler == null:
		return null
	return handler.row_drag_data(self)
func can_drop_data(_pos, data):
	return handler != null and handler.row_can_drop(self, data)
func drop_data(pos, data):
	if handler != null:
		handler.row_drop(self, pos, data)
"""
	sc.reload()
	_dnd_script = sc
	return sc


func row_drag_data(from: Control):
	if not from.has_meta("btt_uid"):
		return null
	var uid = int(from.get_meta("btt_uid"))
	var layer = _find_layer(_cur_level_id, uid)
	if layer == null:
		return null
	var prev = Button.new()
	prev.text = " " + _layer_label(layer)
	prev.icon = _row_thumb(layer)
	from.set_drag_preview(prev)
	return {"btt_uid": uid}


func row_can_drop(from: Control, data) -> bool:
	return data is Dictionary and data.has("btt_uid") and from.has_meta("btt_uid") \
		and int(data["btt_uid"]) != int(from.get_meta("btt_uid"))


# Insertion-based reorder. The list shows the LOWEST z at the top; dropping on
# the upper half of a row inserts just before it, lower half just after. The
# dragged layer takes the first free z in the gap; when the neighbours'
# z values are consecutive, the following layers are shifted up to open one.
func row_drop(from: Control, _pos: Vector2, data) -> void:
	var uid = int(data["btt_uid"])
	if Input.is_key_pressed(KEY_ALT):
		# Photoshop-style Alt-drag: the DUPLICATE lands at the drop position.
		var copy = _duplicate_layer(uid)
		if copy == null:
			return
		uid = int(copy["uid"])
	var target_uid = int(from.get_meta("btt_uid"))
	var layer = _find_layer(_cur_level_id, uid)
	var target = _find_layer(_cur_level_id, target_uid)
	if layer == null or target == null:
		return
	var order = _cur_layers().duplicate()
	order.sort_custom(self, "_by_z")
	order.erase(layer)
	var idx = order.find(target)
	if idx < 0:
		return
	# Direction-aware: dropping onto a row moves the layer to the OTHER side of
	# it. Dragging 450 onto 470 -> lands after 470 (471); dragging 490 onto
	# 470 -> lands before it.
	if int(layer["z"]) < int(target["z"]):
		idx += 1
	var og = _group_of(uid)
	var tg = _group_of(target_uid)
	var joining = tg != null and (og == null or int(og["uid"]) != int(tg["uid"]))
	var leaving = og != null and tg == null
	if joining:
		# Entering a group always lands at its BOTTOM edge.
		var last = -1
		for i in range(order.size()):
			if tg["members"].has(int(order[i]["uid"])):
				last = i
		idx = last + 1
	elif leaving:
		# Leaving a group: land immediately above or below it, never further.
		var gmin = -1
		var gmax = -1
		for i in range(order.size()):
			if og["members"].has(int(order[i]["uid"])):
				if gmin < 0:
					gmin = i
				gmax = i
		if gmin >= 0:
			if idx > gmax + 1:
				idx = gmax + 1
			elif idx < gmin:
				idx = gmin
			elif idx > gmin and idx <= gmax:
				idx = gmax + 1   # dropped inside its own span while exiting: below
	var prev = order[idx - 1] if idx > 0 else null
	var next = order[idx] if idx < order.size() else null
	if og != null and (tg == null or int(tg["uid"]) != int(og["uid"])):
		og["members"].erase(uid)
		if og["members"].empty():
			_cur_groups().erase(og)
	if joining:
		if not tg["members"].has(uid):
			tg["members"].append(uid)
	var z
	if prev == null and next == null:
		z = int(layer["z"])
	elif prev == null:
		z = int(next["z"]) - 1
	elif next == null:
		z = int(prev["z"]) + 1
	elif int(next["z"]) - int(prev["z"]) > 1:
		z = int(prev["z"]) + 1
	else:
		# No gap: shift the tail up by one to open a slot.
		z = int(prev["z"]) + 1
		var floor_z = z
		for i in range(idx, order.size()):
			if int(order[i]["z"]) <= floor_z:
				order[i]["z"] = floor_z + 1
				floor_z += 1
				if order[i]["node"] != null and is_instance_valid(order[i]["node"]):
					order[i]["node"].z_index = int(order[i]["z"])
			else:
				break
	if z == int(layer["z"]):
		if joining or leaving:
			_persist()
			call_deferred("_refresh_layer_list")
			call_deferred("_sync_props")
		return
	layer["z"] = z
	if layer["node"] != null and is_instance_valid(layer["node"]):
		layer["node"].z_index = z
	if int(layer.get("clip", 0)) == 3:
		layer["clip"] = 0
		layer["clip_obj"] = null
		var entry_z = _cur_entry()
		if entry_z != null:
			_clip_update(entry_z, layer)
	_persist()
	call_deferred("_refresh_layer_list")
	call_deferred("_sync_props")


func _by_z(a, b) -> bool:
	return int(a["z"]) < int(b["z"])


# Double-click a row's name -> rename it in place.
func _on_row_btn_gui_input(event, uid: int) -> void:
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT \
		and event.pressed and event.doubleclick:
		_start_inline_rename(uid)
	elif event is InputEventMouseButton and event.button_index == BUTTON_RIGHT and event.pressed:
		_open_layer_ctx_menu(uid, event.global_position)


var _layer_ctx_menu: PopupMenu = null
var _layer_ctx_uid := -1

func _open_layer_ctx_menu(uid: int, pos: Vector2) -> void:
	var layer = _find_layer(_cur_level_id, uid)
	if layer == null:
		return
	if _layer_ctx_menu != null and is_instance_valid(_layer_ctx_menu):
		_layer_ctx_menu.queue_free()
	_layer_ctx_menu = PopupMenu.new()
	_layer_ctx_menu.add_item("Duplicate", 100)
	_layer_ctx_menu.add_item("Delete", 101)
	var gsub = PopupMenu.new()
	gsub.name = "groupsub"
	gsub.add_item("[ New group ]", 200)
	var gi = 0
	for g in _cur_groups():
		gsub.add_item(str(g["name"]), 210 + gi)
		gi += 1
	gsub.connect("id_pressed", self, "_on_group_add_menu_id")
	_layer_ctx_menu.add_child(gsub)
	_layer_ctx_menu.add_submenu_item("Add to group", "groupsub")
	if _group_of(uid) != null:
		_layer_ctx_menu.add_item("Remove from group", 111)
	_layer_ctx_menu.add_separator()
	var sub = PopupMenu.new()
	sub.name = "clipsub"
	sub.add_radio_check_item("No clipping mask", 0)
	sub.add_radio_check_item("All Objects Below", 2)
	sub.add_radio_check_item("All Objects Above", 4)
	sub.add_radio_check_item("Same Layer", 1)
	sub.add_radio_check_item("Single Object", 3)
	var cur = int(layer.get("clip", 0))
	for i in range(sub.get_item_count()):
		sub.set_item_checked(i, sub.get_item_id(i) == cur)
	sub.connect("id_pressed", self, "_on_clip_menu_id")
	_layer_ctx_menu.add_child(sub)
	_layer_ctx_menu.add_submenu_item("Clipping Mask", "clipsub")
	_layer_ctx_menu.add_separator()
	_layer_ctx_menu.add_check_item("Compact rows", 120)
	_layer_ctx_menu.set_item_checked(_layer_ctx_menu.get_item_index(120), _compact_rows)
	_layer_ctx_menu.connect("id_pressed", self, "_on_layer_ctx_id")
	_g.Editor.add_child(_layer_ctx_menu)
	_layer_ctx_uid = uid
	_clip_menu_uid = uid
	_layer_ctx_menu.rect_position = pos
	_layer_ctx_menu.popup()


# Layers a context action applies to: the whole selection when the clicked
# row belongs to it, else just the clicked row.
func _ctx_targets() -> Array:
	if _sel_multi.has(_layer_ctx_uid):
		return _edit_targets()
	var l = _find_layer(_cur_level_id, _layer_ctx_uid)
	return [l] if l != null else []


func _on_group_add_menu_id(id: int) -> void:
	var targets = _ctx_targets()
	if targets.empty():
		return
	for l in targets:
		_drop_group_membership(int(l["uid"]))
	if id == 200:
		var g = {"uid": _next_group_uid, "name": "Group %d" % _next_group_uid,
			"members": [], "open": true, "visible": true}
		_next_group_uid += 1
		for l in targets:
			g["members"].append(int(l["uid"]))
		_cur_groups().append(g)
		_record_op({"type": "group", "level_id": _cur_level_id, "before": null, "after": _ser_group(g)})
		# The new group becomes the selection (not its members).
		_grp_runtime(g)
		_sel_group = int(g["uid"])
		_sel_uid = -1
		_sel_multi = []
	else:
		var gi = id - 210
		var groups = _cur_groups()
		if gi >= 0 and gi < groups.size():
			for l in targets:
				if not groups[gi]["members"].has(int(l["uid"])):
					groups[gi]["members"].append(int(l["uid"]))
	_refresh_layer_list()
	_persist()


func _on_layer_ctx_id(id: int) -> void:
	match id:
		120:
			_toggle_compact_rows()
		100:
			if _sel_multi.has(_layer_ctx_uid) and _multi_selected():
				_duplicate_selection()
			else:
				_duplicate_layer(_layer_ctx_uid)
		101:
			if not (_sel_multi.has(_layer_ctx_uid) and _multi_selected()):
				_sel_uid = _layer_ctx_uid
				_sel_multi = [_sel_uid]
			_on_remove_layer()
		111:
			for l in _ctx_targets():
				_drop_group_membership(int(l["uid"]))
			_refresh_layer_list()
			_persist()


func _open_clip_menu(uid: int, pos: Vector2) -> void:
	var layer = _find_layer(_cur_level_id, uid)
	if layer == null:
		return
	if _clip_menu == null or not is_instance_valid(_clip_menu):
		_clip_menu = PopupMenu.new()
		_clip_menu.add_radio_check_item("No clipping mask", 0)
		_clip_menu.add_radio_check_item("All Objects Below", 2)
		_clip_menu.add_radio_check_item("All Objects Above", 4)
		_clip_menu.add_radio_check_item("Same Layer", 1)
		_clip_menu.add_radio_check_item("Single Object", 3)
		_clip_menu.connect("id_pressed", self, "_on_clip_menu_id")
		_g.Editor.add_child(_clip_menu)
	_clip_menu_uid = uid
	var cur = int(layer.get("clip", 0))
	for i in range(_clip_menu.get_item_count()):
		_clip_menu.set_item_checked(i, _clip_menu.get_item_id(i) == cur)
	_clip_menu.rect_position = pos
	_clip_menu.popup()


func _on_clip_menu_id(id: int) -> void:
	var entry = _cur_entry()
	var layer = _find_layer(_cur_level_id, _clip_menu_uid)
	if entry == null or layer == null:
		return
	layer["clip"] = int(id)
	layer["clip_z"] = null   # menu choices use the automatic target
	layer["clip_obj"] = null
	_clip_update(entry, layer)
	_refresh_layer_list()
	_persist()


func _start_inline_rename(uid: int) -> void:
	_cancel_inline_rename()
	var r = _row_by_uid.get(uid)
	var layer = _find_layer(_cur_level_id, uid)
	if r == null or layer == null or not is_instance_valid(r["btn"]):
		return
	var btn: Button = r["btn"]
	_rename_uid = uid
	_rename_edit = LineEdit.new()
	_rename_edit.text = str(layer["name"])
	_rename_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rename_edit.rect_min_size = Vector2(0, _row_h())
	_rename_edit.connect("text_entered", self, "_on_rename_entered")
	_rename_edit.connect("focus_exited", self, "_on_rename_focus_exited")
	var parent = btn.get_parent()
	parent.add_child(_rename_edit)
	parent.move_child(_rename_edit, btn.get_index())
	btn.visible = false
	_rename_edit.grab_focus()
	_rename_edit.select_all()


func _commit_inline_rename() -> void:
	if _rename_edit == null or not is_instance_valid(_rename_edit):
		return
	if _rename_guid >= 0:
		var g = _group_by_uid(_rename_guid)
		if g != null:
			var gtxt = _rename_edit.text.strip_edges()
			if gtxt != "":
				g["name"] = gtxt
			_persist()
		_cancel_inline_rename()
		call_deferred("_refresh_layer_list")
		return
	var layer = _find_layer(_cur_level_id, _rename_uid)
	if layer != null:
		var txt = _rename_edit.text.strip_edges()
		if txt != "":
			layer["name"] = txt
			layer["auto_name"] = false
		else:
			# Empty name -> back to the texture's display name (auto again).
			layer["name"] = _display_name(layer["tex"])
			layer["auto_name"] = true
		_persist()
	_cancel_inline_rename()
	# Deferred: committing can be triggered by focus loss while another row is
	# being clicked -- rebuilding the rows mid-event frees the clicked button
	# and crashes.
	call_deferred("_refresh_layer_list")


func _cancel_inline_rename() -> void:
	if _rename_edit != null and is_instance_valid(_rename_edit):
		_rename_edit.queue_free()
	_rename_edit = null
	_rename_uid = -1
	_rename_guid = -1


func _on_rename_entered(_txt: String) -> void:
	_commit_inline_rename()


func _on_rename_focus_exited() -> void:
	_commit_inline_rename()


func _add_group_header_row(g: Dictionary) -> void:
	var guid = int(g["uid"])
	var row = HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fold = Button.new()
	fold.flat = true
	fold.rect_min_size = Vector2(22, 26)
	var fic = _load_icon(_root + "icons/down.png", 0.5)
	if fic != null:
		var fr = TextureRect.new()
		fr.texture = fic
		fr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		fr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fr.anchor_right = 1.0
		fr.anchor_bottom = 1.0
		fr.flip_v = not bool(g["open"])
		fold.add_child(fr)
	else:
		fold.text = "v" if bool(g["open"]) else ">"
	fold.hint_tooltip = "Fold / unfold the group"
	fold.connect("pressed", self, "_on_group_fold", [guid])
	row.add_child(fold)
	var btn = Button.new()
	btn.flat = false
	btn.align = Button.ALIGN_LEFT
	btn.clip_text = true
	btn.rect_min_size = Vector2(0, 26)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.text = " [ " + str(g["name"]) + " ]"
	btn.hint_tooltip = "Select the group. Painting edits its fusion mask (right click / Alt+click carves, left click restores); Opacity and Smoothness edit the group, the other options edit every member. Double-click: rename. Ctrl+Click: select the member layers instead."
	btn.connect("pressed", self, "_on_group_header_pressed", [guid])
	btn.connect("gui_input", self, "_on_group_header_gui", [guid])
	_grp_row_btn[guid] = btn
	var all_sel = true
	for m in g["members"]:
		if not _sel_multi.has(int(m)):
			all_sel = false
			break
	if _sel_group == guid or (all_sel and _multi_selected()):
		btn.add_stylebox_override("normal", btn.get_stylebox("pressed"))
		btn.add_stylebox_override("hover", btn.get_stylebox("pressed"))
	row.add_child(btn)
	var gbicon = Button.new()
	var gbmode = int(g.get("blend", 0))
	if gbmode >= 0 and gbmode < _blend_icons.size() and _blend_icons[gbmode] != null:
		gbicon.icon = _blend_icons[gbmode]
	else:
		gbicon.text = ["N", "S", "H"][gbmode]
	gbicon.hint_tooltip = "Group blending: " + ["Normal", "Smooth", "Hard"][gbmode] + " (click to cycle). Shapes the edge of the group's combined coverage."
	gbicon.rect_min_size = Vector2(28, 26)
	gbicon.expand_icon = false
	gbicon.connect("pressed", self, "_on_group_blend_pressed", [guid])
	row.add_child(gbicon)
	var eye = Button.new()
	eye.flat = true
	eye.rect_min_size = Vector2(26, 26)
	eye.icon = _eye_icon if bool(g["visible"]) else _hide_icon
	eye.hint_tooltip = "Show / hide the whole group"
	eye.connect("pressed", self, "_on_group_eye", [guid])
	row.add_child(eye)
	_layer_rows.add_child(row)


var _group_ctx_menu: PopupMenu = null

func _on_group_header_gui(event, guid: int) -> void:
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT \
		and event.pressed and event.doubleclick:
		_start_group_rename(guid)
		return
	if event is InputEventMouseButton and event.button_index == BUTTON_RIGHT and event.pressed:
		if _group_ctx_menu != null and is_instance_valid(_group_ctx_menu):
			_group_ctx_menu.queue_free()
		_group_ctx_menu = PopupMenu.new()
		_group_ctx_menu.add_item("Rename", 301)
		_group_ctx_menu.add_item("Dissolve group", 300)
		_group_ctx_menu.add_item("Delete group (with layers)", 303)
		_group_ctx_menu.add_separator()
		_group_ctx_menu.add_check_item("Compact rows", 302)
		_group_ctx_menu.set_item_checked(_group_ctx_menu.get_item_index(302), _compact_rows)
		_group_ctx_menu.connect("id_pressed", self, "_on_group_ctx_id", [guid])
		_g.Editor.add_child(_group_ctx_menu)
		_group_ctx_menu.rect_position = event.global_position
		_group_ctx_menu.popup()


func _on_group_ctx_id(id: int, guid: int) -> void:
	if id == 300:
		_ungroup(guid)
	elif id == 301:
		_start_group_rename(guid)
	elif id == 302:
		_toggle_compact_rows()
	elif id == 303:
		_on_delete_group(guid)


func _on_group_fold(guid: int) -> void:
	var g = _group_by_uid(guid)
	if g != null:
		g["open"] = not bool(g["open"])
		_refresh_layer_list()
		_persist()


func _on_group_blend_pressed(guid: int) -> void:
	var g = _group_by_uid(guid)
	if g == null:
		return
	_grp_runtime(g)
	g["blend"] = (int(g["blend"]) + 1) % 3
	if int(g["blend"]) == 1:
		_blur_full_build(g)
	_grp_push_params(g)
	_persist()
	_refresh_layer_list()


func _start_group_rename(guid: int) -> void:
	_cancel_inline_rename()
	var g = _group_by_uid(guid)
	var btn = _grp_row_btn.get(guid)
	if g == null or btn == null or not is_instance_valid(btn):
		return
	_rename_guid = guid
	_rename_edit = LineEdit.new()
	_rename_edit.text = str(g["name"])
	_rename_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rename_edit.rect_min_size = Vector2(0, 26)
	_rename_edit.connect("text_entered", self, "_on_rename_entered")
	_rename_edit.connect("focus_exited", self, "_on_rename_focus_exited")
	var gparent = btn.get_parent()
	gparent.add_child(_rename_edit)
	gparent.move_child(_rename_edit, btn.get_index())
	btn.visible = false
	_rename_edit.grab_focus()
	_rename_edit.select_all()


func _on_group_header_pressed(guid: int) -> void:
	var g = _group_by_uid(guid)
	if g == null:
		return
	if Input.is_key_pressed(KEY_CONTROL):
		# Ctrl: select every member layer (the whole multi machinery applies).
		_sel_group = -1
		_sel_multi = []
		for m in g["members"]:
			_sel_multi.append(int(m))
		if not _sel_multi.empty():
			_sel_uid = int(_sel_multi[0])
			_sel_anchor = _sel_uid
	else:
		# Plain click: select the GROUP itself. Painting edits its fusion
		# mask; Opacity / Blending apply to the combined render.
		_grp_runtime(g)
		_sel_group = guid
		_sel_uid = -1
		_sel_multi = []
	_refresh_layer_list()
	_sync_props()


func _on_group_eye(guid: int) -> void:
	var g = _group_by_uid(guid)
	if g == null:
		return
	g["visible"] = not bool(g["visible"])
	for m in g["members"]:
		var l = _find_layer(_cur_level_id, int(m))
		if l != null:
			l["visible"] = bool(g["visible"])
			if l["node"] != null and is_instance_valid(l["node"]):
				l["node"].visible = bool(g["visible"])
	_persist()
	_refresh_layer_list()
	_update_all_eye_button()


func _on_layer_row_pressed(uid: int) -> void:
	_sel_group = -1
	if Input.is_key_pressed(KEY_CONTROL):
		# Toggle in / out of the multi-selection.
		if _sel_multi.has(uid) and _sel_multi.size() > 1:
			_sel_multi.erase(uid)
			if _sel_uid == uid:
				_sel_uid = int(_sel_multi[0])
		else:
			if not _sel_multi.has(_sel_uid) and _sel_uid >= 0:
				_sel_multi.append(_sel_uid)
			if not _sel_multi.has(uid):
				_sel_multi.append(uid)
			_sel_uid = uid
			_sel_anchor = uid
	elif Input.is_key_pressed(KEY_SHIFT) and (_sel_anchor >= 0 or _sel_uid >= 0):
		# Range from the FIXED anchor (set by the last plain / Ctrl click) to
		# the clicked row, in list order -- successive Shift-clicks all
		# measure from the same origin.
		if _sel_anchor < 0:
			_sel_anchor = _sel_uid
		var order = _cur_layers().duplicate()
		order.sort_custom(self, "_by_z")
		var a = -1
		var b = -1
		for i in range(order.size()):
			if int(order[i]["uid"]) == _sel_anchor:
				a = i
			if int(order[i]["uid"]) == uid:
				b = i
		_sel_multi = []
		if a >= 0 and b >= 0:
			for i in range(min(a, b), max(a, b) + 1):
				_sel_multi.append(int(order[i]["uid"]))
		_sel_uid = uid
	else:
		_sel_multi = [uid]
		_sel_uid = uid
		_sel_anchor = uid
	_refresh_layer_list()
	_sync_props()


func _multi_selected() -> bool:
	return _sel_multi.size() > 1


# ── Layer groups (Photoshop-style folders; members keep their z) ─────────────

func _cur_groups() -> Array:
	var e = _cur_entry()
	if e == null:
		return []
	if not e.has("groups"):
		e["groups"] = []
	return e["groups"]


func _group_uid_of(uid: int) -> int:
	var g = _group_of(uid)
	return int(g["uid"]) if g != null else -1


func _group_of(uid: int):
	for g in _cur_groups():
		if g["members"].has(uid):
			return g
	return null


func _group_by_uid(guid: int):
	for g in _cur_groups():
		if int(g["uid"]) == guid:
			return g
	return null


func _group_in_level(level_id: int, guid: int):
	var entry = _levels.get(level_id)
	if entry == null:
		return null
	for g in entry.get("groups", []):
		if int(g["uid"]) == guid:
			return g
	return null


const GRP_DEFAULTS = {"opacity": 1.0, "blend": 0, "smoothness": 1536.0, "res": DEFAULT_RES}
# The group's own colour settings, persisted with the map.
const GRP_CS_KEYS = ["hue", "saturation", "lightness", "gamma", "contrast", "tint_color", "tint_amount", "color_blend", "levels",
	"tex_rot", "tex_scale", "tex_off_x", "tex_off_y", "light_paint", "light_intensity", "clip", "clip_obj"]


# Phase B: the group is a quasi-layer with its OWN fusion mask, painted with
# the regular pipeline. The mask starts WHITE (the whole group shows); erasing
# carves it away, painting restores it -- Photoshop's "reveal all" group mask.
func _grp_runtime(g: Dictionary) -> void:
	for k in GRP_DEFAULTS.keys():
		if not g.has(k):
			g[k] = GRP_DEFAULTS[k]
	# The group's OWN colour settings (independent of the members').
	for k in COLOR_DEFAULTS.keys():
		if not g.has(k):
			var dv = COLOR_DEFAULTS[k]
			g[k] = dv.duplicate(true) if dv is Dictionary else dv
	if not g.has("tex"):
		g["tex"] = ""   # probed by the colour-settings module previews
	# Group-level Light Painting / clipping (independent of the members').
	for k in ["light_paint", "light_intensity", "clip", "clip_obj", "clip_z", "clip_vp"]:
		if not g.has(k):
			g[k] = {"light_paint": false, "light_intensity": 1.0, "clip": 0, "clip_obj": null, "clip_z": null, "clip_vp": null}[k]
	g["grp"] = true
	if not g.has("dirty"):
		g["dirty"] = false
	if not g.has("b64"):
		g["b64"] = ""
	if not g.has("blur_tex"):
		g["blur_tex"] = null
		g["blur_small"] = null
		g["blur_f"] = 0
	if g.get("mask") is Image and g.get("mask_tex") != null:
		return
	var img = g.get("mask")
	var gwx = _woxels()
	var gres = int(g["res"])
	var gw = max(1, int(ceil(gwx.x / gres)))
	var gh = max(1, int(ceil(gwx.y / gres)))
	if not (img is Image):
		img = Image.new()
		img.create(gw, gh, false, Image.FORMAT_RGBA8)
		img.fill(Color(1, 1, 1, 1))
		g["mask"] = img
	elif img.get_width() != gw or img.get_height() != gh:
		img = _fit_mask(img, gw, gh, gres, _pending_shift_px(), Color(1, 1, 1, 1))
		g["mask"] = img
	var mt = ImageTexture.new()
	mt.create_from_image(img, Texture.FLAG_FILTER)
	g["mask_tex"] = mt


# Member ShaderMaterials of a group (main + light mats), in whatever level
# owns the group.
func _grp_member_mats(g: Dictionary) -> Array:
	var out := []
	for lid in _levels.keys():
		var entry = _levels[lid]
		if not entry.get("groups", []).has(g):
			continue
		for l in entry["layers"]:
			if not g["members"].has(int(l["uid"])):
				continue
			var mat = l.get("mat")
			if mat != null and is_instance_valid(mat):
				out.append(mat)
			var lm = l.get("light_mat")
			if lm != null and is_instance_valid(lm):
				out.append(lm)
		break
	return out


# Member layer dicts of a group (z ascending), in whatever level owns it.
func _grp_member_layers(g: Dictionary) -> Array:
	var out := []
	for lid in _levels.keys():
		var entry = _levels[lid]
		if not entry.get("groups", []).has(g):
			continue
		for l in entry["layers"]:
			if g["members"].has(int(l["uid"])):
				out.append(l)
		break
	out.sort_custom(self, "_sort_by_z_asc")
	return out


# The level entry owning a group (null when the group is orphaned).
func _grp_entry(g: Dictionary):
	for lid in _levels.keys():
		if _levels[lid].get("groups", []).has(g):
			return _levels[lid]
	return null


# The group a layer belongs to (any level), or null.
func _grp_of_layer(layer: Dictionary):
	for lid in _levels.keys():
		var entry = _levels[lid]
		if not entry["layers"].has(layer):
			continue
		for g in entry.get("groups", []):
			if g["members"].has(int(layer["uid"])):
				return g
		break
	return null


# True when the layer belongs to a group whose Light Painting is on.
func _grp_light_of(layer: Dictionary) -> bool:
	var g = _grp_of_layer(layer)
	return g != null and bool(g.get("light_paint", false))


# Push the group's compositing uniforms to every member shader.
func _grp_push_params(g: Dictionary) -> void:
	_grp_runtime(g)
	if int(g["blend"]) == 1 and g.get("blur_tex") == null:
		_blur_full_build(g)
	var gtc = Color(str(g["tint_color"]))
	gtc.a = clamp(float(g["tint_amount"]), 0.0, 1.0)
	var glv = g["levels"]
	var glr = glv.get("r", [0, 1, 1, 0, 1])
	var glg = glv.get("g", [0, 1, 1, 0, 1])
	var glb = glv.get("b", [0, 1, 1, 0, 1])
	var glm = glv.get("m", [0, 1, 1, 0, 1])
	var glight = bool(g.get("light_paint", false))
	for mat in _grp_member_mats(g):
		mat.set_shader_param("grp_on", 1.0)
		mat.set_shader_param("grp_mask", g["mask_tex"])
		mat.set_shader_param("grp_opacity", float(g["opacity"]))
		mat.set_shader_param("grp_blend", float(int(g["blend"])))
		mat.set_shader_param("grp_hue", float(g["hue"]))
		mat.set_shader_param("grp_saturation", float(g["saturation"]))
		mat.set_shader_param("grp_lightness", float(g["lightness"]))
		mat.set_shader_param("grp_gamma", float(g["gamma"]))
		mat.set_shader_param("grp_contrast", float(g["contrast"]))
		mat.set_shader_param("grp_tint", gtc)
		mat.set_shader_param("glv_on", 1.0 if bool(glv.get("on", false)) else 0.0)
		mat.set_shader_param("glv_in_lo", Vector3(glr[0], glg[0], glb[0]))
		mat.set_shader_param("glv_in_hi", Vector3(glr[1], glg[1], glb[1]))
		mat.set_shader_param("glv_gamma", Vector3(glr[2], glg[2], glb[2]))
		mat.set_shader_param("glv_out_lo", Vector3(glr[3], glg[3], glb[3]))
		mat.set_shader_param("glv_out_hi", Vector3(glr[4], glg[4], glb[4]))
		mat.set_shader_param("glv_m_in_lo", float(glm[0]))
		mat.set_shader_param("glv_m_in_hi", float(glm[1]))
		mat.set_shader_param("glv_m_gamma", float(glm[2]))
		mat.set_shader_param("glv_m_out_lo", float(glm[3]))
		mat.set_shader_param("glv_m_out_hi", float(glm[4]))
		var bt = g.get("blur_tex")
		if bt != null:
			mat.set_shader_param("grp_blur", bt)
			mat.set_shader_param("grp_blur_scale", g.get("blur_scale_v", Vector2(1, 1)))
			mat.set_shader_param("grp_blur_texel", g.get("blur_texel_v", Vector2(0, 0)))
		# Group Transform (composed with the member's own in the shader).
		mat.set_shader_param("grp_tex_rot", deg2rad(float(g["tex_rot"])))
		mat.set_shader_param("grp_tex_scale", float(g["tex_scale"]))
		mat.set_shader_param("grp_tex_offset", Vector2(float(g["tex_off_x"]), float(g["tex_off_y"])))
		# Group Light Painting.
		mat.set_shader_param("grp_light_on", 1.0 if glight else 0.0)
		mat.set_shader_param("grp_light_gain", float(g["light_intensity"]))
		# Group clipping stencil (built by _grp_clip_update).
		var cvp = g.get("clip_vp")
		if cvp != null and is_instance_valid(cvp) and int(g.get("clip", 0)) > 0:
			mat.set_shader_param("grp_clip_mask", cvp.get_texture())
			mat.set_shader_param("grp_clip_texel", Vector2(1.0 / max(cvp.size.x, 1.0), 1.0 / max(cvp.size.y, 1.0)))
			mat.set_shader_param("grp_clip_on", 1.0)
		else:
			mat.set_shader_param("grp_clip_on", 0.0)
	# Group Smooth edge: every member needs its coverage blurred at the
	# group's smoothness (rebuilt when missing or when the factor changed).
	var gsmooth = int(g["blend"]) == 1
	for ml in _grp_member_layers(g):
		if gsmooth:
			if ml.get("gblur_tex") == null or int(ml.get("gblur_f", 0)) != _blur_factor(ml, "gblur"):
				_blur_full_build(ml, "gblur")
			else:
				var gmt = ml["mat"]
				gmt.set_shader_param("grp_mblur", ml["gblur_tex"])
		elif ml.get("gblur_tex") != null:
			ml["gblur_tex"] = null
			ml["gblur_small"] = null
			ml["gblur_f"] = 0
	# A group light needs a fresh backbuffer copy before each member draws.
	for ml in _grp_member_layers(g):
		var root = ml.get("node")
		if root != null and is_instance_valid(root) and root is BackBufferCopy:
			var need = glight or bool(ml.get("light_paint", false)) or int(ml["color_blend"]) > 0
			root.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT if need else BackBufferCopy.COPY_MODE_DISABLED


# Full resync of the group uniforms for one level (cheap: a handful of
# set_shader_param per layer). Called after any structural change.
func _groups_sync_shaders(entry) -> void:
	if entry == null:
		return
	var groups = entry.get("groups", [])
	for l in entry["layers"]:
		var mat = l.get("mat")
		if mat == null or not is_instance_valid(mat):
			continue
		var mine = null
		for gg in groups:
			if gg["members"].has(int(l["uid"])):
				mine = gg
				break
		if mine == null:
			mat.set_shader_param("grp_on", 0.0)
			var lm = l.get("light_mat")
			if lm != null and is_instance_valid(lm):
				lm.set_shader_param("grp_on", 0.0)
	for g in groups:
		if not g["members"].empty():
			_grp_push_params(g)


func _sel_grp():
	if _sel_group < 0:
		return null
	var g = _group_by_uid(_sel_group)
	if g == null:
		_sel_group = -1
	return g


# The paint pipeline's target: the selected group's quasi-layer, or the
# selected layer.
func _paint_target():
	var g = _sel_grp()
	if g != null:
		_grp_runtime(g)
		return g
	return _selected_layer()


func _stroke_target():
	if _stroke_group_guid >= 0:
		var g = _group_in_level(_cur_level_id, _stroke_group_guid)
		if g != null:
			_grp_runtime(g)
		return g
	return _find_layer(_cur_level_id, _stroke_layer_uid)


# Group the current multi-selection. Refused when the selection is not
# contiguous in the list, or touches an existing group.
func _group_selection() -> void:
	if not _multi_selected():
		return
	var order = _cur_layers().duplicate()
	order.sort_custom(self, "_by_z")
	var idxs := []
	for i in range(order.size()):
		if _sel_multi.has(int(order[i]["uid"])):
			idxs.append(i)
		if _group_of(int(order[i]["uid"])) != null and _sel_multi.has(int(order[i]["uid"])):
			print("[BetterTerrain] Group: a selected layer already belongs to a group.")
			return
	idxs.sort()
	if idxs[idxs.size() - 1] - idxs[0] != idxs.size() - 1:
		print("[BetterTerrain] Group: the selection must be contiguous in the list.")
		return
	var g = {"uid": _next_group_uid, "name": "Group %d" % _next_group_uid,
		"members": _sel_multi.duplicate(), "open": true, "visible": true}
	_next_group_uid += 1
	_cur_groups().append(g)
	# The freshly formed group becomes the selection (not its members).
	_grp_runtime(g)
	_sel_group = int(g["uid"])
	_sel_uid = -1
	_sel_multi = []
	_record_op({"type": "group", "level_id": _cur_level_id, "before": null, "after": _ser_group(g)})
	_refresh_layer_list()
	_persist()


func _ungroup(guid: int) -> void:
	var g = _group_by_uid(guid)
	if g == null:
		return
	if _sel_group == guid:
		_sel_group = -1
	_record_op({"type": "group", "level_id": _cur_level_id, "before": _ser_group(g), "after": null})
	_grp_free_clip(g)
	_cur_groups().erase(g)
	_refresh_layer_list()
	_persist()


func _ser_group(g: Dictionary) -> Dictionary:
	var d = {"uid": int(g["uid"]), "name": str(g["name"]),
		"members": g["members"].duplicate(), "open": bool(g["open"]), "visible": bool(g["visible"]),
		"opacity": float(g.get("opacity", 1.0)), "blend": int(g.get("blend", 0)),
		"smoothness": float(g.get("smoothness", 1536.0)), "res": int(g.get("res", DEFAULT_RES))}
	for ck in GRP_CS_KEYS:
		if g.has(ck):
			d[ck] = g[ck].duplicate(true) if g[ck] is Dictionary else g[ck]
	if g.get("mask") is Image:
		d["mask"] = (g["mask"] as Image).duplicate()
	return d


func _apply_group_op(op: Dictionary, is_undo: bool) -> void:
	var st = op["before"] if is_undo else op["after"]
	var other = op["after"] if is_undo else op["before"]
	if st == null and other != null:
		var g = _group_by_uid(int(other["uid"]))
		if g != null:
			if _sel_group == int(other["uid"]):
				_sel_group = -1
			_grp_free_clip(g)
			_cur_groups().erase(g)
	elif st != null:
		var g2 = _group_by_uid(int(st["uid"]))
		if g2 == null:
			var ng = st.duplicate(true)
			if ng.get("mask") is Image:
				# Never share the op's image: painting after the restore must
				# not corrupt the undo history.
				ng["mask"] = (ng["mask"] as Image).duplicate()
				ng["dirty"] = true
			_cur_groups().append(ng)
			_grp_runtime(ng)
		_next_group_uid = max(_next_group_uid, int(st["uid"]) + 1)
	_refresh_layer_list()


# Layers a property edit applies to: the whole multi-selection, or the
# selected layer alone.
func _edit_targets() -> Array:
	if _sel_grp() != null:
		# Group selected: layer settings and group settings are independent.
		# Nothing edits the members; the group branches handle everything.
		return []
	if _multi_selected():
		var out := []
		for u in _sel_multi:
			var l = _find_layer(_cur_level_id, int(u))
			if l != null:
				out.append(l)
		return out
	var l = _selected_layer()
	return [l] if l != null else []


var _blend_all_btn: Button = null
var _blend_mix_icon = null
var _all_eye_btn: Button = null
var _header_pad: Control = null
var _blend_all_state := -1     # -1 Mix (per-layer), else forced 0/1/2
var _blend_snapshot := {}      # uid -> blend, captured when leaving Mix

# Cycle: Mix -> Smooth -> Hard -> Normal -> Mix (restores the snapshot).
# When the layers already agree on a mode, the first click moves to the NEXT
# mode (no wasted click on an identical state).
func _on_blend_all_cycle() -> void:
	if _blend_all_state == -1:
		_blend_snapshot = {}
		var uniform = -2
		for l in _cur_layers():
			_blend_snapshot[int(l["uid"])] = int(l["blend"])
			if uniform == -2:
				uniform = int(l["blend"])
			elif uniform != int(l["blend"]):
				uniform = -1
		if uniform == 1:
			_blend_all_state = 2
		elif uniform == 2:
			_blend_all_state = 0
		else:
			_blend_all_state = 1
	elif _blend_all_state == 1:
		_blend_all_state = 2
	elif _blend_all_state == 2:
		_blend_all_state = 0
	else:
		# Back to Mix: if restoring the snapshot would change nothing (the
		# layers were already uniform before forcing), skip straight to Smooth.
		var differs = false
		for l in _cur_layers():
			if _blend_snapshot.get(int(l["uid"]), int(l["blend"])) != int(l["blend"]):
				differs = true
				break
		_blend_all_state = -1 if differs else 1
	for l in _cur_layers():
		if _blend_all_state == -1:
			l["blend"] = _blend_snapshot.get(int(l["uid"]), int(l["blend"]))
		else:
			l["blend"] = _blend_all_state
		_apply_color_params(l, l["mat"])
	_persist()
	_update_blend_all_label()
	_sync_props()
	_refresh_layer_list()


func _update_blend_all_label() -> void:
	if _blend_all_btn == null or not is_instance_valid(_blend_all_btn):
		return
	var mode = _blend_all_state
	if mode == -1:
		# Show the common mode when all layers agree, else "Mix".
		mode = -2
		for l in _cur_layers():
			if mode == -2:
				mode = int(l["blend"])
			elif mode != int(l["blend"]):
				mode = -1
				break
		if mode == -2:
			mode = -1
	var names = ["Mix", "Normal", "Smooth", "Hard"]
	var icons = [_blend_mix_icon, _blend_icons[0], _blend_icons[1], _blend_icons[2]]
	var idx = mode + 1
	_blend_all_btn.hint_tooltip = "Blending of ALL layers: " + names[idx] + " (click to cycle Mix / Smooth / Hard / Normal)."
	if icons[idx] != null:
		_blend_all_btn.icon = icons[idx]
		_blend_all_btn.text = ""
	else:
		_blend_all_btn.icon = null
		_blend_all_btn.text = names[idx]
	_update_all_eye_button()


func _update_all_eye_button() -> void:
	if _all_eye_btn == null or not is_instance_valid(_all_eye_btn):
		return
	var any_visible = false
	for l in _cur_layers():
		if bool(l["visible"]):
			any_visible = true
			break
	_all_eye_btn.icon = _eye_icon if any_visible else _hide_icon


func _on_all_visibility_pressed() -> void:
	var any_visible = false
	for l in _cur_layers():
		if bool(l["visible"]):
			any_visible = true
			break
	for l in _cur_layers():
		l["visible"] = not any_visible
		if l["node"] != null and is_instance_valid(l["node"]):
			l["node"].visible = not any_visible
	_persist()
	_update_all_eye_button()
	_refresh_layer_list()


func _on_row_blend_pressed(uid: int) -> void:
	var layer = _find_layer(_cur_level_id, uid)
	if layer == null:
		return
	var nb = (int(layer["blend"]) + 1) % 3
	var targets = _edit_targets() if _sel_multi.has(uid) else [layer]
	for l in targets:
		l["blend"] = nb
		_apply_color_params(l, l["mat"])
	_persist()
	_blend_all_state = -1   # manual per-layer change -> Mix
	_update_blend_all_label()
	_sync_props()
	_refresh_layer_list()


func _on_clip_check_toggled(on: bool) -> void:
	if _clip_box != null and is_instance_valid(_clip_box):
		_clip_box.visible = on
	if _ui_syncing:
		return
	var entry = _cur_entry()
	if entry == null or _selected_layer() == null:
		return
	var g = _sel_grp()
	if g != null:
		_grp_runtime(g)
		g["clip"] = (int(_clip_mode_opt.get_item_id(_clip_mode_opt.selected)) if _clip_mode_opt != null else 2) if on else 0
		g["clip_z"] = null
		g["clip_obj"] = null
		_grp_clip_update(entry, g)
		_refresh_layer_list()
		_persist()
		return
	for layer in _edit_targets():
		if on:
			layer["clip"] = int(_clip_mode_opt.get_item_id(_clip_mode_opt.selected)) if _clip_mode_opt != null else 2
		else:
			layer["clip"] = 0
		layer["clip_z"] = null
		layer["clip_obj"] = null
		_clip_update(entry, layer)
	_refresh_layer_list()
	_persist()


func _on_clip_mode_selected(idx: int) -> void:
	if _ui_syncing:
		return
	var entry = _cur_entry()
	var layer = _selected_layer()
	if entry == null or layer == null:
		return
	var g = _sel_grp()
	if g != null:
		_grp_runtime(g)
		g["clip"] = int(_clip_mode_opt.get_item_id(idx))
		g["clip_z"] = null
		g["clip_obj"] = null
		_grp_clip_update(entry, g)
		_refresh_layer_list()
		_persist()
		return
	layer["clip"] = int(_clip_mode_opt.get_item_id(idx))
	layer["clip_z"] = null
	layer["clip_obj"] = null
	_clip_update(entry, layer)
	_refresh_layer_list()
	_persist()


func _on_clip_pick_toggled(on: bool) -> void:
	_clip_pick_armed = on


# Pick the topmost prop under the map click and clip to its object layer.
func _clip_pick(screen_pos: Vector2) -> void:
	_clip_pick_armed = false
	if _clip_pick_btn != null and is_instance_valid(_clip_pick_btn):
		_clip_pick_btn.pressed = false
	var entry = _cur_entry()
	var layer = _selected_layer()
	if entry == null or layer == null:
		return
	var objects = entry["level"].get("Objects")
	var ui = _g.World.get("UI") if _g.World != null else null
	if objects == null or ui == null:
		return
	var wp = ui.get("MousePosition")
	if wp == null:
		return
	var best = null
	var best_z = 0
	for p in objects.get_children():
		if not (p is Node2D):
			continue
		if p.has_meta("preview") and bool(p.get_meta("preview")):
			continue
		var src = p.get("Sprite")
		if src == null or not is_instance_valid(src) or src.texture == null:
			continue
		var local = p.to_local(wp)
		var half = src.texture.get_size() * 0.5
		if abs(local.x) <= half.x and abs(local.y) <= half.y:
			if best == null or p.z_index >= best_z:
				best = p
				best_z = p.z_index
	if best == null:
		return
	var g = _sel_grp()
	if g != null:
		_grp_runtime(g)
		var gbefore = {"clip": int(g["clip"]), "clip_obj": g.get("clip_obj")}
		var gmode = int(g["clip"])
		if gmode == 0:
			gmode = 1
		g["clip"] = gmode
		g["clip_z"] = null
		g["clip_obj"] = str(best.get_meta("node_id")) if best.has_meta("node_id") else null
		_record_op({"type": "gclip", "level_id": _cur_level_id, "guid": int(g["uid"]), "before": gbefore,
			"after": {"clip": gmode, "clip_obj": g.get("clip_obj")}})
		_grp_clip_update(entry, g)
		_refresh_layer_list()
		_persist()
		return
	var before = {"z": int(layer["z"]), "clip": int(layer["clip"]), "clip_z": layer.get("clip_z"), "clip_obj": layer.get("clip_obj")}
	# Keep the mode the user chose; picking only turns clipping on if it was off.
	var cmode = int(layer["clip"])
	if cmode == 0:
		cmode = 1
	layer["clip"] = cmode
	layer["clip_z"] = int(best_z) if cmode == 1 else null
	layer["clip_obj"] = str(best.get_meta("node_id")) if best.has_meta("node_id") else null
	# The slot joins the picked object's layer (undoable).
	layer["z"] = int(best_z)
	if layer["node"] != null and is_instance_valid(layer["node"]):
		layer["node"].z_index = int(best_z)
	var after = {"z": int(layer["z"]), "clip": cmode, "clip_z": layer.get("clip_z"), "clip_obj": layer.get("clip_obj")}
	_record_op({"type": "clip_pick", "level_id": _cur_level_id, "uid": int(layer["uid"]), "before": before, "after": after})
	_clip_update(entry, layer)
	_refresh_layer_list()
	_persist()


func _on_light_paint_toggled(on: bool) -> void:
	if _light_box != null and is_instance_valid(_light_box):
		_light_box.visible = on
	if _ui_syncing:
		return
	var entry = _cur_entry()
	if entry == null:
		return
	var g = _sel_grp()
	if g != null:
		_grp_runtime(g)
		g["light_paint"] = on
		_grp_push_params(g)
		_persist()
		return
	for layer in _edit_targets():
		layer["light_paint"] = on
		_light_update(entry, layer)
	_persist()


func _on_light_intensity_changed(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	if _light_spin != null and is_instance_valid(_light_spin):
		_light_spin.value = v
	_ui_syncing = false
	var entry = _cur_entry()
	if entry == null:
		return
	var g = _sel_grp()
	if g != null:
		_grp_runtime(g)
		g["light_intensity"] = v
		_grp_push_params(g)
		_persist()
		return
	for layer in _edit_targets():
		layer["light_intensity"] = v
		_light_update(entry, layer)
	_persist()


func _on_light_intensity_spin(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	if _light_slider != null and is_instance_valid(_light_slider):
		_light_slider.value = v
	_ui_syncing = false
	_on_light_intensity_changed(v)


func _on_layer_hide_toggled(hidden: bool, uid: int) -> void:
	if _ui_syncing:
		return
	var layer = _find_layer(_cur_level_id, uid)
	if layer == null:
		return
	var targets = _edit_targets() if _sel_multi.has(uid) else [layer]
	_ui_syncing = true
	for l in targets:
		l["visible"] = not hidden
		if l["node"] != null and is_instance_valid(l["node"]):
			l["node"].visible = not hidden
		var r = _row_by_uid.get(int(l["uid"]))
		if r != null:
			r["hide"].pressed = hidden
			r["hide"].icon = _hide_icon if hidden else _eye_icon
			r["row"].modulate = Color(1, 1, 1, 1.0 if not hidden else 0.5)
			r["btn"].text = " " + _layer_label(l)
	_ui_syncing = false
	_persist()
	_update_all_eye_button()


func _sort_by_z_asc(a, b) -> bool:
	if int(a["z"]) == int(b["z"]):
		return int(a["uid"]) < int(b["uid"])
	return int(a["z"]) < int(b["z"])


func _sync_props() -> void:
	if _props_box == null or not is_instance_valid(_props_box):
		return
	var layer = _selected_layer()
	var grp = _sel_grp()
	_props_box.visible = layer != null
	_update_generate_label()
	_sync_organic_post()
	if _props_top != null and is_instance_valid(_props_top):
		_props_top.visible = layer != null and grp == null
	if layer == null:
		return
	_ui_syncing = true
	_ensure_catalog()   # thumbnails must be available right after a map load
	_z_slider.value = layer["z"]
	_z_spin.value = layer["z"]
	_opacity_slider.value = layer["opacity"]
	_opacity_spin.value = round(float(layer["opacity"]) * 100.0)
	if _smooth_slider != null:
		_smooth_slider.value = float(layer["smoothness"])
		_smooth_spin.value = float(layer["smoothness"])
	if _smooth_row != null and is_instance_valid(_smooth_row):
		_smooth_row.visible = int(layer["blend"]) == 1
	var psrc = layer
	if grp != null:
		_grp_runtime(grp)
		psrc = grp
	if _clip_check != null and is_instance_valid(_clip_check):
		_ui_syncing = true
		var cmode = int(psrc.get("clip", 0))
		_clip_check.pressed = cmode > 0
		_clip_box.visible = cmode > 0
		if _clip_mode_opt != null and is_instance_valid(_clip_mode_opt) and cmode > 0:
			for oi in range(_clip_mode_opt.get_item_count()):
				if _clip_mode_opt.get_item_id(oi) == cmode:
					_clip_mode_opt.selected = oi
					break
		_ui_syncing = false
	if _light_check != null and is_instance_valid(_light_check):
		_ui_syncing = true
		var lp2 = bool(psrc.get("light_paint", false))
		_light_check.pressed = lp2
		_light_box.visible = lp2
		if _light_slider != null and is_instance_valid(_light_slider):
			_light_slider.value = float(psrc.get("light_intensity", 1.0))
		if _light_spin != null and is_instance_valid(_light_spin):
			_light_spin.value = float(psrc.get("light_intensity", 1.0))
		_ui_syncing = false
	if _cs != null:
		_cs.sync_ui()
	if _use_plain_check != null and is_instance_valid(_use_plain_check):
		var plain = str(layer["tex"]).begins_with("color://")
		if _use_plain_check.pressed != plain:
			_use_plain_check.pressed = plain   # triggers the box/list visibility
		if plain and _plain_picker != null and is_instance_valid(_plain_picker):
			var cc = Color(str(layer["tex"]).substr(8))
			if not _plain_picker.color.is_equal_approx(cc):
				_plain_picker.color = cc

	if grp != null:
		# Group selected: Opacity / Smoothness show the GROUP's own values;
		# everything layer-specific is hidden (layer and group settings are
		# fully independent).
		_grp_runtime(grp)
		_ui_syncing = true
		_opacity_slider.value = float(grp["opacity"])
		_opacity_spin.value = round(float(grp["opacity"]) * 100.0)
		if _smooth_slider != null:
			_smooth_slider.value = float(grp["smoothness"])
			_smooth_spin.value = float(grp["smoothness"])
		if _smooth_row != null and is_instance_valid(_smooth_row):
			_smooth_row.visible = int(grp["blend"]) == 1
	var lay_only = grp == null
	if _z_row != null and is_instance_valid(_z_row):
		_z_row.visible = lay_only
	if _smooth_link_btn != null and is_instance_valid(_smooth_link_btn):
		_smooth_link_btn.visible = lay_only
	if _cs != null and _cs.get("_color_blend_option") != null and is_instance_valid(_cs._color_blend_option):
		var cbrow = _cs._color_blend_option.get_parent()
		if cbrow is Control:
			cbrow.visible = lay_only
	_res_option.selected = max(0, RES_OPTIONS.find(int(layer["res"])))
	_ui_syncing = false


# ── UI handlers ───────────────────────────────────────────────────────────────

func _on_add_layer() -> void:
	var entry = _cur_entry()
	if entry == null:
		return
	var tex = DEFAULT_TEX
	var prev = _selected_layer()
	if prev != null:
		tex = prev["tex"]
	# New layer goes just above the current top one.
	var z = -450
	for l in entry["layers"]:
		z = max(z, int(l["z"]) + 10)
	var layer = _new_layer(entry, "", tex, z, 1.0, true, DEFAULT_RES)
	_sel_uid = layer["uid"]
	_record_op({"type": "add", "level_id": _cur_level_id, "layer": _serialize_layer(layer)})
	_schedule_persist()
	_refresh_layer_list()


var _delete_group_confirm: ConfirmationDialog = null
var _remove_confirm: ConfirmationDialog = null

# Deep-copies a layer just above itself ("<name> copy"), selects it.
func _duplicate_layer(uid: int):
	var entry = _cur_entry()
	var src = _find_layer(_cur_level_id, uid)
	if entry == null or src == null:
		return null
	var d = _serialize_layer(src)
	d["name"] = str(src["name"]) + " copy"
	d["auto_name"] = false
	d["uid"] = _next_uid   # a fresh uid: _restore_layer reuses the dict's
	_restore_layer(_cur_level_id, d)
	var copy = _find_layer(_cur_level_id, int(d["uid"]))
	if copy == null:
		return null
	# A copy of a grouped layer joins the same group.
	var sg = _group_of(uid)
	if sg != null and not sg["members"].has(int(copy["uid"])):
		sg["members"].append(int(copy["uid"]))
	_record_op({"type": "add", "level_id": _cur_level_id, "layer": _serialize_layer(copy)})
	_sel_uid = int(copy["uid"])
	_sel_multi = [_sel_uid]
	_refresh_layer_list()
	_sync_props()
	_persist()
	return copy


func _duplicate_selection() -> void:
	var uids = _sel_multi.duplicate() if _multi_selected() else [_sel_uid]
	var copies := []
	for u in uids:
		var c = _duplicate_layer(int(u))
		if c != null:
			copies.append(int(c["uid"]))
	if copies.size() > 1:
		# Every copy stays selected, like the source selection.
		_sel_multi = copies
		_sel_uid = copies[copies.size() - 1]
		_refresh_layer_list()
		_sync_props()


func _on_remove_layer() -> void:
	if _sel_grp() != null:
		# Group selected: the remove button dissolves the group (its member
		# layers and their paint are kept).
		_ungroup(_sel_group)
		return
	var layer = _selected_layer()
	if _cur_entry() == null or layer == null:
		return
	if _remove_confirm == null or not is_instance_valid(_remove_confirm):
		_remove_confirm = ConfirmationDialog.new()
		_remove_confirm.window_title = "Remove terrain layer"
		_remove_confirm.get_ok().text = "Remove"
		_remove_confirm.connect("confirmed", self, "_do_remove_layer")
		_g.Editor.add_child(_remove_confirm)
	var targets = _edit_targets()
	if targets.size() > 1:
		_remove_confirm.window_title = "Remove terrain layers"
		_remove_confirm.dialog_text = "Remove the %d selected layers?\nTheir painted terrain will be deleted (Ctrl+Z restores them)." % targets.size()
	else:
		_remove_confirm.window_title = "Remove terrain layer"
		_remove_confirm.dialog_text = "Remove the layer \"%s\"?\nIts painted terrain will be deleted (Ctrl+Z restores it)." % str(layer["name"])
	_remove_confirm.popup_centered()


func _do_remove_layer() -> void:
	var entry = _cur_entry()
	if entry == null or _selected_layer() == null:
		return
	var targets = _edit_targets()
	if targets.size() > 1:
		_remove_layers(targets)
		return
	_record_op({"type": "remove", "level_id": _cur_level_id, "layer": _serialize_layer(_selected_layer()), "group": _group_uid_of(_sel_uid)})
	_delete_layer_by_uid(_cur_level_id, _sel_uid)
	_sel_uid = -1
	_refresh_layer_list()


# Remove several layers (and optionally a group) as ONE undo entry.
func _remove_layers(targets: Array, group = null) -> void:
	var entry = _cur_entry()
	if entry == null:
		return
	var ops := []
	for l in targets:
		ops.append({"type": "remove", "level_id": _cur_level_id, "layer": _serialize_layer(l), "group": _group_uid_of(int(l["uid"]))})
	if group != null:
		ops.append({"type": "group", "level_id": _cur_level_id, "before": _ser_group(group), "after": null})
	_record_op({"type": "multi", "level_id": _cur_level_id, "ops": ops})
	for l in targets:
		_delete_layer_by_uid(_cur_level_id, int(l["uid"]))
	if group != null:
		if _sel_group == int(group["uid"]):
			_sel_group = -1
		_grp_free_clip(group)
		_cur_groups().erase(group)
	_sel_uid = -1
	_sel_multi = []
	_refresh_layer_list()
	_sync_props()
	_persist()


func _on_delete_group(guid: int) -> void:
	var g = _group_by_uid(guid)
	if g == null:
		return
	var members = _grp_member_layers(g)
	if _delete_group_confirm == null or not is_instance_valid(_delete_group_confirm):
		_delete_group_confirm = ConfirmationDialog.new()
		_delete_group_confirm.window_title = "Delete group"
		_delete_group_confirm.get_ok().text = "Delete"
		_g.Editor.add_child(_delete_group_confirm)
	if _delete_group_confirm.is_connected("confirmed", self, "_do_delete_group"):
		_delete_group_confirm.disconnect("confirmed", self, "_do_delete_group")
	_delete_group_confirm.connect("confirmed", self, "_do_delete_group", [guid])
	_delete_group_confirm.dialog_text = "Delete the group \"%s\" AND its %d layer(s)?\nTheir painted terrain will be deleted (Ctrl+Z restores everything).\nUse \"Dissolve group\" to keep the layers." % [str(g["name"]), members.size()]
	_delete_group_confirm.popup_centered()


func _do_delete_group(guid: int) -> void:
	var g = _group_by_uid(guid)
	if g == null:
		return
	_remove_layers(_grp_member_layers(g), g)


func _on_z_changed(v: float) -> void:
	if _ui_syncing:
		return
	if _sel_grp() != null:
		return   # groups are reordered by hand in the list
	var layer = _selected_layer()
	if layer == null:
		return
	var delta = int(v) - int(layer["z"])
	var entry_z = _cur_entry()
	for l in _edit_targets():
		l["z"] = int(l["z"]) + delta if l != layer else int(v)
		if l["node"] != null and is_instance_valid(l["node"]):
			l["node"].z_index = int(l["z"])
		if int(l.get("clip", 0)) == 3:
			# Moving the slot by hand detaches it from the clipped object.
			l["clip"] = 0
			l["clip_obj"] = null
			if entry_z != null:
				_clip_update(entry_z, l)
		elif int(l.get("clip", 0)) != 0 and entry_z != null:
			_clip_update(entry_z, l)
	_ui_syncing = true
	_z_slider.value = v
	_z_spin.value = v
	_ui_syncing = false
	_persist()
	# Re-sort the dropdown by z; the slider keeps focus since we don't touch it.
	_refresh_layer_list()


# Jump the selected layer's z to the previous/next layer DEFINED in the map
# (level.Layers: Terrain -500, Caves -300, ..., User Layer 1 100, ...).
func _on_jump_layer(dir: int) -> void:
	var layer = _selected_layer()
	if layer == null or _cur_level == null or not is_instance_valid(_cur_level):
		return
	# level.Layers is a .NET SortedDictionary (opaque to GDScript):
	# SaveLayers() returns it as a Godot Dictionary; fall back to DD defaults.
	var zs := []
	if _cur_level.has_method("SaveLayers"):
		var defined = _cur_level.call("SaveLayers")
		if defined is Dictionary:
			for k in defined.keys():
				zs.append(int(k))
	if zs.empty():
		zs = [-500, -400, -300, -200, -100, 0, 100, 200, 300, 400, 500, 600, 700, 800, 900]
	zs.sort()
	var cur = int(layer["z"])
	var target = null
	if dir > 0:
		for z in zs:
			if int(z) > cur:
				target = int(z)
				break
	else:
		for i in range(zs.size() - 1, -1, -1):
			if int(zs[i]) < cur:
				target = int(zs[i])
				break
	if target == null:
		return
	_on_z_changed(clamp(target, -600, 1000))


func _update_drop_text(layer: Dictionary) -> void:
	var r = _row_by_uid.get(int(layer["uid"]))
	if r != null and is_instance_valid(r["btn"]):
		r["btn"].text = " " + _layer_label(layer)


func _on_opacity_changed(v: float) -> void:
	if _ui_syncing:
		return
	var gop = _sel_grp()
	if gop != null:
		# Group selected: the Opacity slider drives the GROUP's own opacity.
		_grp_runtime(gop)
		gop["opacity"] = v
		for gmat in _grp_member_mats(gop):
			gmat.set_shader_param("grp_opacity", v)
		_ui_syncing = true
		_opacity_spin.value = round(v * 100.0)
		_ui_syncing = false
		_persist()
		return
	for layer in _edit_targets():
		layer["opacity"] = v
		layer["mat"].set_shader_param("opacity", v)
	_ui_syncing = true
	_opacity_spin.value = round(v * 100.0)
	_ui_syncing = false
	_persist()


func _on_opacity_spin_changed(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_opacity_slider.value = v / 100.0
	_ui_syncing = false
	_on_opacity_changed(v / 100.0)


func _on_res_changed(idx: int) -> void:
	if _ui_syncing:
		return
	var layer = _selected_layer()
	if layer == null or idx < 0 or idx >= RES_OPTIONS.size():
		return
	var res = RES_OPTIONS[idx]
	if res == int(layer["res"]):
		return
	var wx = _woxels()
	var w = max(1, int(ceil(wx.x / res)))
	var h = max(1, int(ceil(wx.y / res)))
	var img: Image = layer["mask"]
	img.resize(w, h, Image.INTERPOLATE_BILINEAR)
	layer["res"] = res
	layer["mask_tex"].create_from_image(img, Texture.FLAG_FILTER)
	layer["mat"].set_shader_param("mask", layer["mask_tex"])
	_apply_color_params(layer, layer["mat"])
	layer["dirty"] = true
	_schedule_persist()


var _brush_thumb_cache := {}
var _thumb_queue := []      # [[list index, cache key, path, is_fav], ...] left to build
var _thumb_gen := 0         # bumped on every repopulate: stale queue entries are dropped

func _populate_brush_list() -> void:
	var keep_scroll = _brush_list.get_v_scroll().value
	_brush_list.clear()
	_thumb_queue = []
	_thumb_gen += 1
	var f = ""
	if _brush_search != null and is_instance_valid(_brush_search):
		f = _brush_search.text.to_lower()
	for i in range(_brush_paths.size()):
		var p = _brush_paths[i]
		var k = _brush_key_of(p)
		var is_fav = _brush_fav.has(k)
		var hidden = _brush_hidden.has(k)
		if _brush_view == BRUSH_VIEW_ALL and hidden:
			continue
		if _brush_view == BRUSH_VIEW_FAV and not is_fav:
			continue
		if _brush_view == BRUSH_VIEW_HIDDEN and not hidden:
			continue
		var name = _brush_display_name(p)
		if f != "" and not (f in name.to_lower()):
			continue
		var ck = p + ("|fav" if is_fav else "") + ("|inv" if _brush_inverted.has(_brush_key_of(p)) else "")
		var thumb = _brush_thumb_cache.get(ck)
		if thumb != null:
			_brush_list.add_item(name, thumb)
		else:
			_brush_list.add_item(name)
		var li = _brush_list.get_item_count() - 1
		if thumb == null and not _brush_thumb_cache.has(ck):
			# Built later, a few per frame (see _tick_thumbs): a big library
			# never freezes (or crashes) the panel build any more.
			_thumb_queue.append([li, ck, p, is_fav])
		_brush_list.set_item_tooltip(li, name + ("  (hidden)" if hidden else ""))
		_brush_list.set_item_metadata(li, i)
		if i == _brush_idx:
			_brush_list.select(li)
	# Same list as before (invert / fav toggle / rename): stay where we were
	# instead of jumping back to the top.
	if _brush_list.get_item_count() == _brush_list_prev_count and keep_scroll > 0:
		_brush_list.get_v_scroll().call_deferred("set_value", keep_scroll)
	_brush_list_prev_count = _brush_list.get_item_count()
	_update_brush_count_label()


# Drain the thumbnail queue within a small per-frame budget; each thumbnail
# is stored in the session cache and set on its (still current) list item.
func _tick_thumbs() -> void:
	if _thumb_queue.empty():
		return
	if _brush_list == null or not is_instance_valid(_brush_list):
		_thumb_queue = []
		return
	var gen = _thumb_gen
	var t0 = OS.get_ticks_msec()
	while not _thumb_queue.empty() and OS.get_ticks_msec() - t0 < THUMB_BUDGET_MS:
		var job = _thumb_queue.pop_front()
		var ck = job[1]
		var thumb = _brush_thumb_cache.get(ck)
		if thumb == null and not _brush_thumb_cache.has(ck):
			thumb = _brush_thumb(job[2], job[3])
			_brush_thumb_cache[ck] = thumb
		if gen != _thumb_gen or not is_instance_valid(_brush_list):
			return
		var li = int(job[0])
		if thumb != null and li < _brush_list.get_item_count():
			_brush_list.set_item_icon(li, thumb)


func _brush_key_of(path: String) -> String:
	return path.get_file()


func _load_brush_prefs() -> void:
	var f = File.new()
	if f.open(BRUSH_PREFS, File.READ) != OK:
		return
	var pr = JSON.parse(f.get_as_text())
	f.close()
	if pr.error != OK or not (pr.result is Dictionary):
		return
	_brush_fav = {}
	_brush_hidden = {}
	for k in pr.result.get("favorites", []):
		_brush_fav[str(k)] = true
	for k in pr.result.get("inverted_brushes", []):
		_brush_inverted[k] = true
	for k in pr.result.get("hidden", []):
		_brush_hidden[str(k)] = true
	_brush_view = int(pr.result.get("view", 0))
	_show_light_brushes = bool(pr.result.get("lights", false))
	_show_patterns = bool(pr.result.get("patterns", false))
	_color_open = bool(pr.result.get("color_settings", false))
	_transform_open = bool(pr.result.get("transform", false))
	_smooth_linked = bool(pr.result.get("smooth_link", false))
	_brush_random_ratio = bool(pr.result.get("random_ratio", false))
	_brush_roundness = float(pr.result.get("roundness", 1.0))
	_brush_random_rot = bool(pr.result.get("random_rot", true))
	# Rotation and ratio are per-session tweaks: every map load starts neutral.
	_brush_rot_fixed = 0.0
	_brush_ratio_fixed = 1.0
	_rp_tab = int(pr.result.get("rp_tab", 1))
	_tex_view = int(pr.result.get("tex_view", 0))
	_tex_hidden = {}
	for k in pr.result.get("hidden_textures", []):
		_tex_hidden[str(k)] = true
	_tex_color_tol = float(pr.result.get("tex_color_tol", 0.3))
	_tex_sort = int(pr.result.get("tex_sort", 0))
	_lib_icon_size = float(pr.result.get("lib_icon_size", 64.0))
	_organic_scale = float(pr.result.get("organic_scale", 1.0))
	_organic_detail = float(pr.result.get("organic_detail", 0.65))
	_organic_coverage = float(pr.result.get("organic_coverage", 55.0))
	_panel_w_left = float(pr.result.get("panel_w_left", 0.0))
	_panel_w_right = float(pr.result.get("panel_w_right", 0.0))
	_layer_list_h = float(pr.result.get("layer_list_h", 0.0))
	_compact_rows = bool(pr.result.get("compact_rows", false))
	_brush_list_h = float(pr.result.get("brush_list_h", 0.0))


func _save_brush_prefs() -> void:
	Directory.new().make_dir_recursive("user://BetterTerrainTool")
	var f = File.new()
	if f.open(BRUSH_PREFS, File.WRITE) == OK:
		f.store_string(JSON.print({"favorites": _brush_fav.keys(), "hidden": _brush_hidden.keys(), "inverted_brushes": _brush_inverted.keys(), "view": _brush_view, "lights": _show_light_brushes, "patterns": _show_patterns, "color_settings": _color_open, "transform": _transform_open, "smooth_link": _smooth_linked, "random_ratio": _brush_random_ratio, "roundness": _brush_roundness, "random_rot": _brush_random_rot, "rot_fixed": _brush_rot_fixed, "ratio_fixed": _brush_ratio_fixed, "rp_tab": _rp_tab, "tex_view": _tex_view, "hidden_textures": _tex_hidden.keys(), "panel_w_left": _panel_w_left, "panel_w_right": _panel_w_right, "layer_list_h": _layer_list_h, "compact_rows": _compact_rows, "brush_list_h": _brush_list_h, "tex_color_tol": _tex_color_tol, "tex_sort": _tex_sort, "lib_icon_size": _lib_icon_size, "organic_scale": _organic_scale, "organic_detail": _organic_detail, "organic_coverage": _organic_coverage}, "\t"))
		f.close()


func _on_rp_tab_toggled(pressed: bool, idx: int) -> void:
	if not pressed:
		return
	_rp_tab = idx
	if _tab_textures != null and is_instance_valid(_tab_textures):
		_tab_textures.visible = idx == 0
	if _tab_brushes != null and is_instance_valid(_tab_brushes):
		_tab_brushes.visible = idx == 1
	if idx == 0:
		_populate_tex_list()
	_save_brush_prefs()


# Screens / scaling setups vary too much to guess a good grid size: it is a
# user setting ("Library icon size" in the Brushes tab), applied to both lists.
func _grid_list_setup(list: ItemList) -> void:
	# Opt out of the Unofficial Patch's UIRescaler thumbnail pass: it scales
	# fixed_icon_size without the column width, which overlaps the grid. Our
	# own "Library icon size" slider covers big screens instead.
	list.set_meta("_uir_skip", true)
	# Follow the Unofficial Patch's "Asset Thumbnails" scale (published as a
	# World meta), so our grids match the size of the native libraries. The
	# effective scale includes DD's Enlarge UI. Column width follows too, so
	# no overlap. The slider stays the user's base size at scale 1.
	var icon = clamp(_lib_icon_size * _uir_thumb_scale(), 32.0, 512.0)
	list.icon_mode = ItemList.ICON_MODE_TOP
	list.max_columns = 0
	list.same_column_width = true
	list.fixed_column_width = int(icon + 26)
	list.fixed_icon_size = Vector2(icon, icon)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _uir_thumb_scale() -> float:
	if _g != null and _g.World != null and is_instance_valid(_g.World) \
		and _g.World.has_meta("uir_asset_thumb_scale"):
		return max(0.5, float(_g.World.get_meta("uir_asset_thumb_scale")))
	return 1.0


func _apply_lib_icon_size() -> void:
	for l in [_tex_list, _brush_list]:
		if l != null and is_instance_valid(l):
			_grid_list_setup(l)


func _build_textures_tab(box: VBoxContainer) -> void:
	_use_plain_check = CheckButton.new()
	_use_plain_check.text = "Use Plain Color"
	_use_plain_check.hint_tooltip = "Paint with a solid colour instead of a texture."
	_use_plain_check.connect("toggled", self, "_on_use_plain_toggled")
	box.add_child(_use_plain_check)
	_show_patterns_check2 = CheckButton.new()
	_show_patterns_check2.text = "Show patterns"
	_show_patterns_check2.pressed = _show_patterns
	_show_patterns_check2.connect("toggled", self, "_on_show_patterns_toggled")
	box.add_child(_show_patterns_check2)
	_tex_tools = [_show_patterns_check2]
	_tex_search = LineEdit.new()
	_tex_search.placeholder_text = "Search textures..."
	_tex_search.connect("text_changed", self, "_on_tex_search")
	box.add_child(_tex_search)
	_tex_tools.append(_tex_search)
	_build_color_search(box)
	var sort_row = HBoxContainer.new()
	var sort_lbl = Label.new()
	sort_lbl.text = "Sort by"
	sort_row.add_child(sort_lbl)
	_tex_sort_option = OptionButton.new()
	_tex_sort_option.add_item("Name")
	_tex_sort_option.add_item("Color")
	_tex_sort_option.selected = _tex_sort
	_tex_sort_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tex_sort_option.connect("item_selected", self, "_on_tex_sort_selected")
	sort_row.add_child(_tex_sort_option)
	box.add_child(sort_row)
	_tex_tools.append(sort_row)
	if _favorites_mod() != null:
		_tex_mode_btn = Button.new()
		_tex_mode_btn.hint_tooltip = "Cycle texture view: All / Favorites / Hidden"
		_tex_mode_btn.connect("pressed", self, "_on_tex_mode_cycle")
		box.add_child(_tex_mode_btn)
		_tex_tools.append(_tex_mode_btn)
		_tex_count_lbl = _mk_count_label()
		box.add_child(_tex_count_lbl)
		_tex_tools.append(_tex_count_lbl)
		_update_tex_mode_button()
	_tex_list = ItemList.new()
	_tex_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid_list_setup(_tex_list)
	_tex_list.allow_rmb_select = true
	_tex_tools.append(_tex_list)
	_tex_list.connect("item_selected", self, "_on_tex_selected")
	_tex_list.connect("item_rmb_selected", self, "_on_tex_rmb")
	box.add_child(_tex_list)
	_build_plain_color_box(box)


func _build_color_search(box: VBoxContainer) -> void:
	var row = HBoxContainer.new()
	row.add_constant_override("separation", 8)
	var left = VBoxContainer.new()
	left.add_constant_override("separation", 2)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var lbl_cs = Label.new()
	lbl_cs.text = "Search by color"
	left.add_child(lbl_cs)
	var crow = HBoxContainer.new()
	crow.add_constant_override("separation", 4)
	_tex_custom_btn = ColorPickerButton.new()
	_tex_custom_btn.rect_min_size = Vector2(56, 30)
	_tex_custom_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tex_custom_btn.hint_tooltip = "Custom colour filter"
	_tex_custom_btn.connect("color_changed", self, "_on_tex_custom_color")
	crow.add_child(_tex_custom_btn)
	_tex_eyedrop_btn = Button.new()
	_tex_eyedrop_btn.rect_min_size = Vector2(30, 30)
	_tex_eyedrop_btn.toggle_mode = true
	_tex_eyedrop_btn.hint_tooltip = "Pick a colour from the map, then filter by it"
	var eye_ic = _load_icon(_root + "icons/eyedropper.png", 0.7)
	if eye_ic != null:
		_tex_eyedrop_btn.icon = eye_ic
	else:
		_tex_eyedrop_btn.text = "/"
	_tex_eyedrop_btn.connect("toggled", self, "_on_tex_eyedrop_toggled")
	crow.add_child(_tex_eyedrop_btn)
	left.add_child(crow)
	row.add_child(left)
	var grid = GridContainer.new()
	grid.columns = 6
	grid.add_constant_override("hseparation", 2)
	grid.add_constant_override("vseparation", 2)
	_tex_swatches = []
	for i in range(TEX_PALETTE.size()):
		var b = Button.new()
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		b.hint_tooltip = "Filter textures by this colour"
		b.toggle_mode = true
		_style_swatch(b, TEX_PALETTE[i], false)
		b.connect("toggled", self, "_on_tex_swatch_toggled", [i])
		grid.add_child(b)
		_tex_swatches.append(b)
	row.add_child(grid)
	box.add_child(row)
	_tex_tools.append(row)
	var trow = HBoxContainer.new()
	_tex_tools.append(trow)
	var tlbl = Label.new()
	tlbl.text = "Tolerance"
	trow.add_child(tlbl)
	_tex_tol_slider = _mk_slider(0.05, 1.0, 0.01, _tex_color_tol, "_on_tex_tol_changed")
	trow.add_child(_tex_tol_slider)
	var clr = Button.new()
	var del_ic = _load_icon(_root + "icons/delete.png", 0.65)
	if del_ic != null:
		clr.icon = del_ic
	else:
		clr.text = "X"
	clr.hint_tooltip = "Reset the colour filter (colour, custom colour and tolerance)"
	clr.connect("pressed", self, "_on_tex_color_clear")
	trow.add_child(clr)
	box.add_child(trow)


var _swatch_icons := {}

# Styleboxes get stretched by containers/rescalers, so the circle is a BAKED
# icon: a Button with empty styleboxes always draws its icon at native size.
func _swatch_icon(col: Color, selected: bool) -> ImageTexture:
	var key = str(col) + ("|s" if selected else "")
	if _swatch_icons.has(key):
		return _swatch_icons[key]
	var sz = 28
	var img = Image.new()
	img.create(sz, sz, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c = (sz - 1) * 0.5
	var ring = Color(1, 1, 1) if selected else Color(0.35, 0.35, 0.35)
	var ring_w = 2.5 if selected else 1.4
	img.lock()
	for y in range(sz):
		for x in range(sz):
			var d = Vector2(x - c, y - c).length()
			var r_out = c
			if d <= r_out + 0.5:
				var px = ring if d > r_out - ring_w else col
				var a = clamp(r_out + 0.5 - d, 0.0, 1.0)   # AA on the rim
				img.set_pixel(x, y, Color(px.r, px.g, px.b, a))
	img.unlock()
	var t = ImageTexture.new()
	t.create_from_image(img, Texture.FLAG_FILTER)
	_swatch_icons[key] = t
	return t


func _style_swatch(b: Button, col: Color, selected: bool) -> void:
	b.icon = _swatch_icon(col, selected)
	b.expand_icon = false
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		b.add_stylebox_override(st, StyleBoxEmpty.new())


func _sync_swatches() -> void:
	for i in range(_tex_swatches.size()):
		var sel = _tex_color_filter != null and _tex_swatches[i].pressed
		_style_swatch(_tex_swatches[i], TEX_PALETTE[i], sel)


func _build_plain_color_box(box: VBoxContainer) -> void:
	_plain_box = VBoxContainer.new()
	_plain_box.visible = false
	_plain_box.add_constant_override("separation", 6)
	var grid = GridContainer.new()
	grid.columns = 8
	grid.add_constant_override("hseparation", 2)
	grid.add_constant_override("vseparation", 2)
	for hexc in PLAIN_DEFAULTS:
		var b = Button.new()
		b.rect_min_size = Vector2(22, 22)
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		b.icon = _swatch_icon(Color(hexc), false)
		b.expand_icon = false
		for st in ["normal", "hover", "pressed", "focus", "disabled"]:
			b.add_stylebox_override(st, StyleBoxEmpty.new())
		b.hint_tooltip = hexc
		b.connect("pressed", self, "_on_plain_swatch", [hexc])
		grid.add_child(b)
	_plain_box.add_child(grid)
	# Inline colour picker (no popup); its presets row doubles as a palette.
	_plain_picker = ColorPicker.new()
	_plain_picker.edit_alpha = false
	_plain_picker.presets_enabled = true
	_plain_picker.connect("color_changed", self, "_on_plain_picker_changed")
	_plain_box.add_child(_plain_picker)
	box.add_child(_plain_box)


func _on_use_plain_toggled(on: bool) -> void:
	if _plain_box != null and is_instance_valid(_plain_box):
		_plain_box.visible = on
	for c in _tex_tools:
		if c != null and is_instance_valid(c):
			c.visible = not on
	if on and _selected_layer() != null and not str(_selected_layer()["tex"]).begins_with("color://"):
		_apply_texture("color://#808080")
		if _plain_picker != null:
			_plain_picker.color = Color("#808080")


func _on_plain_swatch(hexc: String) -> void:
	if _selected_layer() == null:
		return
	_apply_texture("color://" + hexc)
	if _plain_picker != null and is_instance_valid(_plain_picker):
		_plain_picker.color = Color(hexc)


# Dragging inside the picker applies live without spamming the undo history:
# the transition is recorded once, ~0.6 s after the last change.
func _on_plain_picker_changed(c: Color) -> void:
	var layer = _selected_layer()
	if layer == null:
		return
	var path = "color://#" + c.to_html(false)
	if _plain_before == "":
		_plain_before = str(layer["tex"])
	_plain_settle = 0.6
	_apply_texture(path, false)


func _tick_plain_settle(delta: float) -> void:
	if _plain_settle < 0.0:
		return
	_plain_settle -= delta
	if _plain_settle > 0.0:
		return
	_plain_settle = -1.0
	var layer = _selected_layer()
	if layer != null and _plain_before != "" and _plain_before != str(layer["tex"]):
		_record_op({"type": "tex", "level_id": _cur_level_id, "uid": int(layer["uid"]), "before": _plain_before, "after": str(layer["tex"])})
	_plain_before = ""


func _on_tex_swatch_toggled(on: bool, idx: int) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	for i in range(_tex_swatches.size()):
		if i != idx:
			_tex_swatches[i].pressed = false
	_ui_syncing = false
	_tex_color_filter = TEX_PALETTE[idx] if on else null
	if on and _tex_custom_btn != null and is_instance_valid(_tex_custom_btn):
		_tex_custom_btn.color = TEX_PALETTE[idx]
	_sync_swatches()
	_populate_tex_list()


func _on_tex_custom_color(c: Color) -> void:
	_ui_syncing = true
	for b in _tex_swatches:
		b.pressed = false
	_ui_syncing = false
	_tex_color_filter = c
	_sync_swatches()
	_populate_tex_list()


func _on_tex_eyedrop_toggled(on: bool) -> void:
	_tex_eyedrop_armed = on
	_set_eyedrop_cursor(on)


func _set_eyedrop_cursor(on: bool) -> void:
	if on:
		if _eyedrop_cursor == null:
			var img = Image.new()
			if img.load(_root + "icons/eyedropper.png") == OK:
				img.convert(Image.FORMAT_RGBA8)
				if img.get_width() > 32:
					img.resize(32, 32, Image.INTERPOLATE_BILINEAR)
				var t = ImageTexture.new()
				t.create_from_image(img, Texture.FLAG_FILTER)
				_eyedrop_cursor = t
		if _eyedrop_cursor != null:
			# Hotspot at the tip (bottom-left of the glyph).
			Input.set_custom_mouse_cursor(_eyedrop_cursor, Input.CURSOR_ARROW, Vector2(0, _eyedrop_cursor.get_height() - 1))
	else:
		Input.set_custom_mouse_cursor(null)


func _on_tex_tol_changed(v: float) -> void:
	_tex_color_tol = v
	_save_brush_prefs()
	if _tex_color_filter != null:
		_populate_tex_list()


func _on_tex_color_clear() -> void:
	_ui_syncing = true
	for b in _tex_swatches:
		b.pressed = false
	if _tex_tol_slider != null and is_instance_valid(_tex_tol_slider):
		_tex_tol_slider.value = 0.3
	if _tex_custom_btn != null and is_instance_valid(_tex_custom_btn):
		_tex_custom_btn.color = Color(0, 0, 0, 1)
	_ui_syncing = false
	_tex_color_filter = null
	_tex_color_tol = 0.3
	_sync_swatches()
	_populate_tex_list()
	_save_brush_prefs()


# Average colour of a texture (from its thumbnail, alpha-weighted), cached.
func _tex_avg_color(path: String) -> Color:
	if _tex_avg_cache.has(path):
		return _tex_avg_cache[path]
	var avg = Color(0.5, 0.5, 0.5)
	var t = _thumb_for(path)
	if t != null and t is Texture:
		var img: Image = t.get_data()
		if img != null:
			img = img.duplicate()
			if img.get_format() != Image.FORMAT_RGBA8:
				img.convert(Image.FORMAT_RGBA8)
			img.resize(16, 16, Image.INTERPOLATE_BILINEAR)
			img.lock()
			var r = 0.0
			var g = 0.0
			var b = 0.0
			var wsum = 0.0
			for y in range(16):
				for x in range(16):
					var c = img.get_pixel(x, y)
					r += c.r * c.a
					g += c.g * c.a
					b += c.b * c.a
					wsum += c.a
			img.unlock()
			if wsum > 0.0:
				avg = Color(r / wsum, g / wsum, b / wsum)
	_tex_avg_cache[path] = avg
	return avg


# Perceptual-ish distance: hue difference dominates, value/saturation soften.
func _color_distance(a: Color, b: Color) -> float:
	var dh = abs(a.h - b.h)
	dh = min(dh, 1.0 - dh) * 2.0
	var hue_w = min(a.s, b.s) * min(a.v, b.v)   # hue is meaningless on grey/dark
	var ds = a.s - b.s
	var dv = a.v - b.v
	return sqrt(dh * dh * 4.0 * hue_w + ds * ds + dv * dv * 2.0) / sqrt(7.0)


func _tex_eyedrop_pick(screen_pos: Vector2) -> void:
	_tex_eyedrop_armed = false
	_set_eyedrop_cursor(false)
	if _tex_eyedrop_btn != null and is_instance_valid(_tex_eyedrop_btn):
		_tex_eyedrop_btn.pressed = false
	var vp = _g.Editor.get_viewport()
	if vp == null:
		return
	var img: Image = vp.get_texture().get_data()
	if img == null:
		return
	img.flip_y()   # viewport textures are stored upside down
	img.lock()
	var x = int(clamp(screen_pos.x, 0, img.get_width() - 1))
	var y = int(clamp(screen_pos.y, 0, img.get_height() - 1))
	var c = img.get_pixel(x, y)
	img.unlock()
	_ui_syncing = true
	for b in _tex_swatches:
		b.pressed = false
	_ui_syncing = false
	_tex_color_filter = Color(c.r, c.g, c.b)
	if _tex_custom_btn != null and is_instance_valid(_tex_custom_btn):
		_tex_custom_btn.color = _tex_color_filter
	_sync_swatches()
	_populate_tex_list()


func _on_lib_icon_size_changed(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_lib_size_spin.value = v
	_ui_syncing = false
	_lib_icon_size = v
	_apply_lib_icon_size()
	_save_brush_prefs()


func _on_lib_icon_size_spin(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_lib_size_slider.value = v
	_ui_syncing = false
	_lib_icon_size = v
	_apply_lib_icon_size()
	_save_brush_prefs()


func _on_tex_search(_t: String) -> void:
	_populate_tex_list()


func _by_key_pair(a, b) -> bool:
	if a[0] != b[0]:
		return a[0] < b[0]
	return str(a[1]) < str(b[1])


func _on_tex_sort_selected(idx: int) -> void:
	_tex_sort = idx
	_tex_hue_cache = {}
	_save_brush_prefs()
	_populate_tex_list()


# Colour ordering by DOMINANT hue: per-pixel hues weighted by saturation and
# value (the flat average washes everything towards brown). Textures without
# enough coloured pixels go to a grey bucket at the end, sorted by brightness.
var _tex_hue_cache := {}

func _tex_color_key(path: String) -> float:
	if _tex_hue_cache.has(path):
		return _tex_hue_cache[path]
	var key = 10.0
	var t = _thumb_for(path)
	if t != null and t is Texture:
		var img: Image = t.get_data()
		if img != null:
			img = img.duplicate()
			if img.get_format() != Image.FORMAT_RGBA8:
				img.convert(Image.FORMAT_RGBA8)
			img.resize(16, 16, Image.INTERPOLATE_BILINEAR)
			img.lock()
			# 18-bin hue histogram (weights = saturation * value): the DOMINANT
			# bin decides the hue. A global circular mean mixes unrelated hues
			# (teal + orange grains averaged into magenta...).
			var bins := []
			var bx := []
			var by := []
			for _i in range(18):
				bins.append(0.0)
				bx.append(0.0)
				by.append(0.0)
			var wsum = 0.0
			var vsum = 0.0
			var ssum = 0.0
			var asum = 0.0
			for y in range(16):
				for x in range(16):
					var c = img.get_pixel(x, y)
					if c.a < 0.5:
						continue
					asum += 1.0
					vsum += c.v
					ssum += c.s
					var w = c.s * c.v
					if w > 0.03:
						var bi = int(clamp(c.h * 18.0, 0, 17))
						bins[bi] += w
						var ang = c.h * TAU
						bx[bi] += cos(ang) * w
						by[bi] += sin(ang) * w
						wsum += w
			img.unlock()
			if asum > 0.0:
				var avg_v = vsum / asum
				var avg_s = ssum / asum
				if wsum / asum > 0.08:
					var best = 0
					for i in range(18):
						if bins[i] > bins[best]:
							best = i
					# Refine within the winning bin and its neighbours.
					var p = (best - 1 + 18) % 18
					var nx2 = (best + 1) % 18
					var hx = bx[best] + bx[p] + bx[nx2]
					var hy = by[best] + by[p] + by[nx2]
					var hue = fposmod(atan2(hy, hx) / TAU, 1.0)
					# Coarse hue bands, then vivid -> pale, then bright -> dark:
					# saturated lavas stop landing between two pale pinks.
					var band = int(fposmod(hue, 1.0) * 15.0)
					key = float(band) * 5.0 + (1.0 - avg_s) * 3.5 + (1.0 - avg_v) * 1.0
				else:
					key = 200.0 + (1.0 - avg_v)
	_tex_hue_cache[path] = key
	return key


func _on_tex_mode_cycle() -> void:
	_tex_view = (_tex_view + 1) % 3
	_update_tex_mode_button()
	_save_brush_prefs()
	_populate_tex_list()


func _update_tex_mode_button() -> void:
	_update_tex_count_label()
	if _tex_mode_btn == null or not is_instance_valid(_tex_mode_btn):
		return
	var m = _favorites_mod()
	if _tex_view == 1:
		_tex_mode_btn.text = "Show: Favorites"
		_tex_mode_btn.icon = m.get("_icon_star") if m != null else null
	elif _tex_view == 2:
		_tex_mode_btn.text = "Show: Hidden"
		_tex_mode_btn.icon = m.get("_icon_hidden") if m != null else null
	else:
		_tex_mode_btn.text = "Show: All"
		_tex_mode_btn.icon = null


func _tex_tab_paths() -> Array:
	_ensure_catalog()
	if _show_patterns:
		_ensure_pattern_catalog()
	var out = _catalog_paths.duplicate()
	if _show_patterns:
		out.append_array(_pattern_paths)
		out.sort()
	return out


func _populate_tex_list() -> void:
	if _tex_list == null or not is_instance_valid(_tex_list):
		return
	_reload_fav_set()
	_update_tex_count_label()
	_tex_list.clear()
	var fav_on = _favorites_mod() != null
	var q = ""
	if _tex_search != null and is_instance_valid(_tex_search):
		q = _tex_search.text.strip_edges().to_lower()
	var tab_paths = _tex_tab_paths()
	if _tex_sort == 1:
		var keyed := []
		for pth in tab_paths:
			keyed.append([_tex_color_key(pth), pth])
		keyed.sort_custom(self, "_by_key_pair")
		tab_paths = []
		for kv in keyed:
			tab_paths.append(kv[1])
	for path in tab_paths:
		var is_fav = fav_on and _is_fav(path)
		var hidden = fav_on and _tex_hidden.has(path)
		if fav_on:
			if _tex_view == 0 and hidden:
				continue
			if _tex_view == 1 and not is_fav:
				continue
			if _tex_view == 2 and not hidden:
				continue
		var name = _display_name(path)
		if q != "" and name.to_lower().find(q) < 0:
			continue
		if _tex_color_filter != null and _color_distance(_tex_avg_color(path), _tex_color_filter) > _tex_color_tol:
			continue
		var thumb = _tex_tab_thumb(path, is_fav)
		if thumb != null:
			_tex_list.add_item(name, thumb)
		else:
			_tex_list.add_item(name)
		var li = _tex_list.get_item_count() - 1
		_tex_list.set_item_tooltip(li, name + ("  (hidden)" if hidden else ""))
		_tex_list.set_item_metadata(li, path)
		var layer = _selected_layer()
		if layer != null and str(layer["tex"]) == path:
			_tex_list.select(li)


func _tex_tab_thumb(path: String, with_badge: bool):
	var key = path + ("|fav" if with_badge else "")
	if _tex_thumb_cache.has(key):
		return _tex_thumb_cache[key]
	var base = _thumb_for(path)
	if base == null:
		return null
	var img: Image = base.get_data()
	if img == null:
		return null
	img = img.duplicate()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	img.resize(64, 64, Image.INTERPOLATE_BILINEAR)
	if with_badge:
		var badge = _fav_badge_image(_fav_badge_size())
		if badge != null:
			img.blend_rect(badge, Rect2(0, 0, badge.get_width(), badge.get_height()), Vector2(64 - badge.get_width() - 2, 2))
	var t = ImageTexture.new()
	t.create_from_image(img, Texture.FLAG_FILTER)
	_tex_thumb_cache[key] = t
	return t


func _scroll_tex_list_to_selected() -> void:
	if _tex_list != null and is_instance_valid(_tex_list) and _tex_list.get_selected_items().size() > 0:
		_tex_list.ensure_current_is_visible()


func _on_tex_selected(idx: int) -> void:
	var path = _tex_list.get_item_metadata(idx)
	if path is String and _selected_layer() != null:
		_apply_texture(path)


func _on_tex_rmb(idx: int, at: Vector2) -> void:
	if _favorites_mod() == null:
		return
	var path = _tex_list.get_item_metadata(idx)
	if not (path is String):
		return
	if _tex_ctx_menu != null and is_instance_valid(_tex_ctx_menu):
		_tex_ctx_menu.queue_free()
	_tex_ctx_menu = PopupMenu.new()
	_right_panel.add_child(_tex_ctx_menu)
	var m = _favorites_mod()
	if _is_fav(path):
		_tex_ctx_menu.add_item("Remove from Favorites", 0)
		if m.get("_icon_unstar") != null:
			_tex_ctx_menu.set_item_icon(0, m._icon_unstar)
	else:
		_tex_ctx_menu.add_item("Add to Favorites", 0)
		if m.get("_icon_star") != null:
			_tex_ctx_menu.set_item_icon(0, m._icon_star)
	_tex_ctx_menu.add_item("Unhide texture" if _tex_hidden.has(path) else "Hide texture", 1)
	_tex_ctx_menu.connect("id_pressed", self, "_on_tex_ctx_pressed", [path])
	_tex_ctx_menu.popup(Rect2(_tex_list.rect_global_position + at, Vector2(1, 1)))


func _on_tex_ctx_pressed(id: int, path: String) -> void:
	var m = _favorites_mod()
	if id == 0 and m != null:
		if _is_fav(path):
			m._remove_from_favorites([{"tex_path": path}])
		else:
			m._add_to_favorites([{"tex_path": path, "type": 9, "thing": null}])
	elif id == 1:
		if _tex_hidden.has(path):
			_tex_hidden.erase(path)
		else:
			_tex_hidden[path] = true
		_save_brush_prefs()
	_populate_tex_list()


func _on_brush_mode_cycle() -> void:
	_brush_view = (_brush_view + 1) % 3
	_update_brush_mode_button()
	_save_brush_prefs()
	_populate_brush_list()


func _update_brush_mode_button() -> void:
	if _brush_mode_btn == null or not is_instance_valid(_brush_mode_btn):
		return
	var m = _favorites_mod()
	if _brush_view == BRUSH_VIEW_FAV:
		_brush_mode_btn.text = "Show: Favorites"
		_brush_mode_btn.icon = m.get("_icon_star") if m != null else null
	elif _brush_view == BRUSH_VIEW_HIDDEN:
		_brush_mode_btn.text = "Show: Hidden"
		_brush_mode_btn.icon = m.get("_icon_hidden") if m != null else null
	else:
		_brush_mode_btn.text = "Show: All"
		_brush_mode_btn.icon = null


func _on_brush_rmb(idx: int, at: Vector2) -> void:
	var meta = _brush_list.get_item_metadata(idx)
	if meta == null:
		return
	var path = _brush_paths[int(meta)]
	var k = _brush_key_of(path)
	if _brush_ctx_menu != null and is_instance_valid(_brush_ctx_menu):
		_brush_ctx_menu.queue_free()
	_brush_ctx_menu = PopupMenu.new()
	_right_panel.add_child(_brush_ctx_menu)
	var m = _favorites_mod()
	if _brush_fav.has(k):
		_brush_ctx_menu.add_item("Remove from Favorites", 0)
		if m != null and m.get("_icon_unstar") != null:
			_brush_ctx_menu.set_item_icon(0, m._icon_unstar)
	else:
		_brush_ctx_menu.add_item("Add to Favorites", 0)
		if m != null and m.get("_icon_star") != null:
			_brush_ctx_menu.set_item_icon(0, m._icon_star)
	_brush_ctx_menu.add_item("Unhide brush" if _brush_hidden.has(k) else "Hide brush", 1)
	_brush_ctx_menu.add_check_item("Invert brush colors", 2)
	_brush_ctx_menu.set_item_checked(_brush_ctx_menu.get_item_index(2), _brush_inverted.has(k))
	_brush_ctx_menu.connect("id_pressed", self, "_on_brush_ctx_pressed", [k])
	_brush_ctx_menu.popup(Rect2(_brush_list.rect_global_position + at, Vector2(1, 1)))


func _on_brush_ctx_pressed(id: int, k: String) -> void:
	if id == 0:
		if _brush_fav.has(k):
			_brush_fav.erase(k)
		else:
			_brush_fav[k] = true
	elif id == 1:
		if _brush_hidden.has(k):
			_brush_hidden.erase(k)
		else:
			_brush_hidden[k] = true
	elif id == 2:
		if _brush_inverted.has(k):
			_brush_inverted.erase(k)
		else:
			_brush_inverted[k] = true
		for ck in _brush_thumb_cache.keys():
			if _brush_key_of(str(ck).split("|")[0]) == k:
				_brush_thumb_cache.erase(ck)
		_brush_variants = {}
		_first_variant = null
		_load_brush_src()
	_save_brush_prefs()
	_populate_brush_list()


func _on_brush_selected(idx: int) -> void:
	var meta = _brush_list.get_item_metadata(idx)
	if meta == null:
		return
	_brush_idx = int(meta)
	_load_brush_src()


func _on_mode_selected(idx: int) -> void:
	_stroke_mode = idx


func _mk_random_btn(pressed_now: bool, handler: String, tip: String) -> Button:
	var b = Button.new()
	b.toggle_mode = true
	b.pressed = pressed_now
	if _random_icon == null:
		_random_icon = _load_icon(_root + "icons/random.png", 0.5)
	if _random_icon != null:
		b.icon = _random_icon
	else:
		b.text = "?"
	b.hint_tooltip = tip
	b.connect("toggled", self, handler)
	return b


func _on_size_spin(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_size_slider.value = _slider_from_size(v)
	_ui_syncing = false
	_set_brush_size(v)


func _on_hardness_spin(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_hardness_slider.value = v
	_ui_syncing = false
	_on_hardness_changed(v)


func _on_flow_spin(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_flow_slider.value = v
	_ui_syncing = false
	_on_flow_changed(v)


# In random mode, show the rolled value of the NEXT click on the sliders
# (display only: guarded so it does not write back as a fixed value).
func _sync_random_sliders() -> void:
	_ui_syncing = true
	if _brush_random_rot and _rot_slider != null and is_instance_valid(_rot_slider):
		var deg = round(rad2deg(fposmod(_preview_rot, TAU)))
		_rot_slider.value = deg
		if _rot_spin != null and is_instance_valid(_rot_spin):
			_rot_spin.value = deg
	if _brush_random_ratio and _ratio_slider != null and is_instance_valid(_ratio_slider):
		_ratio_slider.value = _preview_ratio
		if _ratio_spin != null and is_instance_valid(_ratio_spin):
			_ratio_spin.value = _preview_ratio
	_ui_syncing = false


func _on_rot_slider_changed(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_rot_spin.value = v
	_ui_syncing = false
	_brush_rot_fixed = v
	_brush_variants = {}
	# Applies right away, even in random mode: the preview and the next
	# stroke's first stamp use this value (later stamps roll again).
	_preview_rot = deg2rad(v)
	_save_brush_prefs()


func _on_rot_spin(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_rot_slider.value = v
	_ui_syncing = false
	_on_rot_slider_changed(v)


func _on_ratio_slider_changed(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_ratio_spin.value = v
	_ui_syncing = false
	_brush_ratio_fixed = v
	_brush_variants = {}
	_preview_ratio = v
	_save_brush_prefs()


func _on_ratio_spin(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_ratio_slider.value = v
	_ui_syncing = false
	_on_ratio_slider_changed(v)


func _on_ratio_toggled(on: bool) -> void:
	_brush_random_ratio = on
	_brush_variants = {}
	_preview_ratio = _rand_ratio()
	_save_brush_prefs()


func _on_rot_toggled(on: bool) -> void:
	_brush_random_rot = on
	if not on:
		_preview_rot = deg2rad(_brush_rot_fixed)
	_brush_variants = {}


func _on_continuous_toggled(on: bool) -> void:
	_brush_continuous = on


# Move our toolbar button to TOOL_POSITION inside its category (between the
# Terrain brush and the Water brush). DD's Toolset does not expose the
# button, so we look it up by name in the Toolset subtree.
func _place_toolbar_button() -> void:
	var toolset = _g.Editor.Toolset
	if toolset == null:
		return
	var toolbars = toolset.get("Toolbars")
	if not (toolbars is Dictionary) or not toolbars.has(TOOL_CATEGORY):
		return
	var toolbar = toolbars[TOOL_CATEGORY]
	if toolbar == null or not is_instance_valid(toolbar):
		return
	# ToolbarButton exposes its tool id through the C# "Tool" property.
	var ours = _find_toolbar_button(toolbar, TOOL_ID)
	var anchor = _find_toolbar_button(toolbar, "TerrainBrush")
	if ours == null:
		print("[BetterTerrain] Toolbar button not found; leaving default position.")
		return
	var parent = ours.get_parent()
	var idx = TOOL_POSITION
	if anchor != null and anchor.get_parent() == parent:
		idx = anchor.get_index() + 1
	parent.move_child(ours, min(idx, parent.get_child_count() - 1))


func _find_toolbar_button(root, tool_id: String):
	var stack = [root]
	while not stack.empty():
		var n = stack.pop_back()
		if n is Button:
			var t = n.get("Tool")
			if t != null and str(t) == tool_id:
				return n
		for c in n.get_children():
			stack.push_back(c)
	return null


func _on_size_changed(v: float) -> void:
	if _ui_syncing:
		return
	_set_brush_size(_size_from_slider(v))


func _on_hardness_changed(v: float) -> void:
	_brush_hardness = v
	if _adjust_active:
		return
	if not _ui_syncing and _hard_spin != null and is_instance_valid(_hard_spin):
		_ui_syncing = true
		_hard_spin.value = v
		_ui_syncing = false


func _on_roundness_changed(v: float) -> void:
	_brush_roundness = v
	if _adjust_active:
		return   # Alt-drag session: caches / prefs are handled at release
	if not _ui_syncing and _round_spin != null and is_instance_valid(_round_spin):
		_ui_syncing = true
		_round_spin.value = v
		_ui_syncing = false
	_brush_variants = {}
	_first_variant = null
	_prefs_dirty_at = OS.get_ticks_msec()


func _on_roundness_spin(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_round_slider.value = v
	_ui_syncing = false
	_on_roundness_changed(v)


func _on_flow_changed(v: float) -> void:
	_brush_flow = v
	if not _ui_syncing and _flow_spin != null and is_instance_valid(_flow_spin):
		_ui_syncing = true
		_flow_spin.value = v
		_ui_syncing = false


func _on_fill() -> void:
	_fill_layer(1.0)


func _on_organic_fill() -> void:
	_organic_fill(false)


# Organic random coverage from OpenSimplex noise: soft-edged blobs covering
# about half the layer. "all" gives every slot of the level its own seed, and
# the LOWEST layer is filled completely so no spot is left uncovered.
func _organic_fill(all: bool) -> void:
	var targets := []
	if all:
		targets = _cur_layers().duplicate()
		targets.sort_custom(self, "_by_z")
	else:
		var g = _sel_grp()
		targets = _grp_member_layers(g) if g != null else _edit_targets()
		targets.sort_custom(self, "_by_z")
	if targets.empty():
		return
	# Fresh recipe per slot (seeds, scale, detail, requested coverage and the
	# z taper): stored on the layer so the post-generation Coverage slider
	# can re-threshold the SAME noise later.
	var first = 1 if all else 0   # the "all" base slot is a full fill, not a rung
	var rungs = targets.size() - first
	var recipes := []
	for li in range(targets.size()):
		# Higher slots hide the ones below: taper the coverage as z rises.
		# The lowest generated slot gets the requested coverage, the topmost
		# ~40% of it, linearly in between (multi-selection and groups alike).
		var taper = 1.0
		if rungs > 1 and li >= first:
			taper = lerp(1.0, 0.4, float(li - first) / float(rungs - 1))
		recipes.append({"seed_a": randi(), "seed_b": randi(), "scale": _organic_scale, "detail": _organic_detail,
			"cov": clamp(_organic_coverage / 100.0, 0.0, 1.0), "taper": taper, "base": all and li == 0})
	_organic_run(targets, recipes, "Generating organic terrain…")


# Render every target from its recipe (a coroutine with the progress popup).
func _organic_run(targets: Array, recipes: Array, title: String) -> void:
	_organic_popup_open(title)
	var tree = _g.Editor.get_tree()
	yield(tree, "idle_frame")   # let the popup paint before the number crunching
	for li in range(targets.size()):
		var layer = targets[li]
		var gen: Dictionary = recipes[li]
		var mask: Image = layer["mask"]
		var before = mask.duplicate()
		var w = mask.get_width()
		var h = mask.get_height()
		var base = bool(gen.get("base", false))   # bottom "all" slot: full coverage, no holes
		# Two noise scales: big blobs shaped by the low frequency, coastlines
		# and inner nuance carved by a higher-frequency detail noise.
		var noise = OpenSimplexNoise.new()
		noise.seed = int(gen["seed_a"])
		noise.octaves = 5
		noise.period = max(w, h) / 4.0 * float(gen["scale"])
		noise.persistence = 0.55
		var detail = OpenSimplexNoise.new()
		detail.seed = int(gen["seed_b"])
		detail.octaves = 3
		detail.period = max(w, h) / 18.0 * float(gen["scale"])
		detail.persistence = 0.6
		var dw = float(gen["detail"])
		var cov = clamp(float(gen["cov"]) * float(gen.get("taper", 1.0)), 0.0, 1.0)
		var thr = lerp(0.45, -0.45, cov)
		var edge = 0.10   # soft ramp width around the threshold
		mask.lock()
		for y in range(h):
			for x in range(w):
				if base:
					mask.set_pixel(x, y, Color(1, 1, 1, 1))
				else:
					var n = noise.get_noise_2d(x, y) + dw * detail.get_noise_2d(x, y)
					var v = clamp((n - thr + edge) / (2.0 * edge), 0.0, 1.0)
					# Inner nuance, faded in CONTINUOUSLY with the depth inside
					# the blob. The previous version replaced v only past the
					# ramp's top, leaving a thin FULL-opacity ring along every
					# contour (the "liseré").
					if dw > 0.0:
						var inner = clamp((n - thr - edge) / 0.5, 0.0, 1.0)
						var m = 0.55 + 0.45 * (0.5 + 0.5 * detail.get_noise_2d(x + 4096, y))
						v *= lerp(1.0, m, inner * dw)
					mask.set_pixel(x, y, Color(v, v, v, 1))
			if y % 64 == 63:
				mask.unlock()
				_organic_popup_progress((li + float(y) / h) / targets.size(), layer["name"])
				yield(tree, "idle_frame")
				mask.lock()
		mask.unlock()
		layer["gen"] = gen.duplicate()
		_upload_mask(layer)
		_record(layer, before, mask.duplicate())
		layer["dirty"] = true
		_organic_popup_progress(float(li + 1) / targets.size(), layer["name"])
		yield(tree, "idle_frame")
	_schedule_persist()
	_organic_popup_close()
	_sync_organic_post()


# Layers of the current selection that carry a generation recipe.
func _gen_targets() -> Array:
	var g = _sel_grp()
	var out := []
	for l in (_grp_member_layers(g) if g != null else _edit_targets()):
		if l.get("gen") is Dictionary and not bool(l["gen"].get("base", false)):
			out.append(l)
	return out


# Post-generation Coverage row: visible only when the selection holds
# generated layers; shows the requested coverage of the first of them.
func _sync_organic_post() -> void:
	if _og_post_row == null or not is_instance_valid(_og_post_row):
		return
	var gl = _gen_targets()
	_og_post_row.visible = not gl.empty()
	if gl.empty():
		return
	_ui_syncing = true
	var v = round(float(gl[0]["gen"]["cov"]) * 100.0)
	_og_post_slider.value = v
	_og_post_spin.value = v
	_ui_syncing = false


func _on_post_cov_drag_ended(_changed: bool) -> void:
	_post_cov_commit()


func _on_post_cov_gui_input(event) -> void:
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and not event.pressed:
		call_deferred("_post_cov_commit")   # after the slider has taken the final value


func _on_post_cov_spin(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_og_post_slider.value = v
	_ui_syncing = false
	_post_cov_pending = true
	_post_cov_commit()


func _on_post_cov_slider(v: float) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_og_post_spin.value = v   # mirror while dragging; applied on release
	_ui_syncing = false
	_post_cov_pending = true


func _post_cov_commit() -> void:
	if not _post_cov_pending:
		return
	_post_cov_pending = false
	_apply_post_coverage(_og_post_slider.value)


# Re-threshold the stored noise of every generated layer in the selection
# at a new requested coverage (its z taper is preserved).
func _apply_post_coverage(v: float) -> void:
	var targets = _gen_targets()
	if targets.empty():
		return
	var recipes := []
	for l in targets:
		var gen = l["gen"].duplicate()
		gen["cov"] = clamp(v / 100.0, 0.0, 1.0)
		recipes.append(gen)
	_organic_run(targets, recipes, "Adjusting coverage…")


var _organic_box: VBoxContainer = null
var _organic_ui := []
var _og_scale_slider: HSlider = null
var _og_scale_spin: SpinBox = null
var _og_detail_slider: HSlider = null
var _og_detail_spin: SpinBox = null
var _og_cov_slider: HSlider = null
var _og_cov_spin: SpinBox = null
var _og_gen_btn: Button = null
var _og_post_row: HBoxContainer = null
var _og_post_slider: HSlider = null
var _og_post_spin: SpinBox = null
var _post_cov_pending := false


# "Generate" / "Generate (Multi)" depending on how many slots it will fill.
func _update_generate_label() -> void:
	if _og_gen_btn == null or not is_instance_valid(_og_gen_btn):
		return
	var g = _sel_grp()
	var n = _grp_member_layers(g).size() if g != null else _edit_targets().size()
	_og_gen_btn.text = "Procedural Generation (Multi)" if n > 1 else "Procedural Generation"
var _organic_scale := 1.0
var _organic_detail := 0.65
var _organic_coverage := 55.0

func _on_organic_cog_toggled(on: bool) -> void:
	if _organic_box != null and is_instance_valid(_organic_box):
		_organic_box.visible = on


func _og_pair(v: float, slider: HSlider, spin: SpinBox, from_spin: bool) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	if from_spin and slider != null and is_instance_valid(slider):
		slider.value = v
	elif spin != null and is_instance_valid(spin):
		spin.value = v
	_ui_syncing = false


func _on_organic_scale(v: float) -> void:
	_og_pair(v, _og_scale_slider, _og_scale_spin, false)
	_organic_scale = v
	_save_brush_prefs()


func _on_organic_scale_spin(v: float) -> void:
	_og_pair(v, _og_scale_slider, _og_scale_spin, true)
	_organic_scale = v
	_save_brush_prefs()


func _on_organic_detail(v: float) -> void:
	_og_pair(v, _og_detail_slider, _og_detail_spin, false)
	_organic_detail = v
	_save_brush_prefs()


func _on_organic_detail_spin(v: float) -> void:
	_og_pair(v, _og_detail_slider, _og_detail_spin, true)
	_organic_detail = v
	_save_brush_prefs()


func _on_organic_coverage(v: float) -> void:
	_og_pair(v, _og_cov_slider, _og_cov_spin, false)
	_organic_coverage = v
	_save_brush_prefs()


func _on_organic_coverage_spin(v: float) -> void:
	_og_pair(v, _og_cov_slider, _og_cov_spin, true)
	_organic_coverage = v
	_save_brush_prefs()


var _organic_panel = null
var _organic_bar: ProgressBar = null
var _organic_label: Label = null

func _organic_popup_open(title: String) -> void:
	_organic_popup_close()
	var panel = PanelContainer.new()
	panel.rect_min_size = Vector2(360, 0)
	# DD-like dark panel (same styling as ShadowBakeAll's progress popup).
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.11, 0.12, 0.98)
	sb.border_color = Color(0, 0, 0, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	panel.add_stylebox_override("panel", sb)
	var vb = VBoxContainer.new()
	vb.add_constant_override("separation", 8)
	_organic_label = Label.new()
	_organic_label.text = title
	vb.add_child(_organic_label)
	_organic_bar = ProgressBar.new()
	_organic_bar.min_value = 0
	_organic_bar.max_value = 100
	_organic_bar.value = 0
	vb.add_child(_organic_bar)
	panel.add_child(vb)
	_g.Editor.add_child(panel)
	var vp = _g.Editor.get_viewport().get_visible_rect().size
	panel.rect_position = ((vp - panel.rect_size) / 2.0).floor()
	_organic_panel = panel


func _organic_popup_progress(frac: float, layer_name: String) -> void:
	if _organic_bar != null and is_instance_valid(_organic_bar):
		_organic_bar.value = clamp(frac, 0.0, 1.0) * 100.0
	if _organic_label != null and is_instance_valid(_organic_label):
		_organic_label.text = "Generating organic terrain… " + str(layer_name)


func _organic_popup_close() -> void:
	if _organic_panel != null and is_instance_valid(_organic_panel):
		if _organic_panel.get_parent() != null:
			_organic_panel.get_parent().remove_child(_organic_panel)
		_organic_panel.queue_free()
	_organic_panel = null
	_organic_bar = null
	_organic_label = null


func _on_clear() -> void:
	_fill_layer(0.0)


# ── Texture picker ────────────────────────────────────────────────────────────

func _on_pick_texture() -> void:
	var layer = _selected_layer()
	if layer == null:
		return
	_ensure_catalog()
	_ensure_picker()
	_picker_original = str(layer["tex"])
	_picker_search.text = ""
	_picker_query = ""
	_populate_pack_list()
	# Open on the pack holding the current texture.
	var grp = ALL_GROUP
	for g in _pack_order:
		if _picker_original in _pack_groups.get(g, []):
			grp = g
			break
	var li = _picker_groups.find(grp)
	if li < 0:
		li = 0
	if _pack_list.get_item_count() > 0:
		_pack_list.select(li)
		_populate_grid(_picker_groups[li])
	_picker_win.popup_centered(Vector2(1040, 700))
	_picker_search.grab_focus()


func _ensure_picker() -> void:
	if _picker_win != null and is_instance_valid(_picker_win):
		return
	_picker_win = WindowDialog.new()
	_picker_win.window_title = "Choose a terrain texture"
	_picker_win.rect_min_size = Vector2(1040, 700)
	var root = VBoxContainer.new()
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.margin_left = 8
	root.margin_top = 8
	root.margin_right = -8
	root.margin_bottom = -8
	_picker_win.add_child(root)

	var search_row = HBoxContainer.new()
	var search_lbl = Label.new()
	search_lbl.text = "Search"
	search_row.add_child(search_lbl)
	_picker_search = LineEdit.new()
	_picker_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_search.placeholder_text = "Filter terrains by name…"
	_picker_search.connect("text_changed", self, "_on_picker_search")
	search_row.add_child(_picker_search)
	_show_patterns_check = CheckButton.new()
	_show_patterns_check.text = "Show patterns"
	_show_patterns_check.hint_tooltip = "Also list pattern and tileset textures (except those sharing a terrain's name within the same pack)."
	_show_patterns_check.pressed = _show_patterns
	if _show_patterns:
		_ensure_pattern_catalog()
	_show_patterns_check.connect("toggled", self, "_on_show_patterns_toggled")
	search_row.add_child(_show_patterns_check)
	root.add_child(search_row)

	var content = HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(content)
	_pack_list = ItemList.new()
	_pack_list.rect_min_size = Vector2(190, 0)
	_pack_list.connect("item_selected", self, "_on_pack_selected")
	content.add_child(_pack_list)
	var scroll = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)
	_picker_grid = GridContainer.new()
	_picker_grid.columns = 5
	_picker_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_picker_grid)

	# Accept | live-preview toggle | Cancel
	var bar = HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGN_CENTER
	bar.set("custom_constants/separation", 16)
	bar.rect_min_size = Vector2(0, 48)
	root.add_child(bar)
	_picker_accept_btn = Button.new()
	_picker_accept_btn.text = "Accept"
	_picker_accept_btn.rect_min_size = Vector2(120, 34)
	_add_btn_border(_picker_accept_btn)
	_picker_accept_btn.connect("pressed", self, "_picker_accept")
	bar.add_child(_picker_accept_btn)
	var tgl = Button.new()
	tgl.toggle_mode = true
	tgl.pressed = _picker_accept_required
	tgl.rect_min_size = Vector2(44, 34)
	tgl.align = Button.ALIGN_CENTER
	tgl.set("icon_align", Button.ALIGN_CENTER)   # Godot 3.4+
	tgl.hint_tooltip = "On: a click applies the texture but keeps the popup open (Accept confirms, Cancel reverts). Off: a click applies and closes."
	var circle = _load_icon(_root + "icons/white-circle-icon.png")
	tgl.icon = circle if circle != null else _make_circle_icon(18)
	tgl.connect("toggled", self, "_on_picker_toggle")
	bar.add_child(tgl)
	_picker_cancel_btn = Button.new()
	_picker_cancel_btn.text = "Cancel"
	_picker_cancel_btn.rect_min_size = Vector2(120, 34)
	_add_btn_border(_picker_cancel_btn)
	_picker_cancel_btn.connect("pressed", self, "_picker_cancel")
	bar.add_child(_picker_cancel_btn)
	_set_picker_buttons_enabled(_picker_accept_required)

	_g.Editor.get_tree().get_root().add_child(_picker_win)
	if Engine.has_meta("popup_blur_singleton"):
		var pb = Engine.get_meta("popup_blur_singleton")
		if pb != null and pb.has_method("register"):
			pb.register(_picker_win)


func _populate_pack_list() -> void:
	_reload_fav_set()
	var have_favs = not _loaded_fav_paths().empty()
	_picker_groups = []
	if have_favs:
		_picker_groups.append(FAV_GROUP)
	_picker_groups.append(ALL_GROUP)
	for g in _pack_order:
		_picker_groups.append(g)
	_pack_list.clear()
	for g in _picker_groups:
		_pack_list.add_item(g)
	if have_favs:
		var m = _favorites_mod()
		if m != null and m.get("_icon_star") != null:
			_pack_list.set_item_icon(0, m._icon_star)


func _on_pack_selected(idx: int) -> void:
	if idx >= 0 and idx < _picker_groups.size():
		_populate_grid(_picker_groups[idx])


func _on_picker_search(text: String) -> void:
	_picker_query = text.strip_edges()
	_populate_grid(_picker_group)


func _populate_grid(group: String) -> void:
	_picker_group = group
	var paths = _paths_for_group(group)
	if _picker_query != "":
		var ql = _picker_query.to_lower()
		var filtered := []
		for path in paths:
			if _display_name(path).to_lower().find(ql) >= 0:
				filtered.append(path)
		paths = filtered
	_fill_grid(paths)


func _paths_for_group(group: String) -> Array:
	if group == FAV_GROUP:
		return _loaded_fav_paths()
	if group == ALL_GROUP:
		if _show_patterns:
			var all = _catalog_paths.duplicate()
			all.append_array(_pattern_paths)
			all.sort()
			return all
		return _catalog_paths
	var out = _pack_groups.get(group, []).duplicate()
	if _show_patterns:
		out.append_array(_pattern_by_pack.get(group, []))
		out.sort()
	return out


func _on_show_patterns_toggled(on: bool) -> void:
	_show_patterns = on
	_ui_syncing = true
	if _show_patterns_check != null and is_instance_valid(_show_patterns_check) and _show_patterns_check.pressed != on:
		_show_patterns_check.pressed = on
	if _show_patterns_check2 != null and is_instance_valid(_show_patterns_check2) and _show_patterns_check2.pressed != on:
		_show_patterns_check2.pressed = on
	_ui_syncing = false
	_save_brush_prefs()
	if on:
		_ensure_pattern_catalog()
	if _picker_grid != null and is_instance_valid(_picker_grid):
		_populate_grid(_picker_group)
	_populate_tex_list()


# Pattern + tileset textures from the Pattern / Floor tools' libraries.
# Skipped: a texture whose display name matches a terrain of the same pack.
func _ensure_pattern_catalog() -> void:
	if not _pattern_paths.empty():
		return
	var tools = _g.Editor.get("Tools")
	if not (tools is Dictionary):
		return
	var lists := []
	for tn in ["PatternShapeTool", "FloorShapeTool", "MaterialBrush"]:
		var t = tools.get(tn)
		if t == null or not is_instance_valid(t):
			continue
		var tm = t.get("textureMenu")
		if tm != null and is_instance_valid(tm) and tm is ItemList:
			lists.append(tm)
		var controls = t.get("Controls")
		if controls is Dictionary:
			for k in controls.keys():
				var c = controls[k]
				if c != null and is_instance_valid(c) and c is ItemList and not (c in lists):
					lists.append(c)
	# Terrain names per pack root (path up to "/textures/") for the exclusion.
	var terrain_names := {}
	var root_to_pack := {}
	for g in _pack_order:
		for tp in _pack_groups.get(g, []):
			var pr = _pack_root(tp)
			root_to_pack[pr] = g
			terrain_names[pr + "|" + _display_name(tp).to_lower()] = true
	var seen := {}
	for il in lists:
		var lookup = il.get("Lookup")
		if not (lookup is Dictionary):
			continue
		var count = il.get_item_count()
		for path in lookup:
			if not (path is String):
				continue
			if not ("textures/patterns" in path or "textures/tilesets" in path):
				continue
			if seen.has(path):
				continue
			var idx = lookup[path]
			if not (idx is int) or idx < 0 or idx >= count:
				continue
			var pr = _pack_root(path)
			if terrain_names.has(pr + "|" + _display_name(path).to_lower()):
				continue
			seen[path] = true
			_thumb_by_path[path] = il.get_item_icon(idx)
			_pattern_paths.append(path)
			var pack = root_to_pack.get(pr, "")
			if pack != "":
				if not _pattern_by_pack.has(pack):
					_pattern_by_pack[pack] = []
				_pattern_by_pack[pack].append(path)
	_pattern_paths.sort()


func _pack_root(path: String) -> String:
	var i = path.find("/textures/")
	return path.substr(0, i) if i >= 0 else ""


func _fill_grid(paths: Array) -> void:
	if _picker_grid == null:
		return
	for c in _picker_grid.get_children():
		_picker_grid.remove_child(c)
		c.queue_free()
	var layer = _selected_layer()
	var cur = str(layer["tex"]) if layer != null else ""
	for path in paths:
		var cell = VBoxContainer.new()
		var frame = Control.new()
		frame.rect_min_size = Vector2(150, 150)
		var b = Button.new()
		b.expand_icon = true
		b.anchor_right = 1.0
		b.anchor_bottom = 1.0
		b.icon = _thumb_by_path.get(path, null)
		b.hint_tooltip = _display_name(path)
		b.connect("pressed", self, "_choose_texture", [path])
		b.connect("gui_input", self, "_on_thumb_gui_input", [path])
		if path == cur:
			_apply_sel_style(b)
		frame.add_child(b)
		if _is_fav(path):
			var badge_tex = _fav_badge_tex()
			if badge_tex != null:
				var bs = _fav_badge_size()
				var badge = TextureRect.new()
				badge.texture = badge_tex
				badge.expand = true
				badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
				badge.rect_min_size = Vector2(bs, bs)
				badge.anchor_left = 1.0
				badge.anchor_right = 1.0
				badge.margin_left = -(bs + 4)
				badge.margin_right = -4
				badge.margin_top = 4
				badge.margin_bottom = 4 + bs
				frame.add_child(badge)
		cell.add_child(frame)
		var lbl = Label.new()
		lbl.text = _display_name(path)
		lbl.align = Label.ALIGN_CENTER
		lbl.clip_text = true
		lbl.rect_min_size = Vector2(150, 0)
		cell.add_child(lbl)
		_picker_grid.add_child(cell)


func _choose_texture(path) -> void:
	_apply_texture(str(path))
	if _picker_accept_required:
		_populate_grid(_picker_group)   # refresh the selection highlight
	elif _picker_win != null:
		_picker_win.hide()


func _picker_accept() -> void:
	if _picker_win != null:
		_picker_win.hide()


func _picker_cancel() -> void:
	if _picker_original != "":
		_apply_texture(_picker_original, false)
	if _picker_win != null:
		_picker_win.hide()


func _on_picker_toggle(pressed: bool) -> void:
	_picker_accept_required = pressed
	_set_picker_buttons_enabled(pressed)


func _set_picker_buttons_enabled(enabled: bool) -> void:
	if _picker_accept_btn != null and is_instance_valid(_picker_accept_btn):
		_picker_accept_btn.disabled = not enabled
	if _picker_cancel_btn != null and is_instance_valid(_picker_cancel_btn):
		_picker_cancel_btn.disabled = not enabled


func _apply_sel_style(btn: Button) -> void:
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.55, 0.45, 0.05, 0.25)
	sb.set_border_width_all(3)
	sb.border_color = Color(1.0, 0.85, 0.1)
	for st in ["normal", "hover", "pressed", "focus"]:
		btn.add_stylebox_override(st, sb)


func _add_btn_border(btn: Button) -> void:
	for st in ["normal", "hover", "pressed", "focus"]:
		var existing = btn.get_stylebox(st, "Button")
		var sb = StyleBoxFlat.new()
		if existing != null and existing is StyleBoxFlat:
			sb = existing.duplicate()
		sb.set_border_width_all(1)
		sb.border_color = Color(1, 1, 1, 1)
		btn.add_stylebox_override(st, sb)


func _make_circle_icon(size: int) -> ImageTexture:
	var img = Image.new()
	img.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c = (size - 1) * 0.5
	img.lock()
	for y in range(size):
		for x in range(size):
			var d = Vector2(x - c, y - c).length()
			var a = clamp(c - d + 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	img.unlock()
	var t = ImageTexture.new()
	t.create_from_image(img, Texture.FLAG_FILTER)
	return t


# ── Favorites (Unofficial Patch "Favorites" mod, terrain type 9) ─────────────
# Only active when the Favorites singleton is present: we never write its
# favorites.json ourselves.

func _favorites_mod():
	if not Engine.has_meta("favorites_singleton"):
		return null
	var m = Engine.get_meta("favorites_singleton")
	if m != null and is_instance_valid(m) and m.has_method("_add_to_favorites"):
		return m
	return null


func _reload_fav_set() -> void:
	_fav_set = {}
	var m = _favorites_mod()
	if m == null:
		return
	var favs = m.get("_favorites")
	if favs is Dictionary:
		for k in favs.keys():
			var info = favs[k]
			if info is Dictionary and int(info.get("type", -1)) == 9:
				_fav_set[k] = true


func _is_fav(path) -> bool:
	return path != null and _fav_set.has(path)


func _loaded_fav_paths() -> Array:
	var out := []
	for pp in _fav_set.keys():
		if _thumb_by_path.has(pp):
			out.append(pp)
	out.sort()
	return out


func _fav_badge_size() -> int:
	var m = _favorites_mod()
	if m != null and m.get("_badge_size_value") != null:
		return int(m._badge_size_value)
	return 16


func _fav_badge_image(size: int):
	var img = Image.new()
	var ok = img.load(_root + "icons/fav1.png") == OK
	if not ok:
		var m = _favorites_mod()
		if m != null and m.get("_icon_fav_badge_img") != null:
			img = m._icon_fav_badge_img.duplicate()
			ok = true
	if not ok:
		return null
	img.convert(Image.FORMAT_RGBA8)
	img.resize(size, size, Image.INTERPOLATE_LANCZOS)
	return img


func _fav_badge_tex():
	var m = _favorites_mod()
	if m != null and m.has_method("_get_scaled_badge"):
		return m._get_scaled_badge(_fav_badge_size())
	return null


func _on_thumb_gui_input(event, path) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == BUTTON_RIGHT:
		if _favorites_mod() != null:
			_show_fav_context_menu(event.global_position, path)


func _show_fav_context_menu(global_pos: Vector2, path) -> void:
	if _fav_ctx_menu != null and is_instance_valid(_fav_ctx_menu):
		_fav_ctx_menu.queue_free()
	_fav_ctx_menu = PopupMenu.new()
	_picker_win.add_child(_fav_ctx_menu)
	var m = _favorites_mod()
	if _is_fav(path):
		_fav_ctx_menu.add_item("Remove from Favorites", 1)
		if m.get("_icon_unstar") != null:
			_fav_ctx_menu.set_item_icon(0, m._icon_unstar)
	else:
		_fav_ctx_menu.add_item("Add to Favorites", 0)
		if m.get("_icon_star") != null:
			_fav_ctx_menu.set_item_icon(0, m._icon_star)
	_fav_ctx_menu.connect("id_pressed", self, "_on_fav_ctx_pressed", [path])
	_fav_ctx_menu.popup(Rect2(global_pos, Vector2(1, 1)))


func _on_fav_ctx_pressed(_id: int, path) -> void:
	var m = _favorites_mod()
	if m == null:
		return
	if _is_fav(path):
		m._remove_from_favorites([{"tex_path": path}])
	else:
		m._add_to_favorites([{"tex_path": path, "type": 9, "thing": null}])
	var keep = _picker_group
	_populate_pack_list()
	var li = _picker_groups.find(keep)
	if li < 0:
		li = 0
	if _pack_list.get_item_count() > 0:
		_pack_list.select(li)
	_populate_grid(_picker_groups[li])


func _set_layer_texture(layer: Dictionary, path: String) -> void:
	layer["tex"] = path
	var tex = _load_texture(path)
	layer["mat"].set_shader_param("tile", tex)
	layer["mat"].set_shader_param("tile_size", tex.get_size())
	_apply_color_params(layer, layer["mat"])
	if layer["auto_name"]:
		layer["name"] = _display_name(path)
	_persist()
	_refresh_layer_list()


func _apply_texture(path: String, record := true) -> void:
	var layer = _selected_layer()
	if layer == null:
		return
	var before = str(layer["tex"])
	if record and before != path:
		_record_op({"type": "tex", "level_id": _cur_level_id, "uid": int(layer["uid"]), "before": before, "after": path})
	_set_layer_texture(layer, path)
	if bool(layer.get("light_paint", false)) and _cur_entry() != null:
		_light_update(_cur_entry(), layer)
