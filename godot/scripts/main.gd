extends Control

enum Phase { LOBBY, TUTORIAL, PLAYING, RESULTS, FINAL }

const BG := Color("101522")
const PANEL := Color("171e2e")
const PANEL_EDGE := Color("303a50")
const TEXT := Color("f7f8fc")
const MUTED := Color("8e99ad")
const CYAN := Color("58d6ff")
const GOLD := Color("ffd15c")
const PLAYER_RADIUS := 28.0
const MOVE_SPEED := 700.0
const ROUND_SECONDS := 25.0
const GAMES := [
	{
		"id": "tilt",
		"title": "Tilt Treasure",
		"verb": "TILT",
		"instructions": "Tilt your phone to steer. Collect as many glowing stars as you can.",
		"goal": "Most stars wins"
	},
	{
		"id": "shake",
		"title": "Shake Sprint",
		"verb": "SHAKE",
		"instructions": "Shake your phone in short, steady strokes to race toward the finish.",
		"goal": "First to the finish wins"
	},
	{
		"id": "rotate",
		"title": "Reactor Spin",
		"verb": "ROTATE",
		"instructions": "Rotate and twist your phone back and forth to charge your reactor.",
		"goal": "First full reactor wins"
	}
]

var server_base := "https://party.citradox.com"
var room_code := ""
var host_token := ""
var join_url := ""
var socket := WebSocketPeer.new()
var players: Dictionary = {}
var room_request: HTTPRequest
var qr_request: HTTPRequest
var title_label: Label
var subtitle_label: Label
var status_label: Label
var room_label: Label
var join_label: Label
var start_button: Button
var qr_rect: TextureRect
var hint_label: Label
var timer_label: Label
var connected := false
var phase := Phase.LOBBY
var current_game_index := 0
var round_time := ROUND_SECONDS
var join_counter := 0
var target_position := Vector2.ZERO
var last_rankings: Array = []
var final_rankings: Array = []
var rng := RandomNumberGenerator.new()


func _ready() -> void:
	var configured_url := OS.get_environment("PARTY_RELAY_URL")
	if not configured_url.is_empty():
		server_base = configured_url.trim_suffix("/")
	rng.randomize()
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

	subtitle_label = make_label("MOTION-ONLY PARTY GAMES", 14, CYAN)
	subtitle_label.position = Vector2(47, 80)
	subtitle_label.size = Vector2(500, 28)
	add_child(subtitle_label)

	status_label = make_label("Create a room to begin", 18, MUTED)
	status_label.position = Vector2(47, 132)
	status_label.size = Vector2(310, 34)
	add_child(status_label)

	room_label = make_label("------", 52, TEXT)
	room_label.position = Vector2(46, 174)
	room_label.size = Vector2(300, 70)
	room_label.add_theme_constant_override("outline_size", 10)
	room_label.add_theme_color_override("font_outline_color", BG)
	add_child(room_label)

	join_label = make_label("Players scan the QR code\nor enter the room code", 13, MUTED)
	join_label.position = Vector2(48, 246)
	join_label.size = Vector2(294, 62)
	join_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(join_label)

	qr_rect = TextureRect.new()
	qr_rect.position = Vector2(48, 312)
	qr_rect.size = Vector2(190, 190)
	qr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(qr_rect)

	start_button = Button.new()
	start_button.text = "CREATE ROOM"
	start_button.position = Vector2(48, 530)
	start_button.size = Vector2(270, 58)
	start_button.add_theme_font_size_override("font_size", 18)
	start_button.pressed.connect(_on_primary_button)
	add_child(start_button)

	var safety := make_label("Hold tight. Make space. Never throw your phone.", 11, Color("657086"))
	safety.position = Vector2(48, 616)
	safety.size = Vector2(290, 48)
	safety.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(safety)

	timer_label = make_label("", 30, TEXT)
	timer_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	timer_label.offset_left = -150
	timer_label.offset_right = -44
	timer_label.offset_top = 42
	timer_label.offset_bottom = 90
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(timer_label)

	hint_label = make_label("Waiting for players…", 16, MUTED)
	hint_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint_label.offset_left = 390
	hint_label.offset_right = -42
	hint_label.offset_top = -54
	hint_label.offset_bottom = -20
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(hint_label)


