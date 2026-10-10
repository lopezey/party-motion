# Draws each player's wavy avatar, with an editor preview and gentle in-game motion.
@tool
extends Control

# Redraw when the player's color or the chosen shape changes.
@export var color := Color("344341"):
	set(value):
		color = value
		queue_redraw()
@export_range(0, 7) var face_variant := 0:
	set(value):
		face_variant = value
		queue_redraw()

# Tracks animation time.
var elapsed := 0.0


# Animate while the game runs.
func _process(delta: float) -> void:
	if not Engine.is_editor_hint():
		elapsed += delta
		queue_redraw()


## Build the avatar outline, then draw its eyes and smile.
func _draw() -> void:
	var ink := Color("101919")
	var center := size * 0.5
	var points := PackedVector2Array()
	var wobble := sin(elapsed * 1.7 + face_variant) * 0.025

	for index in range(80):
		var angle := TAU * index / 80.0
		var radius := 1.0 + sin(angle * (3 + face_variant % 3) + face_variant) * 0.12
		points.append(center + Vector2(cos(angle) * (0.40 + wobble), sin(angle) * (0.40 - wobble)) * size * radius)
	draw_colored_polygon(points, color)
	draw_circle(center + Vector2(-12, -6), 3.2, ink)
	draw_circle(center + Vector2(12, -6), 3.2, ink)
	draw_arc(center + Vector2(0, 3), 11, 0.15, PI - 0.15, 20, ink, 3, true)
