extends Control

enum Phase { LOBBY, TUTORIAL, PLAYING, RESULTS, FINAL }

const TEXT := Color("f7f8fc")
const MUTED := Color("8e99ad")
const CYAN := Color("58d6ff")
const GOLD := Color("ffd15c")

@export_group("Relay")
@export var server_base := "https://party.citradox.com"
@export_group("Gameplay")
@export_range(1.0, 120.0) var round_seconds := 25.0
@export_range(100.0, 1500.0) var move_speed := 700.0
@export_range(10.0, 60.0) var player_radius := 28.0
@export_group("Player Scenes")
@export var player_row_scene: PackedScene = preload("res://scenes/player_row.tscn")
@export var player_token_scene: PackedScene = preload("res://scenes/player_token.tscn")
@export var reactor_scene: PackedScene = preload("res://scenes/reactor.tscn")

var games: Array[Dictionary] = []
var player_views: Dictionary = {}
@onready var arena: Control = $Arena
@onready var lobby: Control = $Arena/Lobby
@onready var tutorial: Control = $Arena/Tutorial
@onready var tilt_game: Control = $Arena/TiltTreasure
@onready var shake_game: Control = $Arena/ShakeSprint
@onready var rotate_game: Control = $Arena/ReactorSpin
@onready var standings: Control = $Arena/Standings

var room_code := ""
var host_token := ""
var join_url := ""
var socket := WebSocketPeer.new()
var players: Dictionary = {}
@onready var room_request: HTTPRequest = $RoomRequest
@onready var qr_request: HTTPRequest = $QRRequest
@onready var title_label: Label = $Sidebar/Title
@onready var subtitle_label: Label = $Sidebar/Subtitle
@onready var status_label: Label = $Sidebar/Status
@onready var room_label: Label = $Sidebar/RoomCode
@onready var join_label: Label = $Sidebar/JoinURL
@onready var start_button: Button = $Sidebar/PrimaryButton
@onready var qr_rect: TextureRect = $Sidebar/QRCode
@onready var hint_label: Label = $Hint
@onready var timer_label: Label = $Timer
var connected := false
var phase := Phase.LOBBY
var current_game_index := 0
var round_time := 0.0
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
	for definition in $GameDefinitions.get_children():
		games.append(definition.as_dictionary())
	# Saved example instances make the other screens visible when editing.
	# Real players use the same scenes once they join.
	for container in [tilt_game.get_node("Players"), shake_game.get_node("Scroll/Players"), rotate_game.get_node("Scroll/Players"), standings.get_node("Scroll/Players")]:
		for preview in container.get_children():
			if preview.name == "PreviewPlayer":
				container.remove_child(preview)
				preview.queue_free()
	refresh_visuals()


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
	refresh_visuals()


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
		"party_command":
			handle_party_command(message.get("command", ""))


func handle_party_command(command: String) -> void:
	match command:
		"start_party":
			if phase == Phase.LOBBY:
				start_party()
		"start_round":
			if phase == Phase.TUTORIAL:
				start_round()
		"next_round":
			if phase == Phase.RESULTS and current_game_index < games.size() - 1:
				advance_after_results()
		"show_final":
			if phase == Phase.RESULTS and current_game_index == games.size() - 1:
				advance_after_results()
		"play_again":
			if phase == Phase.FINAL:
				start_party()


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
	return games[current_game_index]


func show_tutorial() -> void:
	phase = Phase.TUTORIAL
	var game := current_game()
	subtitle_label.text = "ROUND %d OF %d  /  %s" % [current_game_index + 1, games.size(), game["verb"]]
	timer_label.text = ""
	hint_label.text = game["goal"]
	start_button.text = "START ROUND"
	start_button.disabled = false
	sync_all_controllers()


func start_round() -> void:
	phase = Phase.PLAYING
	round_time = round_seconds
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
	var bounds := arena_rect().grow(-player_radius)
	for id in players.keys():
		var player: Dictionary = players[id]
		if not player["connected"]:
			continue
		player["velocity"] = player["velocity"].lerp(player["tilt"] * move_speed, 1.0 - exp(-delta * 5.0))
		var position: Vector2 = player["position"] + player["velocity"] * delta
		position.x = clamp(position.x, bounds.position.x, bounds.end.x)
		position.y = clamp(position.y, bounds.position.y, bounds.end.y)
		player["position"] = position
		if position.distance_to(target_position) < player_radius + 22.0:
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
	start_button.text = "FINAL RESULTS" if current_game_index == games.size() - 1 else "NEXT ROUND"
	start_button.disabled = false
	sync_all_controllers()