func make_label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _on_primary_button() -> void:
	if room_code.is_empty():
		create_room()
		return
	match phase:
		Phase.LOBBY:
			start_party()
		Phase.TUTORIAL:
			start_round()
		Phase.RESULTS:
			advance_after_results()
		Phase.FINAL:
			start_party()


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
	start_button.text = "START PARTY"
	start_button.disabled = true
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
	if phase == Phase.PLAYING:
		round_time = maxf(0.0, round_time - delta)
		timer_label.text = "%02d" % ceili(round_time)
		update_minigame(delta)
		if round_time <= 0.0 and phase == Phase.PLAYING:
			end_round()
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
			for id in players.keys():
				var existing: Dictionary = players[id]
				existing["connected"] = false
				players[id] = existing
			for player in message.get("players", []):
				add_player(player)
		"player_joined":
			var player_data: Dictionary = message.get("player", {})
			add_player(player_data)
			sync_controller(player_data.get("id", ""))
		"player_left":
			mark_player_disconnected(message.get("playerId", ""))
		"motion":
			apply_motion(message)


func add_player(data: Dictionary) -> void:
	var id: String = data.get("id", "")
	if id.is_empty():
		return
	if players.has(id):
		var returning: Dictionary = players[id]
		returning["connected"] = true
		returning["name"] = data.get("name", returning["name"])
		returning["color"] = Color.from_string(data.get("color", "#ffffff"), returning["color"])
		players[id] = returning
	else:
		join_counter += 1
		var index := players.size()
		players[id] = {
			"name": data.get("name", "Player"),
			"color": Color.from_string(data.get("color", "#ffffff"), Color.WHITE),
			"connected": true,
			"position": arena_rect().get_center() + Vector2(cos(index * 1.7), sin(index * 1.7)) * 90.0,
			"velocity": Vector2.ZERO,
			"tilt": Vector2.ZERO,
			"shake": 0.0,
			"rotation": Vector3.ZERO,
			"crowns": 0,
			"points": 0,
			"total_score": 0.0,
			"round_score": 0.0,
			"join_order": join_counter
		}
	update_lobby_ui()


func mark_player_disconnected(id: String) -> void:
	if not players.has(id):
		return
	var player: Dictionary = players[id]
	player["connected"] = false
	player["tilt"] = Vector2.ZERO
	player["shake"] = 0.0
	player["rotation"] = Vector3.ZERO
	players[id] = player
	update_lobby_ui()


func apply_motion(message: Dictionary) -> void:
	var id: String = message.get("playerId", "")
	if not players.has(id):
		return
	var player: Dictionary = players[id]
	var tilt: Array = message.get("tilt", [0.0, 0.0])
	var rotation: Array = message.get("rotation", [0.0, 0.0, 0.0])
	player["tilt"] = Vector2(float(tilt[0]), float(tilt[1]))
	player["shake"] = float(message.get("shake", 0.0))
	player["rotation"] = Vector3(float(rotation[0]), float(rotation[1]), float(rotation[2]))
	players[id] = player


func connected_player_count() -> int:
	var count := 0
	for player in players.values():
		if player["connected"]:
			count += 1
	return count


func update_lobby_ui() -> void:
	var count := connected_player_count()
	if phase == Phase.LOBBY:
		hint_label.text = "%d player%s connected" % [count, "" if count == 1 else "s"]
		start_button.disabled = room_code.is_empty() or count == 0


func start_party() -> void:
	if connected_player_count() == 0:
		return
	for id in players.keys():
		var player: Dictionary = players[id]
		player["crowns"] = 0
		player["points"] = 0
		player["total_score"] = 0.0
		player["round_score"] = 0.0
		players[id] = player
	current_game_index = 0
	show_tutorial()


func current_game() -> Dictionary:
	return GAMES[current_game_index]


func show_tutorial() -> void:
	phase = Phase.TUTORIAL
	var game := current_game()
	subtitle_label.text = "ROUND %d OF %d  /  %s" % [current_game_index + 1, GAMES.size(), game["verb"]]
	timer_label.text = ""
	hint_label.text = game["goal"]
	start_button.text = "START ROUND"
	start_button.disabled = false
	sync_all_controllers()


func start_round() -> void:
	phase = Phase.PLAYING
	round_time = ROUND_SECONDS
	for id in players.keys():
		var player: Dictionary = players[id]
		player["round_score"] = 0.0
		player["shake"] = 0.0
		player["rotation"] = Vector3.ZERO
		player["velocity"] = Vector2.ZERO
		players[id] = player
	spawn_target()
	start_button.disabled = true
	start_button.text = "ROUND IN PROGRESS"
	hint_label.text = current_game()["instructions"]
	sync_all_controllers()


