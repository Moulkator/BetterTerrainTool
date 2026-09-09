# Better Terrain Tool — reusable colour-settings UI module.
#
# Owns: the "Color Variants" row, the "Color settings" section (blend mode,
# gamma / contrast / hue / saturation / lightness, tint) and the Photoshop-like
# Levels tool (histogram, triple input slider, double output slider, per
# channel). It never touches the renderer itself: everything goes through the
# host delegate, so the same UI can drive terrain layers today and existing DD
# nodes (ColourAndModifyThings-style) tomorrow.
#
# The edited target is an opaque Dictionary holding the EDIT_KEYS values plus
# "levels" (see the host's COLOR_DEFAULTS for the canonical shape).
#
# Host delegate contract:
#   cs_target() -> Dictionary or null    the target currently being edited
#   cs_apply(target)                     push the target's params to the render
#   cs_preview(target)                   cheap refresh (thumbnails) during drags
#   cs_edited(target)                    persist + refresh after a change
#   cs_texture(target) -> Texture        source image for the histogram
#   cs_open_changed(open: bool)          "Color settings" fold state changed
#   COLOR_DEFAULTS (property)            defaults dict used by "Reset colours"
#
# NOTE: no "extends" here on purpose -- Dungeondraft's ModManager compiles
# every .gd of the mod with its own injected preamble, and a second extends
# is a parse error. The implicit base (Reference) is what we want.

var host = null
var root := ""
var prefix := ""            # host delegate prefix: "" (layer colours) or "grad_" (gradient colours)
var gradient := false       # gradient variant: no Variants row, no fold toggle, no "all slots"
var _ui_syncing := false
var _random_icon = null
var _reset_icon = null

var _color_ui := {}          # key -> [HSlider, SpinBox]
var _color_toggle: CheckButton = null
var _color_blend_option: OptionButton = null
var _levels_toggle: CheckButton = null
var _variants_box: VBoxContainer = null
var _variants_range: HSlider = null
var _variants_cb := {}
var _levels_box: VBoxContainer = null
var _lv_channel_opt: OptionButton = null
var _lv_channel := "m"          # "m" / "r" / "g" / "b"
var _lv_hist_rect: TextureRect = null
var _lv_in_ctrl: Control = null
var _lv_out_ctrl: Control = null
var _lv_drag := -1              # handle index being dragged
var _lv_drag_ctrl = null
var _lv_slider_script = null
var _lv_in_spins := []
var _lv_live := true
var _lv_live_check: CheckButton = null
var _lv_out_spins := []
var _color_box: VBoxContainer = null
var _tint_btn: ColorPickerButton = null
var _tint_slider: HSlider = null
var _all_check: CheckButton = null
var _all_ui := {}               # neutral UI state while "all slots" is on
var _all_ui_levels := {}
var _variants_all_check: CheckButton = null
const LV_MARGIN = 8.0           # px inset so the edge handles stay visible/clickable
const LV_CHANNELS = ["m", "r", "g", "b"]
const EDIT_KEYS = ["hue", "saturation", "lightness", "gamma", "contrast", "tint_color", "tint_amount", "color_blend"]
const CB_NAMES = ["Normal", "Darken", "Multiply", "Color Burn", "Linear Burn", "Darker Color",
	"Lighten", "Screen", "Color Dodge", "Linear Dodge (Add)", "Lighter Color",
	"Overlay", "Soft Light", "Hard Light", "Vivid Light", "Linear Light", "Pin Light",
	"Subtract", "Inverse Subtract", "Hue", "Saturation", "Color", "Luminosity"]


func setup(host_, root_: String, prefix_ := "", gradient_ := false) -> void:
	host = host_
	root = root_
	prefix = prefix_
	gradient = gradient_


# Public alias: a generic labelled slider+spin row bound to a target key.
# Usable by hosts for adjacent sections (e.g. texture transform).
func param_row(label: String, key: String, mn, mx, st, val) -> HBoxContainer:
	return _color_row(label, key, mn, mx, st, val)


