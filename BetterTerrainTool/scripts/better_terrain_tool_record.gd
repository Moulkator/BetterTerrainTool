extends Reference

# better_terrain_tool_record.gd — custom undo record for a Better Terrain Tool stroke.
#
# Stores the full mask of ONE layer before and after a stroke/fill/clear, and
# hands it back to the driver to restore. Layers are referenced by their
# persistent uid (not by list index) so reordering does not break undo.

var driver = null
var level_id: int = -1
var layer_uid: int = -1
var before: Image = null
var after: Image = null


func undo() -> void:
	if driver != null and is_instance_valid(driver) and before != null:
		driver.restore_mask(level_id, layer_uid, before)


func redo() -> void:
	if driver != null and is_instance_valid(driver) and after != null:
		driver.restore_mask(level_id, layer_uid, after)