func update_minigame(delta: float) -> void:
	match current_game()["id"]:
		"tilt":
			update_tilt_game(delta)
		"shake":
			update_shake_game(delta)
		"rotate":
			update_rotate_game(delta)


func update_tilt_game(delta: float) -> void:
	var bounds := arena_rect().grow(-PLAYER_RADIUS)
	for id in players.keys():
		var player: Dictionary = players[id]
		if not player["connected"]:
			continue
		player["velocity"] = player["velocity"].lerp(player["tilt"] * MOVE_SPEED, 1.0 - exp(-delta * 5.0))
		var position: Vector2 = player["position"] + player["velocity"] * delta
		position.x = clamp(position.x, bounds.position.x, bounds.end.x)
		position.y = clamp(position.y, bounds.position.y, bounds.end.y)
		player["position"] = position
		if position.distance_to(target_position) < PLAYER_RADIUS + 22.0:
			player["round_score"] += 1.0
			spawn_target()
		players[id] = player


func update_shake_game(delta: float) -> void:
	for id in players.keys():
		var player: Dictionary = players[id]
		if not player["connected"]:
			continue
		player["round_score"] = minf(10.0, player["round_score"] + player["shake"] * delta * 1.35)
		players[id] = player
		if player["round_score"] >= 10.0:
			end_round()
			return


func update_rotate_game(delta: float) -> void:
	for id in players.keys():
		var player: Dictionary = players[id]
		if not player["connected"]:
			continue
		var rotation_strength: float = maxf(absf(player["rotation"].x), maxf(absf(player["rotation"].y), absf(player["rotation"].z)))
		if rotation_strength > 25.0:
			player["round_score"] = minf(12.0, player["round_score"] + rotation_strength / 220.0 * delta)
		players[id] = player
		if player["round_score"] >= 12.0:
			end_round()
			return


func spawn_target() -> void:
	var bounds := arena_rect().grow(-70.0)
	target_position = Vector2(rng.randf_range(bounds.position.x, bounds.end.x), rng.randf_range(bounds.position.y, bounds.end.y))


func ranked_player_ids() -> Array:
	var ids: Array = players.keys()
	ids.sort_custom(func(a, b): return players[a]["round_score"] > players[b]["round_score"])
	return ids


func end_round() -> void:
	if phase != Phase.PLAYING:
		return
	phase = Phase.RESULTS
	timer_label.text = ""
	last_rankings = ranked_player_ids()
	var placement_points := [5, 3, 2, 1]
	for index in range(last_rankings.size()):
		var id: String = last_rankings[index]
		var player: Dictionary = players[id]
		if index == 0:
			player["crowns"] += 1
		player["points"] += placement_points[mini(index, placement_points.size() - 1)]
		player["total_score"] += player["round_score"]
		players[id] = player
	subtitle_label.text = "ROUND %d RESULTS" % (current_game_index + 1)
	hint_label.text = "%s takes the crown!" % players[last_rankings[0]]["name"] if not last_rankings.is_empty() else "Round complete"
	start_button.text = "FINAL RESULTS" if current_game_index == GAMES.size() - 1 else "NEXT ROUND"
	start_button.disabled = false
	sync_all_controllers()


func advance_after_results() -> void:
	if current_game_index < GAMES.size() - 1:
		current_game_index += 1
		show_tutorial()
	else:
		show_final_results()


func show_final_results() -> void:
	phase = Phase.FINAL
	final_rankings = players.keys()
	final_rankings.sort_custom(func(a, b):
		var left: Dictionary = players[a]
		var right: Dictionary = players[b]
		if left["crowns"] != right["crowns"]:
			return left["crowns"] > right["crowns"]
		if left["points"] != right["points"]:
			return left["points"] > right["points"]
		if not is_equal_approx(left["total_score"], right["total_score"]):
			return left["total_score"] > right["total_score"]
		return left["join_order"] < right["join_order"]
	)
	subtitle_label.text = "FINAL STANDINGS"
	hint_label.text = "%s wins Party Motion!" % players[final_rankings[0]]["name"]
	start_button.text = "PLAY AGAIN"
	start_button.disabled = false
	sync_all_controllers()


func sync_all_controllers() -> void:
	for id in players.keys():
		sync_controller(id)