func build(box: VBoxContainer) -> void:
	if gradient:
		_build_gradient_variant(box)
		return
	var vrow = HBoxContainer.new()
	var vbtn = Button.new()
	vbtn.text = "Color Variants"
	vbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbtn.hint_tooltip = "Apply a subtle random variation to this layer's colour settings. Click the cog to configure."
	if _random_icon == null:
		_random_icon = _load_icon(root + "icons/random.png", 0.8)
	if _random_icon != null:
		vbtn.icon = _random_icon
	vbtn.connect("pressed", self, "_on_color_variants_pressed")
	vrow.add_child(vbtn)
	var vcog = Button.new()
	var cog_ic = _load_icon(root + "icons/cog.png", 0.5)
	if cog_ic != null:
		vcog.icon = cog_ic
	else:
		vcog.text = "*"
	vcog.toggle_mode = true
	vcog.hint_tooltip = "Show / hide the variation settings."
	vcog.connect("toggled", self, "_on_variants_adv_toggled")
	vrow.add_child(vcog)
	box.add_child(vrow)
	_variants_box = VBoxContainer.new()
	_variants_box.visible = false
	var vrange_row = HBoxContainer.new()
	var vrl = Label.new()
	vrl.text = "Range %"
	vrl.rect_min_size = Vector2(84, 0)
	vrange_row.add_child(vrl)
	_variants_range = _mk_slider(1, 100, 1, 10, "_on_variants_range_changed")
	_slider_resettable(_variants_range, 10)
	vrange_row.add_child(_variants_range)
	_variants_box.add_child(vrange_row)
	var vchecks = HBoxContainer.new()
	_variants_cb = {}
	for pair in [["hue", "Hue"], ["sat", "Sat"], ["gamma", "Gamma"], ["levels", "In Levels"]]:
		var cb = CheckBox.new()
		cb.text = pair[1]
		cb.pressed = true
		vchecks.add_child(cb)
		_variants_cb[pair[0]] = cb
	_variants_box.add_child(vchecks)
	_variants_all_check = CheckButton.new()
	_variants_all_check.text = "Apply to all slots"
	_variants_all_check.hint_tooltip = "Roll an independent variation on every slot of the level. Linked with the Color settings toggle."
	_variants_all_check.connect("toggled", self, "_on_variants_all_toggled")
	_variants_box.add_child(_variants_all_check)
	box.add_child(_variants_box)
	box.add_child(_sep())
	_color_toggle = CheckButton.new()
	_color_toggle.text = "Color Settings"
	_color_toggle.align = Button.ALIGN_CENTER
	var cs_ic = _load_icon(root + "icons/color_settings.png")
	if cs_ic != null:
		_color_toggle.icon = cs_ic
	_color_toggle.connect("toggled", self, "_on_color_toggle")
	if host != null and host.has_method("_attach_chevron"):
		host._attach_chevron(_color_toggle, false)
	box.add_child(_color_toggle)
	_color_box = VBoxContainer.new()
	_color_box.visible = false
	box.add_child(_color_box)
	_all_check = CheckButton.new()
	_all_check.text = "Apply to all slots"
	_all_check.hint_tooltip = "Adjust every slot at once, ON TOP of each slot's own settings: the sliders go back to neutral and act as a global offset. Toggling OFF keeps the result."
	_all_check.connect("toggled", self, "_on_all_toggled")
	_color_box.add_child(_all_check)
	_build_color_rows(_color_box)
	_build_reset(box, "Reset Colors", "Reset the colour adjustments of this layer.")


# Gradient variant: the same blend mode / adjustments / tint / Levels rows,
# always visible, editing the gradient's own colour dictionary.
func _build_gradient_variant(box: VBoxContainer) -> void:
	_color_box = VBoxContainer.new()
	box.add_child(_color_box)
	_build_color_rows(_color_box)
	_build_reset(box, "Reset Gradient Colors", "Reset the colour adjustments of this gradient.")


func _build_color_rows(cbox: VBoxContainer) -> void:
	_color_ui = {}
	var cbrow = HBoxContainer.new()
	var cblbl = Label.new()
	cblbl.text = "Blend mode"
	cblbl.rect_min_size = Vector2(84, 0)
	cbrow.add_child(cblbl)
	_color_blend_option = OptionButton.new()
	_color_blend_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for nm in CB_NAMES:
		_color_blend_option.add_item(nm)
	_color_blend_option.hint_tooltip = "How this layer's colours combine with what is painted below."
	_color_blend_option.connect("item_selected", self, "_on_color_blend_selected")
	_color_blend_option.connect("gui_input", self, "_on_color_blend_gui_input")
	cbrow.add_child(_color_blend_option)
	cbox.add_child(cbrow)
	cbox.add_child(_color_row("Gamma", "gamma", 0.2, 3, 0.01, 1))
	cbox.add_child(_color_row("Contrast", "contrast", 0, 2, 0.01, 1))
	cbox.add_child(_color_row("Hue", "hue", -180, 180, 1, 0))
	cbox.add_child(_color_row("Saturation", "saturation", 0, 2, 0.01, 1))
	cbox.add_child(_color_row("Lightness", "lightness", -1, 1, 0.01, 0))
	var trow = HBoxContainer.new()
	var tlbl = Label.new()
	tlbl.text = "Tint"
	tlbl.rect_min_size = Vector2(84, 0)
	trow.add_child(tlbl)
	_tint_slider = _mk_slider(0, 1, 0.01, 0, "_on_tint_amount_changed")
	_slider_resettable(_tint_slider, 0.0)
	trow.add_child(_tint_slider)
	_tint_btn = ColorPickerButton.new()
	_tint_btn.rect_min_size = Vector2(48, 0)
	_tint_btn.edit_alpha = false
	_tint_btn.connect("color_changed", self, "_on_tint_color_changed")
	trow.add_child(_tint_btn)
	trow.add_child(_reset_btn("_on_tint_reset"))
	cbox.add_child(trow)
	_levels_toggle = CheckButton.new()
	_levels_toggle.text = "Levels"
	_levels_toggle.hint_tooltip = "Photoshop-style Levels: histogram, input black / gamma / white, output range, per channel."
	_levels_toggle.connect("toggled", self, "_on_levels_toggle")
	cbox.add_child(_levels_toggle)
	_build_levels_box(cbox)


func _build_reset(box: VBoxContainer, text: String, tip: String) -> void:
	var reset = Button.new()
	reset.text = text
	reset.align = Button.ALIGN_CENTER
	var reset_ic = _load_icon(root + "icons/reset.png", 0.75)
	if reset_ic != null:
		# Icon on the RIGHT: an overlay anchored to the button's right edge
		# (Button.icon only draws on the left).
		var ricr = TextureRect.new()
		ricr.texture = reset_ic
		ricr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		ricr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ricr.anchor_left = 1.0
		ricr.anchor_right = 1.0
		ricr.anchor_top = 0.0
		ricr.anchor_bottom = 1.0
		ricr.margin_left = -(reset_ic.get_width() + 6)
		ricr.margin_right = -6
		reset.add_child(ricr)
	reset.hint_tooltip = tip
	reset.connect("pressed", self, "_on_color_reset")
	# Outside the collapsible Color Settings section, framed like the host's
	# Fill / Clear buttons when it offers that style.
	if host != null and host.has_method("_framed"):
		box.add_child(host._framed(reset))
	else:
		box.add_child(reset)


