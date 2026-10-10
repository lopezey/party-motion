@tool
extends Area2D

var elapsed := 0.0


func _process(delta: float) -> void:
	if not Engine.is_editor_hint():
		elapsed += delta
	queue_redraw()


func _draw() -> void:
	var points := PackedVector2Array()
	var pulse := 1.0 + sin(elapsed * 3.0) * 0.1
	for index in range(12):
		var radius := (17.0 if index % 2 == 0 else 9.0) * pulse
		points.append(Vector2.from_angle(TAU * index / 12.0) * radius)
	draw_colored_polygon(points, Color("b7ed72"))
	draw_circle(Vector2(-3, -3), 3, Color("f4ffcb"))
