extends Control

const BG := Color("101522")
const PANEL := Color("171e2e")
const PANEL_EDGE := Color("303a50")
const TEXT := Color("f7f8fc")
const MUTED := Color("8e99ad")
const CYAN := Color("58d6ff")
const PLAYER_RADIUS := 30.0
const MOVE_SPEED := 760.0

var server_base := "http://127.0.0.1:8787"
var room_code := ""
var host_token := ""
var join_url := ""
var socket := WebSocketPeer.new()
var players: Dictionary = {}
var room_request: HTTPRequest
var qr_request: HTTPRequest
var title_label: Label
var status_label: Label
var room_label: Label
var join_label: Label
var start_button: Button
var qr_rect: TextureRect
var hint_label: Label
var connected := false


func _ready() -> void:
	var configured_url := OS.get_environment("PARTY_RELAY_URL")
	if not configured_url.is_empty():
		server_base = configured_url.trim_suffix("/")
	build_interface()
	room_request = HTTPRequest.new()
	add_child(room_request)
	room_request.request_completed.connect(_on_room_created)
	qr_request = HTTPRequest.new()
	add_child(qr_request)
	qr_request.request_completed.connect(_on_qr_loaded)
	queue_redraw()


func build_interface() -> void:
	title_label = make_label("PARTY MOTION", 40, TEXT)
	title_label.position = Vector2(44, 28)
	title_label.size = Vector2(400, 60)
	add_child(title_label)

	var subtitle := make_label("TILT ARENA  /  FIRST PLAYABLE PROTOTYPE", 14, CYAN)
	subtitle.position = Vector2(47, 80)
	subtitle.size = Vector2(500, 28)
	add_child(subtitle)

	status_label = make_label("Create a room to begin", 18, MUTED)
	status_label.position = Vector2(47, 132)
	status_label.size = Vector2(360, 34)
	add_child(status_label)

	room_label = make_label("------", 54, TEXT)
	room_label.position = Vector2(46, 174)
	room_label.size = Vector2(330, 70)
	room_label.add_theme_constant_override("outline_size", 10)
	room_label.add_theme_color_override("font_outline_color", BG)
	add_child(room_label)

	join_label = make_label("Players scan the QR code\nor enter the room code", 15, MUTED)
	join_label.position = Vector2(48, 250)
	join_label.size = Vector2(310, 60)
	add_child(join_label)

	qr_rect = TextureRect.new()
	qr_rect.position = Vector2(48, 326)
	qr_rect.size = Vector2(210, 210)
	qr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(qr_rect)

	start_button = Button.new()
	start_button.text = "CREATE ROOM"
	start_button.position = Vector2(48, 566)
	start_button.size = Vector2(270, 58)
	start_button.add_theme_font_size_override("font_size", 18)
	start_button.pressed.connect(create_room)
	add_child(start_button)

	hint_label = make_label("Waiting for players…", 17, MUTED)
	hint_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint_label.offset_left = 410
	hint_label.offset_right = -42
	hint_label.offset_top = -62
	hint_label.offset_bottom = -24
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(hint_label)

	var safety := make_label("Hold tight. Make space. Don't throw your phone.", 12, Color("657086"))
	safety.position = Vector2(48, 648)
	safety.size = Vector2(330, 28)
	add_child(safety)


func make_label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func create_room() -> void:
	start_button.disabled = true
	status_label.text = "Contacting relay…"
	var error := room_request.request(server_base + "/api/rooms", ["Content-Type: application/json"], HTTPClient.METHOD_POST, "{}")
	if error != OK:
		show_error("Could not reach relay (%s)" % error)