func _all_on() -> bool:
	return _all_check != null and is_instance_valid(_all_check) and _all_check.pressed


func _neutral_levels() -> Dictionary:
	return {"on": false, "m": [0.0, 1.0, 1.0, 0.0, 1.0], "r": [0.0, 1.0, 1.0, 0.0, 1.0], "g": [0.0, 1.0, 1.0, 0.0, 1.0], "b": [0.0, 1.0, 1.0, 0.0, 1.0]}


func _snap(t: Dictionary) -> Dictionary:
	var d = {}
	for k in EDIT_KEYS:
		d[k] = t[k]
	d["levels"] = t["levels"].duplicate(true)
	return d


# "Apply to all slots": a global ADJUSTMENT on top of each slot's own
# settings. Toggling ON snapshots every slot as its base and resets the UI to
# neutral; edits are deltas re-applied over each base. Toggling OFF keeps the
# combined result and goes back to editing the selected slot alone.
func _on_variants_all_toggled(on: bool) -> void:
	if _ui_syncing:
		return
	if _all_check != null and is_instance_valid(_all_check) and _all_check.pressed != on:
		_all_check.pressed = on   # runs _on_all_toggled (mode switch)


func _on_all_toggled(on: bool) -> void:
	if not host.has_method(prefix + "cs_all_targets"):
		return
	if _variants_all_check != null and is_instance_valid(_variants_all_check) and _variants_all_check.pressed != on:
		_ui_syncing = true
		_variants_all_check.pressed = on
		_ui_syncing = false
	if on:
		for t in host.call(prefix + "cs_all_targets"):
			t["_cs_base"] = _snap(t)
			t.erase("_cs_var")
		_all_ui = {}
		for k in EDIT_KEYS:
			_all_ui[k] = host.COLOR_DEFAULTS[k]
		_all_ui_levels = _neutral_levels()
	else:
		for t in host.call(prefix + "cs_all_targets"):
			t.erase("_cs_base")
			t.erase("_cs_var")
		host.call(prefix + "cs_edited", host.call(prefix + "cs_target"))
	sync_ui()


# Copy the primary's levels onto every other selected layer.
func _lv_mirror(primary: Dictionary) -> void:
	for t in _edit_list():
		if t != primary:
			t["levels"] = primary["levels"].duplicate(true)
			host.call(prefix + "cs_apply", t)
			host.call(prefix + "cs_edited", t)


# Layers a single-target edit applies to (multi-selection aware).
func _edit_list() -> Array:
	if host != null and host.has_method(prefix + "cs_edit_targets"):
		return host.call(prefix + "cs_edit_targets")
	var t = host.call(prefix + "cs_target") if host != null else null
	return [t] if t != null else []


func _combine(key: String, b, u):
	match key:
		"hue":
			return clamp(float(b) + float(u), -180.0, 180.0)
		"saturation":
			return clamp(float(b) + float(u) - 1.0, 0.0, 2.0)
		"lightness":
			return clamp(float(b) + float(u), -1.0, 1.0)
		"gamma":
			return clamp(float(b) + float(u) - 1.0, 0.2, 3.0)
		"contrast":
			return clamp(float(b) + float(u) - 1.0, 0.0, 2.0)
		"tint_amount":
			return clamp(float(b) + float(u), 0.0, 1.0)
		"tint_color":
			return u if float(_all_ui.get("tint_amount", 0.0)) > 0.0 else b
		"color_blend":
			return int(u) if int(u) != 0 else int(b)
	return u


func _combine_lv(b: Array, u: Array) -> Array:
	return [
		clamp(float(b[0]) + float(u[0]), 0.0, 0.98),
		clamp(float(b[1]) + float(u[1]) - 1.0, 0.02, 1.0),
		clamp(float(b[2]) * float(u[2]), 0.1, 9.99),
		clamp(float(b[3]) + float(u[3]), 0.0, 0.98),
		clamp(float(b[4]) + float(u[4]) - 1.0, 0.02, 1.0),
	]


func _apply_all_delta() -> void:
	if not host.has_method(prefix + "cs_all_targets"):
		return
	for t in host.call(prefix + "cs_all_targets"):
		if not t.has("_cs_base"):
			t["_cs_base"] = _snap(t)   # slot added while the mode was on
		var base = t["_cs_base"]
		var varo = t.get("_cs_var", null)
		for k in EDIT_KEYS:
			var b = base[k]
			if varo != null and varo.has(k):
				b = _combine(k, b, varo[k])
			t[k] = _combine(k, b, _all_ui[k])
		var var_on = varo != null and varo.has("levels_m")
		var lv = {"on": bool(base["levels"].get("on", false)) or bool(_all_ui_levels.get("on", false)) or var_on}
		for c in LV_CHANNELS:
			var bc = base["levels"][c]
			if c == "m" and var_on:
				bc = _combine_lv(bc, varo["levels_m"])
			lv[c] = _combine_lv(bc, _all_ui_levels[c])
		t["levels"] = lv
		host.call(prefix + "cs_apply", t)
		host.call(prefix + "cs_preview", t)
	host.call(prefix + "cs_edited", host.call(prefix + "cs_target"))


func set_open(on: bool) -> void:
	if _color_toggle != null and is_instance_valid(_color_toggle):
		_color_toggle.pressed = on
	if _color_box != null and is_instance_valid(_color_box):
		_color_box.visible = on


# Public CPU colour pipeline (thumbnails / histograms).
func apply_colors_to_image(img: Image, target: Dictionary, include_levels := true) -> void:
	if include_levels:
		_apply_colors_to_image(img, target)
	else:
		_apply_colors_to_image_no_levels(img, target)