func sync_controller(id: String) -> void:
	if id.is_empty() or not players.has(id):
		return
	var player: Dictionary = players[id]
	var game_id := "lobby"
	var round_label := "LOBBY"
	var heading := "Waiting for the host"
	var instructions := "Hold your phone naturally and calibrate when ready."
	match phase:
		Phase.TUTORIAL:
			game_id = current_game()["id"]
			round_label = "ROUND %d OF %d" % [current_game_index + 1, GAMES.size()]
			heading = current_game()["title"]
			instructions = current_game()["instructions"]
		Phase.PLAYING:
			game_id = current_game()["id"]
			round_label = "GO!  ROUND %d" % (current_game_index + 1)
			heading = current_game()["verb"]
			instructions = current_game()["instructions"]
		Phase.RESULTS:
			game_id = "results"
			round_label = "ROUND RESULTS"
			heading = "Score: %s" % score_text(player["round_score"])
			instructions = "Watch the shared screen for the standings."
		Phase.FINAL:
			game_id = "final"
			round_label = "FINAL RESULTS"
			heading = "%d crowns" % player["crowns"]
			instructions = "Thanks for playing Party Motion!"
	send_json({
		"type": "controller_state", "playerId": id, "game": game_id,
		"roundLabel": round_label, "title": heading, "instructions": instructions,
		"crowns": player["crowns"], "points": player["points"]
	})


func send_json(message: Dictionary) -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(message))