func _on_room_created(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code != 201:
		show_error("Relay returned HTTP %d" % response_code)
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		show_error("Relay sent an invalid response")
		return
	room_code = data.get("roomCode", "")
	host_token = data.get("hostToken", "")
	join_url = data.get("joinUrl", "")
	room_label.text = room_code
	join_label.text = join_url
	status_label.text = "Room open • connect phones"
	start_button.text = "NEW ROOM"
	start_button.disabled = false
	load_qr_code()
	connect_socket()


func load_qr_code() -> void:
	qr_request.request(server_base + "/api/rooms/%s/qr.svg" % room_code)


func _on_qr_loaded(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code != 200:
		return
	var image := Image.new()
	if image.load_svg_from_buffer(body, 2.0) == OK:
		qr_rect.texture = ImageTexture.create_from_image(image)


func connect_socket() -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.close()
	socket = WebSocketPeer.new()
	var ws_base := server_base.replace("https://", "wss://").replace("http://", "ws://")
	var url := "%s/ws?role=host&room=%s&token=%s" % [ws_base, room_code, host_token]
	var error := socket.connect_to_url(url)
	if error != OK:
		show_error("WebSocket could not connect (%s)" % error)


func _process(delta: float) -> void:
	poll_socket()
	update_players(delta)
	queue_redraw()


func poll_socket() -> void:
	socket.poll()
	var state := socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not connected:
			connected = true
			status_label.text = "Relay connected"
		while socket.get_available_packet_count() > 0:
			var packet := socket.get_packet().get_string_from_utf8()
			var message = JSON.parse_string(packet)
			if typeof(message) == TYPE_DICTIONARY:
				handle_message(message)
	elif state == WebSocketPeer.STATE_CLOSED and connected:
		connected = false
		status_label.text = "Relay disconnected"


func handle_message(message: Dictionary) -> void:
	match message.get("type", ""):
		"room_state":
			players.clear()
			for player in message.get("players", []):
				add_player(player)
		"player_joined":
			add_player(message.get("player", {}))
		"player_left":
			players.erase(message.get("playerId", ""))
			update_hint()
		"motion":
			var id: String = message.get("playerId", "")
			if players.has(id):
				var player: Dictionary = players[id]
				var tilt: Array = message.get("tilt", [0.0, 0.0])
				player.tilt = Vector2(float(tilt[0]), float(tilt[1]))
				players[id] = player
		"action":
			if message.get("action", "") == "boost":
				boost_player(message.get("playerId", ""))


func add_player(data: Dictionary) -> void:
	var id: String = data.get("id", "")
	if id.is_empty():
		return
	var index := players.size()
	players[id] = {
		"name": data.get("name", "Player"),
		"color": Color.from_string(data.get("color", "#ffffff"), Color.WHITE),
		"position": arena_rect().get_center() + Vector2(cos(index * 1.7), sin(index * 1.7)) * 90.0,
		"velocity": Vector2.ZERO,
		"tilt": Vector2.ZERO,
		"boost": 0.0
	}
	update_hint()


func boost_player(id: String) -> void:
	if not players.has(id):
		return
	var player: Dictionary = players[id]
	var direction: Vector2 = player.tilt.normalized()
	if direction.length_squared() < 0.1:
		direction = Vector2.RIGHT
	player.velocity += direction * 420.0
	player.boost = 0.25
	players[id] = player


func update_players(delta: float) -> void:
	var bounds := arena_rect().grow(-PLAYER_RADIUS)
	for id in players.keys():
		var player: Dictionary = players[id]
		player.velocity = player.velocity.lerp(player.tilt * MOVE_SPEED, 1.0 - exp(-delta * 5.0))
		player.position += player.velocity * delta
		if player.position.x < bounds.position.x or player.position.x > bounds.end.x:
			player.velocity.x *= -0.55
			player.position.x = clamp(player.position.x, bounds.position.x, bounds.end.x)
		if player.position.y < bounds.position.y or player.position.y > bounds.end.y:
			player.velocity.y *= -0.55
			player.position.y = clamp(player.position.y, bounds.position.y, bounds.end.y)
		player.boost = maxf(0.0, player.boost - delta)
		players[id] = player


func update_hint() -> void:
	var count := players.size()
	if count == 0:
		hint_label.text = "Waiting for players…"
	elif count == 1:
		hint_label.text = "1 player connected • tilt to move • BOOST to dash"
	else:
		hint_label.text = "%d players connected • bump, dodge, and boost" % count


func show_error(message: String) -> void:
	status_label.text = message
	status_label.add_theme_color_override("font_color", Color("ff8ba1"))
	start_button.disabled = false


func arena_rect() -> Rect2:
	return Rect2(Vector2(390, 36), Vector2(maxf(500.0, size.x - 430.0), maxf(500.0, size.y - 116.0)))


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	draw_rect(Rect2(Vector2(24, 18), Vector2(330, size.y - 36)), PANEL, true)
	draw_rect(Rect2(Vector2(24, 18), Vector2(330, size.y - 36)), PANEL_EDGE, false, 1.0)
	var arena := arena_rect()
	draw_rect(arena, Color("141b29"), true)
	draw_rect(arena, PANEL_EDGE, false, 2.0)
	for x in range(int(arena.position.x) + 40, int(arena.end.x), 80):
		draw_line(Vector2(x, arena.position.y), Vector2(x, arena.end.y), Color(1, 1, 1, 0.025), 1.0)
	for y in range(int(arena.position.y) + 40, int(arena.end.y), 80):
		draw_line(Vector2(arena.position.x, y), Vector2(arena.end.x, y), Color(1, 1, 1, 0.025), 1.0)
	for player in players.values():
		var position: Vector2 = player.position
		var color: Color = player.color
		if player.boost > 0.0:
			draw_circle(position, PLAYER_RADIUS + 15.0, Color(color, 0.18))
		draw_circle(position + Vector2(0, 7), PLAYER_RADIUS, Color(0, 0, 0, 0.28))
		draw_circle(position, PLAYER_RADIUS, color)
		draw_circle(position, PLAYER_RADIUS, color.lightened(0.2), false, 3.0)
		draw_string(ThemeDB.fallback_font, position + Vector2(-PLAYER_RADIUS, -42), str(player.name), HORIZONTAL_ALIGNMENT_CENTER, PLAYER_RADIUS * 2.0, 16, TEXT)