# Sync every widget from the current target (call on selection change).
func sync_ui() -> void:
	var layer = host.call(prefix + "cs_target")
	if layer == null:
		return
	var src = layer
	var lvsrc = layer["levels"]
	if _all_on():
		src = _all_ui
		lvsrc = _all_ui_levels
	_ui_syncing = true
	for k in _color_ui.keys():
		var vv = float(src[k]) if src.has(k) else float(layer[k])
		_color_ui[k][0].value = vv
		_color_ui[k][1].value = vv
	if _tint_slider != null and is_instance_valid(_tint_slider):
		_tint_slider.value = float(src["tint_amount"])
	if _tint_btn != null and is_instance_valid(_tint_btn):
		_tint_btn.color = Color(str(src["tint_color"]))
	if _color_blend_option != null and is_instance_valid(_color_blend_option):
		_color_blend_option.selected = int(src["color_blend"])
	_ui_syncing = false
	if _levels_toggle != null and is_instance_valid(_levels_toggle):
		var lon = bool(lvsrc.get("on", false))
		if _levels_toggle.pressed != lon:
			_levels_toggle.pressed = lon
		if _levels_box != null and is_instance_valid(_levels_box):
			_levels_box.visible = lon
			if lon:
				_update_levels_histogram()
				_lv_redraw()


# ── moved implementation ─────────────────────────────────────────────────────

func _on_tint_reset() -> void:
	if _tint_btn != null:
		_tint_btn.color = Color(1, 1, 1)
	_set_color_param("tint_color", "#ffffff")
	_tint_slider.value = 0.0

func _color_row(label: String, key: String, mn, mx, st, val) -> HBoxContainer:
	var sl = HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = st
	sl.value = val
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.connect("value_changed", self, "_on_color_slider", [key])
	var sp = SpinBox.new()
	sp.min_value = mn
	sp.max_value = mx
	sp.step = st
	sp.value = val
	sp.rect_min_size = Vector2(64, 0)
	sp.connect("value_changed", self, "_on_color_spin", [key])
	_slider_resettable(sl, val)
	var row = _labeled(label, sl)
	row.add_child(sp)
	row.add_child(_reset_btn("_on_slider_reset", [sl, val]))
	_color_ui[key] = [sl, sp]
	return row

func _on_color_slider(v: float, key: String) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_color_ui[key][1].value = v
	_ui_syncing = false
	_set_color_param(key, v)

func _on_color_spin(v: float, key: String) -> void:
	if _ui_syncing:
		return
	_ui_syncing = true
	_color_ui[key][0].value = v
	_ui_syncing = false
	_set_color_param(key, v)

func _set_color_param(key: String, v) -> void:
	var layer = host.call(prefix + "cs_target")
	if layer == null:
		return
	if _all_on() and key in EDIT_KEYS:
		_all_ui[key] = v
		_apply_all_delta()
		return
	for t in _edit_list():
		if t != layer:
			t[key] = v
			host.call(prefix + "cs_apply", t)
			host.call(prefix + "cs_edited", t)
	layer[key] = v
	host.call(prefix + "cs_apply", layer)
	if key in EDIT_KEYS:
		host.call(prefix + "cs_preview", layer)
		if _lv_live and _levels_box != null and is_instance_valid(_levels_box) and _levels_box.visible:
			_update_levels_histogram()
	host.call(prefix + "cs_edited", host.call(prefix + "cs_target"))

func _on_tint_color_changed(c: Color) -> void:
	if _ui_syncing:
		return
	_set_color_param("tint_color", "#" + c.to_html(false))

func _on_tint_amount_changed(v: float) -> void:
	if _ui_syncing:
		return
	_set_color_param("tint_amount", v)

# Mouse wheel cycles the blend mode when hovering the dropdown, or anywhere
# while the dropdown still has focus (right after a change).
func _on_color_blend_gui_input(event) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == BUTTON_WHEEL_UP:
			_wheel_color_blend(-1)
			_color_blend_option.accept_event()   # keep the panel from scrolling too
		elif event.button_index == BUTTON_WHEEL_DOWN:
			_wheel_color_blend(1)
			_color_blend_option.accept_event()

func _wheel_color_blend(dir: int) -> void:
	if _color_blend_option == null or not is_instance_valid(_color_blend_option):
		return
	var n = _color_blend_option.get_item_count()
	if n == 0:
		return
	var idx = clamp(_color_blend_option.selected + dir, 0, n - 1)
	if idx == _color_blend_option.selected:
		return
	_color_blend_option.selected = idx
	_set_color_param("color_blend", idx)

func _on_color_blend_selected(idx: int) -> void:
	if _ui_syncing:
		return
	_set_color_param("color_blend", idx)

func _on_color_toggle(on: bool) -> void:
	var chv = _color_toggle.get_node_or_null("chev")
	if chv != null:
		chv.flip_v = on
	pass
	if _color_box != null and is_instance_valid(_color_box):
		_color_box.visible = on
	host.call(prefix + "cs_open_changed", on)

func _on_color_reset() -> void:
	var layer = host.call(prefix + "cs_target")
	if layer == null:
		return
	# Only the colour settings: blend modes / smoothness / transform keep
	# their own controls and are not touched by "Reset colours".
	if _all_on():
		# Back to the exact state of the moment "all slots" was switched on:
		# global deltas zeroed and per-slot variant offsets cleared.
		for t in host.call(prefix + "cs_all_targets"):
			t.erase("_cs_var")
		for k in EDIT_KEYS:
			_all_ui[k] = host.COLOR_DEFAULTS[k]
		_all_ui_levels = _neutral_levels()
		_apply_all_delta()
		sync_ui()
		return
	for t in _edit_list():
		for k in EDIT_KEYS:
			t[k] = host.COLOR_DEFAULTS[k]
		t["levels"] = _neutral_levels()
		host.call(prefix + "cs_apply", t)
		host.call(prefix + "cs_edited", t)
	sync_ui()