func score_text(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(int(value))
	return "%.1f" % value


func show_error(message: String) -> void:
	status_label.text = message
	status_label.add_theme_color_override("font_color", Color("ff8ba1"))
	start_button.disabled = false


func arena_rect() -> Rect2:
	return Rect2(Vector2(380, 112), Vector2(maxf(560.0, size.x - 420.0), maxf(460.0, size.y - 190.0)))


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	draw_rect(Rect2(Vector2(24, 18), Vector2(330, size.y - 36)), PANEL, true)
	draw_rect(Rect2(Vector2(24, 18), Vector2(330, size.y - 36)), PANEL_EDGE, false, 1.0)
	var arena := arena_rect()
	draw_rect(arena, Color("141b29"), true)
	draw_rect(arena, PANEL_EDGE, false, 2.0)
	match phase:
		Phase.LOBBY:
			draw_lobby(arena)
		Phase.TUTORIAL:
			draw_tutorial(arena)
		Phase.PLAYING:
			draw_active_game(arena)
		Phase.RESULTS:
			draw_standings(arena, last_rankings, "ROUND COMPLETE")
		Phase.FINAL:
			draw_standings(arena, final_rankings, "PARTY CHAMPION")


func draw_lobby(arena: Rect2) -> void:
	draw_centered("PLAYERS", arena.position.y + 62, 22, MUTED)
	var index := 0
	for player in players.values():
		var y := arena.position.y + 112 + index * 62
		draw_circle(Vector2(arena.position.x + 110, y), 18, player["color"])
		draw_string(ThemeDB.fallback_font, Vector2(arena.position.x + 145, y + 7), player["name"], HORIZONTAL_ALIGNMENT_LEFT, -1, 22, TEXT if player["connected"] else MUTED)
		draw_string(ThemeDB.fallback_font, Vector2(arena.end.x - 160, y + 6), "READY" if player["connected"] else "OFFLINE", HORIZONTAL_ALIGNMENT_RIGHT, 120, 14, CYAN if player["connected"] else MUTED)
		index += 1
	if players.is_empty():
		draw_centered("Scan the QR code to join", arena.get_center().y, 26, MUTED)


func draw_tutorial(arena: Rect2) -> void:
	var game := current_game()
	draw_centered(game["verb"], arena.position.y + 120, 64, CYAN)
	draw_centered(game["title"], arena.position.y + 195, 36, TEXT)
	draw_centered(game["instructions"], arena.position.y + 260, 19, MUTED)
	draw_centered(game["goal"], arena.position.y + 330, 22, GOLD)


func draw_active_game(arena: Rect2) -> void:
	match current_game()["id"]:
		"tilt":
			draw_tilt_game(arena)
		"shake":
			draw_progress_race(arena, 10.0, "SHAKE TO RUN")
		"rotate":
			draw_reactors(arena)


func draw_tilt_game(arena: Rect2) -> void:
	for x in range(int(arena.position.x) + 40, int(arena.end.x), 80):
		draw_line(Vector2(x, arena.position.y), Vector2(x, arena.end.y), Color(1, 1, 1, 0.025), 1.0)
	for y in range(int(arena.position.y) + 40, int(arena.end.y), 80):
		draw_line(Vector2(arena.position.x, y), Vector2(arena.end.x, y), Color(1, 1, 1, 0.025), 1.0)
	draw_circle(target_position, 30, Color(GOLD, 0.16))
	draw_circle(target_position, 17, GOLD)
	for player in players.values():
		if not player["connected"]:
			continue
		var position: Vector2 = player["position"]
		draw_circle(position + Vector2(0, 6), PLAYER_RADIUS, Color(0, 0, 0, 0.25))
		draw_circle(position, PLAYER_RADIUS, player["color"])
		draw_string(ThemeDB.fallback_font, position + Vector2(-42, -38), "%s  %d" % [player["name"], int(player["round_score"])], HORIZONTAL_ALIGNMENT_CENTER, 84, 15, TEXT)


func draw_progress_race(arena: Rect2, goal: float, heading: String) -> void:
	draw_centered(heading, arena.position.y + 52, 21, CYAN)
	var ids := ranked_player_ids()
	for index in range(ids.size()):
		var player: Dictionary = players[ids[index]]
		var y := arena.position.y + 105 + index * 76
		var track := Rect2(Vector2(arena.position.x + 120, y), Vector2(arena.size.x - 210, 22))
		draw_string(ThemeDB.fallback_font, Vector2(arena.position.x + 24, y + 18), player["name"], HORIZONTAL_ALIGNMENT_LEFT, 88, 15, TEXT)
		draw_rect(track, PANEL_EDGE, true)
		draw_rect(Rect2(track.position, Vector2(track.size.x * clampf(player["round_score"] / goal, 0.0, 1.0), track.size.y)), player["color"], true)
		draw_circle(Vector2(track.position.x + track.size.x * clampf(player["round_score"] / goal, 0.0, 1.0), y + 11), 16, player["color"].lightened(0.2))


func draw_reactors(arena: Rect2) -> void:
	draw_centered("ROTATE TO CHARGE", arena.position.y + 52, 21, CYAN)
	var ids := ranked_player_ids()
	var columns := maxi(1, mini(3, ids.size()))
	for index in range(ids.size()):
		var player: Dictionary = players[ids[index]]
		var column := index % columns
		var row := index / columns
		var center := Vector2(arena.position.x + arena.size.x * (float(column) + 0.5) / columns, arena.position.y + 175 + row * 190)
		var ratio: float = clampf(player["round_score"] / 12.0, 0.0, 1.0)
		draw_circle(center, 64, Color(1, 1, 1, 0.04))
		draw_arc(center, 64, -PI / 2.0, -PI / 2.0 + TAU * ratio, 64, player["color"], 12.0, true)
		draw_string(ThemeDB.fallback_font, center + Vector2(-70, 6), "%d%%" % int(ratio * 100.0), HORIZONTAL_ALIGNMENT_CENTER, 140, 25, TEXT)
		draw_string(ThemeDB.fallback_font, center + Vector2(-70, 92), player["name"], HORIZONTAL_ALIGNMENT_CENTER, 140, 17, TEXT)


func draw_standings(arena: Rect2, rankings: Array, heading: String) -> void:
	draw_centered(heading, arena.position.y + 60, 25, GOLD)
	for index in range(rankings.size()):
		var player: Dictionary = players[rankings[index]]
		var y := arena.position.y + 115 + index * 72
		var row := Rect2(Vector2(arena.position.x + 70, y), Vector2(arena.size.x - 140, 54))
		draw_rect(row, Color(player["color"], 0.11), true)
		draw_string(ThemeDB.fallback_font, Vector2(row.position.x + 18, y + 36), "%d" % (index + 1), HORIZONTAL_ALIGNMENT_LEFT, 42, 25, player["color"])
		draw_string(ThemeDB.fallback_font, Vector2(row.position.x + 68, y + 34), player["name"], HORIZONTAL_ALIGNMENT_LEFT, 260, 21, TEXT)
		draw_string(ThemeDB.fallback_font, Vector2(row.end.x - 250, y + 34), "♛ %d    %d PTS" % [player["crowns"], player["points"]], HORIZONTAL_ALIGNMENT_RIGHT, 230, 18, GOLD)


func draw_centered(value: String, y: float, font_size: int, color: Color) -> void:
	var arena := arena_rect()
	draw_string(ThemeDB.fallback_font, Vector2(arena.position.x, y), value, HORIZONTAL_ALIGNMENT_CENTER, arena.size.x, font_size, color)
