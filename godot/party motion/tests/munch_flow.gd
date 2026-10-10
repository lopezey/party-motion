# Run with Godot --headless --path godot --script "res://party motion/tests/munch_flow.gd".
extends SceneTree


func _initialize() -> void:
	call_deferred("verify")
	create_timer(20).timeout.connect(func(): push_error("Motion Munch test timed out"); quit(1))


func snapshot(filename: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("C:/Users/eder5/Documents/Code/party-motion/work/" + filename + ".png")


func verify() -> void:
	var scene_file: PackedScene = load("res://party motion/scenes/main.tscn")
	assert(scene_file.get_state().get_base_scene_state() == null)
	assert(change_scene_to_packed(scene_file) == OK)
	await scene_changed
	var lobby = current_scene
	assert(not lobby.has_node("MotionMunch"))
	var scene = root.get_node("PartySession")
	scene.set_process(false)
	var original_socket = scene.socket
	scene.connected = true
	scene.room_code = "ABCDEF"
	scene.host_token = "test-host-token"
	scene.handle_message({"type": "player_joined", "player": {"id": "a", "name": "EDER", "color": "#b7ed72"}})
	scene.handle_message({"type": "player_joined", "player": {"id": "b", "name": "MAYA", "color": "#ee87b1"}})
	assert(scene.controller_state("a")["hostButtonEnabled"])
	scene.handle_message({"type": "party_command", "command": "start_party"})
	await scene_changed
	var game = current_scene
	assert(not is_instance_valid(lobby))
	assert(game.scene_file_path == "res://party motion/scenes/motion_munch.tscn")
	assert(scene.socket == original_socket and scene.host_token == "test-host-token")
	game.set_physics_process(false)
	assert(game.active and game.phase == game.Phase.TUTORIAL)
	assert(game.get_node("Arena/Tutorial").visible)
	assert(not game.get_node("Arena/Field").visible)
	assert(scene.controller_state("a")["hostCommand"] == "start_round")
	await snapshot("munch-tutorial")
	scene.handle_message({"type": "party_command", "command": "start_round"})
	assert(game.phase == game.Phase.COUNTDOWN and game.avatars.size() == 2)
	assert(game.arena.position == Vector2.ZERO)
	assert(game.arena.size == game.size)
	assert(not game.get_node("Title").visible and not game.get_node("Hint").visible)
	assert(game.get_node("Arena/Field").visible)
	# A duplicated leader command must not reset an already-started round.
	scene.handle_message({"type": "party_command", "command": "start_round"})
	game._physics_process(3.1)
	assert(game.phase == game.Phase.PLAYING)
	assert(not scene.controller_state("a")["hostButtonEnabled"])
	scene.handle_message({"type": "motion", "playerId": "a", "tilt": [1.0, 0.0]})
	var before: Vector2 = game.avatars["a"].position
	game._physics_process(0.1)
	assert(game.avatars["a"].position.x > before.x)
	game.apply_motion("a", [NAN, 0])
	assert(game.participants["a"]["tilt"] == Vector2(1, 0))
	game._physics_process(0.4)
	var stopped: Vector2 = game.avatars["a"].position
	game._physics_process(0.1)
	assert(game.avatars["a"].position == stopped)
	# Test a real Area2D overlap through the engine's physics callbacks.
	var target = game.snacks.get_child(0)
	game.avatars["a"].position = target.position
	for index in range(6):
		await physics_frame
		await process_frame
	assert(game.participants["a"]["score"] >= 1)
	await snapshot("munch-playing")
	# Late players spectate until replay; disconnect/rejoin retains scores.
	scene.handle_message({"type": "player_joined", "player": {"id": "c", "name": "JULES", "color": "#40e0c8"}})
	assert(not game.participants.has("c"))
	assert(scene.controller_state("c")["instructions"].contains("next one"))
	var score: int = game.participants["a"]["score"]
	scene.handle_message({"type": "player_left", "playerId": "a"})
	scene.handle_message({"type": "player_left", "playerId": "b"})
	var paused_time: float = game.time_left
	game._physics_process(1)
	assert(game.time_left == paused_time)
	scene.handle_message({"type": "player_joined", "player": {"id": "a", "name": "EDER", "color": "#b7ed72"}})
	assert(game.participants["a"]["score"] == score)
	game.participants["b"]["score"] = score
	game.time_left = 0.01
	game._physics_process(0.1)
	assert(game.phase == game.Phase.RESULTS)
	assert(game.get_node("Arena/Results/Heading").text == "SHARED WIN!")
	assert(scene.controller_state("a")["hostCommand"] == "play_again")
	await snapshot("munch-results")
	scene.handle_message({"type": "party_command", "command": "play_again"})
	assert(game.phase == game.Phase.TUTORIAL)
	assert(game.get_node("Title").visible and game.get_node("Arena/Tutorial").visible)
	assert(game.participants.has("c") and not game.participants.has("b"))
	assert(game.participants["a"]["score"] == 0)
	for index in range(6):
		scene.store_player({"id": "extra%d" % index, "name": "LONG PLAYER NAME %d" % index, "color": "#b29aee"})
	game.begin(scene.players)
	game.prepare_round()
	game._physics_process(3.1)
	assert(game.avatars.size() == 8)
	await snapshot("munch-eight-playing")
	game.finish_round()
	await snapshot("munch-eight-results")
	game._on_back_to_lobby()
	await scene_changed
	assert(current_scene.scene_file_path == "res://party motion/scenes/main.tscn")
	assert(not is_instance_valid(game))
	assert(scene.active_game == null)
	assert(scene.room_code == "ABCDEF" and scene.socket == original_socket)
	assert(scene.controller_state("a")["hostCommand"] == "start_party")
	assert(scene.controller_state("a")["hostButtonEnabled"])
	print("PASS: real lobby/game scene swaps, persistent session, phone commands, physics collection, reconnect, pause, ties, replay.")
	quit()