func _on_variants_adv_toggled(on: bool) -> void:
	if _variants_box != null and is_instance_valid(_variants_box):
		_variants_box.visible = on

func _on_variants_range_changed(_v: float) -> void:
	pass

# One press = one new subtle random variation of the layer's colour settings,
# offset from the CURRENT values (same spirit as ColourAndModifyThings).
func _on_color_variants_pressed() -> void:
	var primary = host.call(prefix + "cs_target")
	if primary == null:
		return
	var r = 0.1
	if _variants_range != null and is_instance_valid(_variants_range):
		r = _variants_range.value / 100.0
	if _all_on() and host.has_method(prefix + "cs_all_targets"):
		# Each slot rolls its OWN variation, stored as an offset inside the
		# "all slots" state: Reset colours removes it, bases stay pristine.
		for layer in host.call(prefix + "cs_all_targets"):
			layer["_cs_var"] = _variant_offsets(r)
		_apply_all_delta()
	else:
		for t in _edit_list():
			_variant_one(t, r)
			host.call(prefix + "cs_apply", t)
			host.call(prefix + "cs_edited", t)
	sync_ui()


# Neutral-relative random offsets honouring the parameter checkboxes.
func _variant_offsets(r: float) -> Dictionary:
	var d = {}
	if _variants_cb.get("hue") != null and _variants_cb["hue"].pressed:
		d["hue"] = rand_range(-r, r) * 360.0
	if _variants_cb.get("sat") != null and _variants_cb["sat"].pressed:
		d["saturation"] = 1.0 + rand_range(-r, r)
	if _variants_cb.get("gamma") != null and _variants_cb["gamma"].pressed:
		d["gamma"] = 1.0 + rand_range(-r, r)
	if _variants_cb.get("levels") != null and _variants_cb["levels"].pressed:
		d["levels_m"] = [rand_range(0.0, r), 1.0 - rand_range(0.0, r), 1.0, 0.0, 1.0]
	return d


func _variant_one(layer: Dictionary, r: float) -> void:
	if _variants_cb.get("hue") != null and _variants_cb["hue"].pressed:
		layer["hue"] = clamp(float(layer["hue"]) + rand_range(-r, r) * 360.0, -180.0, 180.0)
	if _variants_cb.get("sat") != null and _variants_cb["sat"].pressed:
		layer["saturation"] = clamp(float(layer["saturation"]) + rand_range(-r, r), 0.0, 2.0)
	if _variants_cb.get("gamma") != null and _variants_cb["gamma"].pressed:
		layer["gamma"] = clamp(float(layer["gamma"]) + rand_range(-r, r), 0.2, 3.0)
	if _variants_cb.get("levels") != null and _variants_cb["levels"].pressed:
		var vals: Array = layer["levels"]["m"]
		var nb = clamp(float(vals[0]) + rand_range(-r, r), 0.0, 1.0)
		var nw = clamp(float(vals[1]) + rand_range(-r, r), 0.0, 1.0)
		if nb < nw - 0.02:
			vals[0] = nb
			vals[1] = nw
			layer["levels"]["on"] = true
	host.call(prefix + "cs_apply", layer)
	host.call(prefix + "cs_preview", layer)

func _build_levels_box(box: VBoxContainer) -> void:
	_levels_box = VBoxContainer.new()
	_levels_box.visible = false
	_levels_box.add_constant_override("separation", 4)
	var crow = HBoxContainer.new()
	var clbl = Label.new()
	clbl.text = "Channel"
	clbl.rect_min_size = Vector2(84, 0)
	crow.add_child(clbl)
	_lv_channel_opt = OptionButton.new()
	for nm in ["Master", "Red", "Green", "Blue"]:
		_lv_channel_opt.add_item(nm)
	_lv_channel_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lv_channel_opt.connect("item_selected", self, "_on_lv_channel_selected")
	crow.add_child(_lv_channel_opt)
	crow.add_child(_reset_btn("_on_lv_reset"))
	_levels_box.add_child(crow)
	var auto_btn = Button.new()
	auto_btn.text = "Auto Levels"
	auto_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	auto_btn.hint_tooltip = "Set the input black / white points to the real ends of the histogram (0.1% clip)."
	auto_btn.connect("pressed", self, "_on_lv_auto")
	_levels_box.add_child(auto_btn)
	_lv_hist_rect = TextureRect.new()
	_lv_hist_rect.rect_min_size = Vector2(0, 84)
	_lv_hist_rect.expand = true
	_lv_hist_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_levels_box.add_child(_lv_hist_rect)
	var ilbl = Label.new()
	ilbl.text = "Input"
	_levels_box.add_child(ilbl)
	_lv_in_ctrl = _mk_levels_slider("in")
	_levels_box.add_child(_lv_in_ctrl)
	var irow = HBoxContainer.new()
	_lv_in_spins = []
	var sp_b = _mk_lv_spin(0, 255, 1, 0, "_on_lv_spin", ["in", 0])
	irow.add_child(sp_b)
	_lv_in_spins.append(sp_b)
	var sp_g = _mk_lv_spin(0.1, 9.99, 0.01, 1.0, "_on_lv_spin", ["in", 1])
	sp_g.size_flags_horizontal = Control.SIZE_SHRINK_CENTER | Control.SIZE_EXPAND
	irow.add_child(sp_g)
	_lv_in_spins.append(sp_g)
	var sp_w = _mk_lv_spin(0, 255, 1, 255, "_on_lv_spin", ["in", 2])
	irow.add_child(sp_w)
	_lv_in_spins.append(sp_w)
	_levels_box.add_child(irow)
	var olbl = Label.new()
	olbl.text = "Output"
	_levels_box.add_child(olbl)
	_lv_out_ctrl = _mk_levels_slider("out")
	_levels_box.add_child(_lv_out_ctrl)
	var orow = HBoxContainer.new()
	_lv_out_spins = []
	var so_b = _mk_lv_spin(0, 255, 1, 0, "_on_lv_spin", ["out", 0])
	orow.add_child(so_b)
	_lv_out_spins.append(so_b)
	var ospacer = Control.new()
	ospacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	orow.add_child(ospacer)
	var so_w = _mk_lv_spin(0, 255, 1, 255, "_on_lv_spin", ["out", 1])
	orow.add_child(so_w)
	_lv_out_spins.append(so_w)
	_levels_box.add_child(orow)
	_lv_live_check = CheckButton.new()
	_lv_live_check.text = "Live Histogram"
	_lv_live_check.pressed = _lv_live
	_lv_live_check.hint_tooltip = "Refresh the histogram when the other colour settings change."
	_lv_live_check.connect("toggled", self, "_on_lv_live_toggled")
	_levels_box.add_child(_lv_live_check)
	_levels_box.add_child(_sep())
	box.add_child(_levels_box)

