# Keeps the room and phone connections alive while lobby/game scenes are replaced.
extends Node

signal changed

var server_base := "https://party.citradox.com"
var room_code := ""
var host_token := ""
var players: Dictionary = {}
var connected := false
var busy := false
var status := "Create a room to begin"
var qr_texture: Texture2D
var active_game: Control
var transitioning := false
var socket := WebSocketPeer.new()
var room_request := HTTPRequest.new()
var qr_request := HTTPRequest.new()


func _ready() -> void:
	var configured_url := OS.get_environment("PARTY_RELAY_URL")
	if not configured_url.is_empty():
		server_base = configured_url
	server_base = server_base.trim_suffix("/")
	add_child(room_request)
	add_child(qr_request)
	room_request.timeout = 15
	qr_request.timeout = 15
	room_request.request_completed.connect(_on_room_created)
	qr_request.request_completed.connect(_on_qr_loaded)


## The shared-screen button and leader's phone use the same phase-specific command.
func primary_action() -> void:
	if room_code.is_empty():
		create_room()
	elif not connected:
		connect_socket()
	elif is_instance_valid(active_game):
		active_game.handle_command(active_game.controller_state("")["hostCommand"], players)
	else:
		start_party()


func create_room() -> void:
	if busy:
		return
	busy = true
	status = "Creating your room..."
	changed.emit()
	if room_request.request(server_base + "/api/rooms", ["Content-Type: application/json"], HTTPClient.METHOD_POST, "{}") != OK:
		show_error("Could not reach relay. Try again.")


## Validate the credentials before opening the persistent host connection.
func _on_room_created(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 201:
		show_error("Could not create room. Try again.")
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if not data is Dictionary or not data.has_all(["roomCode", "hostToken"]):
		show_error("Invalid room response. Try again.")
		return
	room_code = str(data["roomCode"])
	host_token = str(data["hostToken"])
	if room_code.is_empty() or host_token.is_empty():
		room_code = ""
		show_error("Invalid room response. Try again.")
		return
	qr_request.request(server_base + "/api/rooms/%s/qr.svg" % room_code)
	connect_socket()


func _on_qr_loaded(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var image := Image.new()
		if image.load_svg_from_buffer(body, 2.0) == OK:
			qr_texture = ImageTexture.create_from_image(image)
	changed.emit()


func connect_socket() -> void:
	socket.close()
	socket = WebSocketPeer.new()
	connected = false
	busy = true
	status = "Connecting..."
	changed.emit()
	var ws_base := server_base.replace("https://", "wss://").replace("http://", "ws://")
	if socket.connect_to_url("%s/ws?role=host&room=%s&token=%s" % [ws_base, room_code.uri_encode(), host_token.uri_encode()]) != OK:
		show_error("Connection failed. Try again.")


func _process(_delta: float) -> void:
	socket.poll()
	var state := socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not connected:
			connected = true
			busy = false
			status = "Room open. Grab your phones!"
			update_roster()
		while socket.get_available_packet_count() > 0:
			var message = JSON.parse_string(socket.get_packet().get_string_from_utf8())
			if message is Dictionary:
				handle_message(message)
	elif state == WebSocketPeer.STATE_CLOSED and (connected or (busy and not room_code.is_empty())):
		connected = false
		for player in players.values():
			player["connected"] = false
		update_roster()
		show_error("Connection lost. Try again.")


## Apply relay events to shared state; motion is delivered only to the active game.
func handle_message(message: Dictionary) -> void:
	match message.get("type", ""):
		"room_state":
			for player in players.values():
				player["connected"] = false
			for player in message.get("players", []):
				store_player(player)
			update_roster()
		"player_joined":
			store_player(message.get("player", {}))
			update_roster()
		"player_left":
			var id := str(message.get("playerId", ""))
			if players.has(id):
				players[id]["connected"] = false
				update_roster()
		"party_command":
			if not connected:
				return
			var command := str(message.get("command", ""))
			if command == "start_party":
				start_party()
			elif is_instance_valid(active_game):
				active_game.handle_command(command, players)
		"motion":
			if is_instance_valid(active_game):
				var axes = message.get("tilt", [])
				if axes is Array:
					active_game.apply_motion(str(message.get("playerId", "")), axes)


func store_player(data: Dictionary) -> void:
	var id := str(data.get("id", ""))
	if not id.is_empty():
		players[id] = {"name": str(data.get("name", "Player")), "color": Color.from_string(str(data.get("color", "#6ee8ad")), Color.WHITE), "connected": true}


func online_count() -> int:
	var count := 0
	for player in players.values():
		count += int(player["connected"])
	return count


func update_roster() -> void:
	if is_instance_valid(active_game):
		active_game.sync_roster(players)
	changed.emit()
	sync_controllers()


## Replace the lobby with the game; this autoload and its socket remain alive.
func start_party() -> void:
	if not connected or online_count() == 0 or transitioning or is_instance_valid(active_game):
		return
	transitioning = true
	if get_tree().change_scene_to_file("res://party motion/scenes/motion_munch.tscn") != OK:
		transitioning = false
		show_error("Could not load Motion Munch.")


func return_to_lobby() -> void:
	if transitioning:
		return
	transitioning = true
	if get_tree().change_scene_to_file("res://party motion/scenes/main.tscn") != OK:
		transitioning = false
		show_error("Could not load the lobby.")


## Describe the current UI step using the existing phone/relay message format.
func controller_state(id: String) -> Dictionary:
	if is_instance_valid(active_game):
		var state: Dictionary = active_game.controller_state(id)
		state["hostButtonEnabled"] = connected and state["hostButtonEnabled"] and not transitioning
		return state
	return {
		"game": "lobby", "roundLabel": "LOBBY", "title": "You're in!",
		"instructions": "Watch the shared screen. Calibrate when ready.",
		"crowns": 0, "points": 0, "hostCommand": "start_party",
		"hostButtonLabel": "START PARTY",
		"hostButtonEnabled": connected and online_count() > 0 and not transitioning
	}


func sync_controllers() -> void:
	if socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	for id in players:
		var state := controller_state(id)
		state["type"] = "controller_state"
		state["playerId"] = id
		socket.send_text(JSON.stringify(state))


func show_error(message: String) -> void:
	busy = false
	status = message
	changed.emit()


func _exit_tree() -> void:
	socket.close()
