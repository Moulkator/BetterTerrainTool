extends Reference

# better_terrain_tool_op_record.gd — custom undo record for layer OPERATIONS
# (add / remove / texture change), as opposed to paint strokes.
#
# The op dictionary is interpreted by the driver's apply_layer_op().

var driver = null
var op := {}


func undo() -> void:
	if driver != null and is_instance_valid(driver):
		driver.apply_layer_op(op, true)


func redo() -> void:
	if driver != null and is_instance_valid(driver):
		driver.apply_layer_op(op, false)