func _mk_levels_slider(kind: String) -> Control:
	if _lv_slider_script == null:
		var sc = GDScript.new()
		sc.source_code = """extends Control
var handler = null
var kind = ""
func _draw():
	if handler != null:
		handler.lv_slider_draw(self, kind)
func _gui_input(e):
	if handler != null:
		handler.lv_slider_input(self, kind, e)
"""
		sc.reload()
		_lv_slider_script = sc
	var c = Control.new()
	c.set_script(_lv_slider_script)
	c.handler = self
	c.kind = kind
	c.rect_min_size = Vector2(0, 22)
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	return c

func _mk_lv_spin(mn, mx, st, val, handler: String, binds: Array) -> SpinBox:
	var sp = SpinBox.new()
	sp.min_value = mn
	sp.max_value = mx
	sp.step = st
	sp.value = val
	sp.rect_min_size = Vector2(64, 0)
	sp.connect("value_changed", self, handler, binds)
	return sp

func _on_lv_spin(v: float, kind: String, idx: int) -> void:
	if _ui_syncing:
		return
	var layer = host.call(prefix + "cs_target")
	if layer == null:
		return
	var vals: Array = _lv_vals()
	if kind == "in":
		if idx == 0:
			vals[0] = min(v / 255.0, float(vals[1]) - 0.01)
		elif idx == 2:
			vals[1] = max(v / 255.0, float(vals[0]) + 0.01)
		else:
			vals[2] = clamp(v, 0.1, 9.99)
	else:
		if idx == 0:
			vals[3] = min(v / 255.0, float(vals[4]) - 0.01)
		else:
			vals[4] = max(v / 255.0, float(vals[3]) + 0.01)
	if _all_on():
		_apply_all_delta()
	else:
		host.call(prefix + "cs_apply", layer)
		host.call(prefix + "cs_edited", layer)
		_lv_mirror(layer)
	_lv_redraw()

func _lv_sync_spins() -> void:
	var vals = _lv_vals()
	_ui_syncing = true
	if _lv_in_spins.size() == 3:
		_lv_in_spins[0].value = round(float(vals[0]) * 255.0)
		_lv_in_spins[1].value = stepify(float(vals[2]), 0.01)
		_lv_in_spins[2].value = round(float(vals[1]) * 255.0)
	if _lv_out_spins.size() == 2:
		_lv_out_spins[0].value = round(float(vals[3]) * 255.0)
		_lv_out_spins[1].value = round(float(vals[4]) * 255.0)
	_ui_syncing = false

func _lv_vals() -> Array:
	if _all_on():
		return _all_ui_levels[_lv_channel]
	var layer = host.call(prefix + "cs_target")
	if layer == null:
		return [0.0, 1.0, 1.0, 0.0, 1.0]
	return layer["levels"][_lv_channel]

func lv_slider_draw(c: Control, kind: String) -> void:
	var w = c.rect_size.x - 2.0 * LV_MARGIN
	var h = c.rect_size.y
	var track = Rect2(LV_MARGIN, h * 0.5 - 2, w, 4)
	c.draw_rect(track, Color(0, 0, 0, 0.5))
	var vals = _lv_vals()
	var xs := []
	if kind == "in":
		var lo = float(vals[0])
		var hi = float(vals[1])
		var mid = lo + (hi - lo) * pow(0.5, float(vals[2]))
		xs = [lo, mid, hi]
	else:
		xs = [float(vals[3]), float(vals[4])]
	var cols = [Color(0.1, 0.1, 0.1), Color(0.55, 0.55, 0.55), Color(0.95, 0.95, 0.95)]
	if kind == "out":
		cols = [Color(0.1, 0.1, 0.1), Color(0.95, 0.95, 0.95)]
	for i in range(xs.size()):
		var x = LV_MARGIN + clamp(xs[i], 0.0, 1.0) * w
		var pts = PoolVector2Array([Vector2(x, h * 0.5 - 1), Vector2(x - 6, h - 1), Vector2(x + 6, h - 1)])
		c.draw_polygon(pts, PoolColorArray([cols[i], cols[i], cols[i]]))
		c.draw_polyline(PoolVector2Array([pts[0], pts[1], pts[2], pts[0]]), Color(0, 0, 0, 0.8), 1.0)