func advance_after_results() -> void:
	if current_game_index < games.size() - 1:
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
	var host_command := "start_party"
	var host_button_label := "START PARTY"
	var host_button_enabled := connected_player_count() > 0
	match phase:
		Phase.TUTORIAL:
			game_id = current_game()["id"]
			round_label = "ROUND %d OF %d" % [current_game_index + 1, games.size()]
			heading = current_game()["title"]
			instructions = current_game()["instructions"]
			host_command = "start_round"
			host_button_label = "START ROUND"
			host_button_enabled = true
		Phase.PLAYING:
			game_id = current_game()["id"]
			round_label = "GO!  ROUND %d" % (current_game_index + 1)
			heading = current_game()["verb"]
			instructions = current_game()["instructions"]
			host_command = ""
			host_button_label = "ROUND IN PROGRESS"
			host_button_enabled = false
		Phase.RESULTS:
			game_id = "results"
			round_label = "ROUND RESULTS"
			heading = "Score: %s" % score_text(player["round_score"])
			instructions = "Watch the shared screen for the standings."
			host_command = "show_final" if current_game_index == games.size() - 1 else "next_round"
			host_button_label = "FINAL RESULTS" if current_game_index == games.size() - 1 else "NEXT ROUND"
			host_button_enabled = true
		Phase.FINAL:
			game_id = "final"
			round_label = "FINAL RESULTS"
			heading = "%d crowns" % player["crowns"]
			instructions = "Thanks for playing Party Motion!"
			host_command = "play_again"
			host_button_label = "PLAY AGAIN"
			host_button_enabled = true
	send_json({
		"type": "controller_state", "playerId": id, "game": game_id,
		"roundLabel": round_label, "title": heading, "instructions": instructions,
		"crowns": player["crowns"], "points": player["points"],
		"hostCommand": host_command, "hostButtonLabel": host_button_label,
		"hostButtonEnabled": host_button_enabled
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
	return Rect2(arena.position, arena.size)


func ensure_player_views(id: String) -> Dictionary:
	if player_views.has(id):
		return player_views[id]
	var views := {}
	for screen in [lobby, shake_game, standings]:
		var row := player_row_scene.instantiate()
		row.name = "Player_" + id
		screen.get_node("Scroll/Players").add_child(row)
		views[screen.name] = row
	var token := player_token_scene.instantiate()
	token.name = "Player_" + id
	tilt_game.get_node("Players").add_child(token)
	views["token"] = token
	var reactor := reactor_scene.instantiate()
	reactor.name = "Player_" + id
	rotate_game.get_node("Scroll/Players").add_child(reactor)
	views["reactor"] = reactor
	player_views[id] = views
	return views


func refresh_visuals() -> void:
	lobby.visible = phase == Phase.LOBBY
	tutorial.visible = phase == Phase.TUTORIAL
	tilt_game.visible = phase == Phase.PLAYING and current_game()["id"] == "tilt"
	shake_game.visible = phase == Phase.PLAYING and current_game()["id"] == "shake"
	rotate_game.visible = phase == Phase.PLAYING and current_game()["id"] == "rotate"
	standings.visible = phase == Phase.RESULTS or phase == Phase.FINAL
	lobby.get_node("EmptyMessage").visible = players.is_empty()
	if tutorial.visible:
		var game := current_game()
		tutorial.get_node("Verb").text = game["verb"]
		tutorial.get_node("Title").text = game["title"]
		tutorial.get_node("Instructions").text = game["instructions"]
		tutorial.get_node("Goal").text = game["goal"]
	tilt_game.get_node("Target").position = target_position - arena.position
	standings.get_node("Heading").text = "PARTY CHAMPION" if phase == Phase.FINAL else "ROUND COMPLETE"
	for id in players:
		var player: Dictionary = players[id]
		var views := ensure_player_views(id)
		for screen_name in ["Lobby", "ShakeSprint", "Standings"]:
			var row: HBoxContainer = views[screen_name]
			row.get_node("Name").text = player["name"]
			row.get_node("Name").modulate = TEXT if player["connected"] else MUTED
			row.get_node("Swatch").color = player["color"]
			row.get_node("Progress").visible = screen_name == "ShakeSprint"
			row.get_node("Progress").value = clampf(player["round_score"] / 10.0, 0.0, 1.0) * 100.0
			row.get_node("Progress").modulate = player["color"]
			if screen_name == "Lobby":
				row.get_node("Detail").text = "READY" if player["connected"] else "OFFLINE"
				row.get_node("Detail").modulate = CYAN if player["connected"] else MUTED
			elif screen_name == "Standings":
				row.get_node("Detail").text = "♛ %d    %d PTS" % [player["crowns"], player["points"]]
				row.get_node("Detail").modulate = GOLD
			else:
				row.get_node("Detail").text = "%d%%" % int(clampf(player["round_score"] / 10.0, 0.0, 1.0) * 100.0)
		var token: Node2D = views["token"]
		token.visible = player["connected"]
		token.position = player["position"] - arena.position
		token.get_node("Body").modulate = player["color"]
		token.get_node("Body").scale = Vector2.ONE * player_radius / 28.0
		token.get_node("Name").text = "%s  %d" % [player["name"], int(player["round_score"])]
		var reactor: VBoxContainer = views["reactor"]
		var ratio := clampf(player["round_score"] / 12.0, 0.0, 1.0)
		reactor.get_node("Name").text = player["name"]
		reactor.get_node("Gauge/Ring").modulate = player["color"]
		reactor.get_node("Gauge/Charge").modulate = player["color"]
		reactor.get_node("Gauge/Charge").value = ratio * 100.0
		reactor.get_node("Gauge/Percent").text = "%d%%" % int(ratio * 100.0)
	var rankings := final_rankings if phase == Phase.FINAL else last_rankings
	for index in range(rankings.size()):
		var row: HBoxContainer = player_views[rankings[index]]["Standings"]
		row.get_node("Name").text = "%d.  %s" % [index + 1, players[rankings[index]]["name"]]
		row.get_parent().move_child(row, index)
	if shake_game.visible or rotate_game.visible:
		var ids := ranked_player_ids()
		for index in range(ids.size()):
			var views: Dictionary = player_views[ids[index]]
			var row: Node = views["ShakeSprint"]
			row.get_parent().move_child(row, index)
			var reactor: Node = views["reactor"]
			reactor.get_parent().move_child(reactor, index)