func lv_slider_input(c: Control, kind: String, event) -> void:
	var layer = host.call(prefix + "cs_target")
	if layer == null:
		return
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			_lv_drag_ctrl = c
			_lv_drag = _lv_nearest_handle(c, kind, event.position.x)
			_lv_apply_drag(c, kind, event.position.x)
		else:
			_lv_drag = -1
			_lv_drag_ctrl = null
			host.call(prefix + "cs_edited", host.call(prefix + "cs_target"))
	elif event is InputEventMouseMotion and _lv_drag_ctrl == c and _lv_drag >= 0:
		_lv_apply_drag(c, kind, event.position.x)

func _lv_nearest_handle(c: Control, kind: String, px: float) -> int:
	var w = max(c.rect_size.x - 2.0 * LV_MARGIN, 1.0)
	px -= LV_MARGIN
	var vals = _lv_vals()
	var xs := []
	if kind == "in":
		var lo = float(vals[0])
		var hi = float(vals[1])
		xs = [lo, lo + (hi - lo) * pow(0.5, float(vals[2])), hi]
	else:
		xs = [float(vals[3]), float(vals[4])]
	var best = 0
	var bd = 1e9
	for i in range(xs.size()):
		var d = abs(xs[i] * w - px)
		if d < bd:
			bd = d
			best = i
	return best

func _lv_apply_drag(c: Control, kind: String, px: float) -> void:
	var layer = host.call(prefix + "cs_target")
	if layer == null:
		return
	var vals: Array = _lv_vals()
	var t = clamp((px - LV_MARGIN) / max(c.rect_size.x - 2.0 * LV_MARGIN, 1.0), 0.0, 1.0)
	if kind == "in":
		if _lv_drag == 0:
			vals[0] = min(t, float(vals[1]) - 0.01)
		elif _lv_drag == 2:
			vals[1] = max(t, float(vals[0]) + 0.01)
		else:
			var lo = float(vals[0])
			var hi = float(vals[1])
			var f = clamp((t - lo) / max(hi - lo, 0.001), 0.02, 0.98)
			vals[2] = clamp(log(f) / log(0.5), 0.1, 9.99)
	else:
		if _lv_drag == 0:
			vals[3] = min(t, float(vals[4]) - 0.01)
		else:
			vals[4] = max(t, float(vals[3]) + 0.01)
	if _all_on():
		_apply_all_delta()
	else:
		host.call(prefix + "cs_apply", layer)
		host.call(prefix + "cs_preview", layer)
		_lv_mirror(layer)
	_lv_sync_spins()
	c.update()

func _on_levels_toggle(on: bool) -> void:
	if _levels_box != null and is_instance_valid(_levels_box):
		_levels_box.visible = on
	var layer = host.call(prefix + "cs_target")
	if layer == null or _ui_syncing:
		return
	if _all_on():
		_all_ui_levels["on"] = on
		_apply_all_delta()
	else:
		layer["levels"]["on"] = on
		host.call(prefix + "cs_apply", layer)
		host.call(prefix + "cs_edited", layer)
		_lv_mirror(layer)
	if on:
		_update_levels_histogram()
		_lv_redraw()

func _on_lv_channel_selected(idx: int) -> void:
	_lv_channel = LV_CHANNELS[clamp(idx, 0, 3)]
	_update_levels_histogram()
	_lv_redraw()

func _on_lv_reset() -> void:
	var layer = host.call(prefix + "cs_target")
	if layer == null:
		return
	if _all_on():
		_all_ui_levels[_lv_channel] = [0.0, 1.0, 1.0, 0.0, 1.0]
		_apply_all_delta()
	else:
		layer["levels"][_lv_channel] = [0.0, 1.0, 1.0, 0.0, 1.0]
		host.call(prefix + "cs_apply", layer)
		host.call(prefix + "cs_edited", layer)
		_lv_mirror(layer)
	_lv_redraw()

func _lv_redraw() -> void:
	_lv_sync_spins()
	for c in [_lv_in_ctrl, _lv_out_ctrl]:
		if c != null and is_instance_valid(c):
			c.update()

# Histogram of the layer texture AFTER the colour settings (HSL / gamma /
# contrast / tint) but WITHOUT levels: frozen while dragging the levels
# handles, refreshed when any other colour setting changes.
# Histogram bins (96) of the current channel, AFTER the colour settings but
# WITHOUT levels.
func _lv_compute_bins(layer: Dictionary) -> Array:
	var t = host.call(prefix + "cs_texture", layer)
	if t == null:
		return []
	var img: Image = t.get_data()
	if img == null:
		return []
	img = img.duplicate()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	img.resize(96, 96, Image.INTERPOLATE_BILINEAR)
	_apply_colors_to_image_no_levels(img, layer)
	var bins := []
	bins.resize(96)
	for i in range(96):
		bins[i] = 0.0
	img.lock()
	for y in range(96):
		for x in range(96):
			var c = img.get_pixel(x, y)
			var v = 0.0
			if _lv_channel == "r":
				v = c.r
			elif _lv_channel == "g":
				v = c.g
			elif _lv_channel == "b":
				v = c.b
			else:
				v = c.r * 0.3 + c.g * 0.59 + c.b * 0.11
			bins[int(clamp(v * 95.0, 0, 95))] += 1.0
	img.unlock()
	return bins

func _on_lv_live_toggled(on: bool) -> void:
	_lv_live = on
	if on:
		_update_levels_histogram()

# Auto Levels: input black / white at the real histogram ends (0.1% clip
# per side), for the current channel. Gamma and output are left alone.
func _on_lv_auto() -> void:
	var layer = host.call(prefix + "cs_target")
	if layer == null:
		return
	var bins = _lv_compute_bins(layer)
	if bins.empty():
		return
	var total = 0.0
	for b in bins:
		total += b
	if total <= 0.0:
		return
	var clip = total * 0.001
	var acc = 0.0
	var lo = 0
	for i in range(96):
		acc += bins[i]
		if acc > clip:
			lo = i
			break
	acc = 0.0
	var hi = 95
	for i in range(95, -1, -1):
		acc += bins[i]
		if acc > clip:
			hi = i
			break
	var vals: Array = _lv_vals()
	vals[0] = clamp(lo / 95.0, 0.0, 0.98)
	vals[1] = clamp(hi / 95.0, float(vals[0]) + 0.01, 1.0)
	if _all_on():
		_apply_all_delta()
	else:
		host.call(prefix + "cs_apply", layer)
		host.call(prefix + "cs_edited", layer)
		_lv_mirror(layer)
	_lv_redraw()

func _update_levels_histogram() -> void:
	if _lv_hist_rect == null or not is_instance_valid(_lv_hist_rect):
		return
	var layer = host.call(prefix + "cs_target")
	if layer == null:
		return
	var bins = _lv_compute_bins(layer)
	if bins.empty():
		return
	var peak = 1.0
	for i in range(96):
		peak = max(peak, bins[i])
	var hh = 64
	var out = Image.new()
	out.create(96, hh, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0.35))
	var bar = Color(0.85, 0.85, 0.85)
	if _lv_channel == "r":
		bar = Color(0.9, 0.35, 0.35)
	elif _lv_channel == "g":
		bar = Color(0.4, 0.85, 0.4)
	elif _lv_channel == "b":
		bar = Color(0.45, 0.6, 0.95)
	out.lock()
	for x in range(96):
		var bh = int(round(sqrt(bins[x] / peak) * (hh - 2)))
		for y in range(bh):
			out.set_pixel(x, hh - 1 - y, bar)
	out.unlock()
	var ot = ImageTexture.new()
	ot.create_from_image(out, 0)
	_lv_hist_rect.texture = ot

func _apply_colors_to_image(img: Image, layer: Dictionary) -> void:
	var hue = float(layer["hue"])
	var sat = float(layer["saturation"])
	var lig = float(layer["lightness"])
	var gam = float(layer["gamma"])
	var con = float(layer["contrast"])
	var tint = Color(str(layer["tint_color"]))
	var ta = float(layer["tint_amount"])
	if hue == 0.0 and sat == 1.0 and lig == 0.0 and gam == 1.0 and con == 1.0 and ta == 0.0:
		return
	img.lock()
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c = img.get_pixel(x, y)
			var a = c.a
			if hue != 0.0 or sat != 1.0:
				var cc = Color.from_hsv(fposmod(c.h + hue / 360.0, 1.0), clamp(c.s * sat, 0.0, 1.0), c.v)
				c = cc
			for i in range(3):
				var v = c[i]
				v += lig
				v = (v - 0.5) * con + 0.5
				v = pow(clamp(v, 0.0, 1.0), 1.0 / gam)
				c[i] = v
			c = c.linear_interpolate(Color(tint.r, tint.g, tint.b), ta)
			c.a = a
			img.set_pixel(x, y, c)
	img.unlock()
	if not layer.get("_skip_levels", false):
		_apply_levels_to_image(img, layer)

# CPU version of the shader's colour pipeline (HSL, gamma, contrast, tint) so
# the small thumbnails preview the layer's colour settings.
# Colour transform WITHOUT the levels stage (histogram source).
func _apply_colors_to_image_no_levels(img: Image, layer: Dictionary) -> void:
	layer["_skip_levels"] = true
	_apply_colors_to_image(img, layer)
	layer.erase("_skip_levels")

func _apply_levels_to_image(img: Image, layer: Dictionary) -> void:
	var lv = layer.get("levels")
	if lv == null or not bool(lv.get("on", false)):
		return
	var lr = lv["r"]
	var lg = lv["g"]
	var lb = lv["b"]
	var lm = lv["m"]
	img.lock()
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c = img.get_pixel(x, y)
			var r = _lv1(_lv1(c.r, lr), lm)
			var g = _lv1(_lv1(c.g, lg), lm)
			var b = _lv1(_lv1(c.b, lb), lm)
			img.set_pixel(x, y, Color(r, g, b, c.a))
	img.unlock()

func _lv1(x: float, v: Array) -> float:
	var t = clamp((x - float(v[0])) / max(float(v[1]) - float(v[0]), 0.001), 0.0, 1.0)
	t = pow(t, 1.0 / max(float(v[2]), 0.01))
	return lerp(float(v[3]), float(v[4]), t)


# ── local UI helpers (copies, so the module stays standalone) ────────────────

func _sep() -> HSeparator:
	return HSeparator.new()


func _labeled(text: String, ctrl: Control) -> HBoxContainer:
	var row = HBoxContainer.new()
	var l = Label.new()
	l.text = text
	l.rect_min_size = Vector2(84, 0)
	row.add_child(l)
	ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ctrl)
	return row


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


func _on_slider_reset(sl, def) -> void:
	sl.value = def


func _reset_btn(handler: String, binds := []) -> Button:
	var b = Button.new()
	if _reset_icon == null:
		_reset_icon = _load_icon(root + "icons/reset.png", 0.5)
	if _reset_icon != null:
		b.icon = _reset_icon
	else:
		b.text = "R"
	b.hint_tooltip = "Reset"
	b.connect("pressed", self, handler, binds)
	return b


func _load_icon(path: String, scale: float = 1.0):
	var img = Image.new()
	if img.load(path) != OK:
		return null
	img.convert(Image.FORMAT_RGBA8)
	if scale != 1.0:
		img.resize(int(img.get_width() * scale), int(img.get_height() * scale), Image.INTERPOLATE_BILINEAR)
	var t = ImageTexture.new()
	t.create_from_image(img, Texture.FLAG_FILTER | Texture.FLAG_MIPMAPS)
	return t
