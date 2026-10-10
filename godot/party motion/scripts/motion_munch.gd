# Runs a single tilt-controlled snack hunt and reports its state to the lobby.
extends Control

signal state_changed

enum Phase { TUTORIAL, COUNTDOWN, PLAYING, RESULTS }

@export_range(5, 120) var round_seconds := 30.0
@export var move_speed := 340.0
@export var avatar_scene: PackedScene = preload("res://party motion/scenes/munch_avatar.tscn")
@export var snack_scene: PackedScene = preload("res://party motion/scenes/munch_snack.tscn")

var phase := Phase.TUTORIAL
var active := false
var participants: Dictionary = {}
var time_left := 0.0
var countdown := 3.0
var avatars: Dictionary = {}
var rng := RandomNumberGenerator.new()

@onready var arena: Control = $Arena
@onready var bodies: Node2D = $Arena/Players
@onready var snacks: Node2D = $Arena/Snacks
@onready var session: Node = get_node("/root/PartySession")


func _ready() -> void:
	rng.randomize()
	session.active_game = self
	session.transitioning = false
	session.changed.connect(refresh_controls)
	state_changed.connect(_on_state_changed)
	# F6 can preview this scene alone. Normal play uses the room's live roster.
	begin(session.players)


## Lock in this round's roster; late joiners can play in the next round.
func begin(roster: Dictionary) -> void:
	clear_arena()
	participants.clear()
	for id in roster:
		if roster[id]["connected"]:
			participants[id] = {
				"name": roster[id]["name"], "color": roster[id]["color"],
				"connected": true, "score": 0, "tilt": Vector2.ZERO, "age": 1.0
			}
	active = true
	visible = true
	phase = Phase.TUTORIAL
	time_left = round_seconds
	refresh_display()
	state_changed.emit()


## Reconcile reconnects without resetting scores or admitting mid-round players.
func sync_roster(roster: Dictionary) -> void:
	for id in participants:
		participants[id]["connected"] = roster.has(id) and roster[id]["connected"]
		if not participants[id]["connected"]:
			participants[id]["tilt"] = Vector2.ZERO
		if avatars.has(id):
			avatars[id].visible = participants[id]["connected"]
	refresh_display()


func online_count() -> int:
	var count := 0
	for player in participants.values():
		count += int(player["connected"])
	return count


## Use the relay's existing commands so the current phone website works unchanged.
func handle_command(command: String, roster: Dictionary) -> void:
	if command == "start_round" and phase == Phase.TUTORIAL and online_count() > 0:
		prepare_round()
	elif command == "play_again" and phase == Phase.RESULTS:
		begin(roster)
	elif command == "show_final" and phase != Phase.RESULTS and online_count() == 0:
		finish_round()


## Expand to full-screen play before placing players and starting the countdown.
func prepare_round() -> void:
	if phase != Phase.TUTORIAL:
		return
	clear_arena()
	phase = Phase.COUNTDOWN
	refresh_display()
	var index := 0
	var columns := mini(4, participants.size())
	var rows := ceili(float(participants.size()) / maxi(columns, 1))
	for id in participants:
		var avatar := avatar_scene.instantiate() as CharacterBody2D
		avatar.set_meta("player_id", id)
		bodies.add_child(avatar)
		avatar.position = Vector2(
			arena.size.x * (index % columns + 1) / (columns + 1),
			arena.size.y * (index / columns + 1) / (rows + 1)
		)
		avatar.get_node("Face").color = participants[id]["color"]
		avatar.get_node("Face").face_variant = index % 8
		avatar.get_node("Name").text = participants[id]["name"]
		avatar.visible = participants[id]["connected"]
		avatars[id] = avatar
		participants[id]["tilt"] = Vector2.ZERO
		participants[id]["age"] = 1.0
		index += 1
	for snack_index in range(6):
		spawn_snack()
	countdown = 3.0
	phase = Phase.COUNTDOWN
	refresh_display()
	state_changed.emit()


## Accept fresh tilt only from this round's connected participants.
func apply_motion(id: String, axes: Array) -> void:
	if not participants.has(id) or not participants[id]["connected"] or axes.size() < 2:
		return
	if not (axes[0] is float or axes[0] is int) or not (axes[1] is float or axes[1] is int):
		return
	var tilt := Vector2(float(axes[0]), float(axes[1]))
	if not is_finite(tilt.x) or not is_finite(tilt.y):
		return
	participants[id]["tilt"] = tilt.limit_length(1.0)
	participants[id]["age"] = 0.0


## Godot's physics step moves avatars and detects snack overlaps.
func _physics_process(delta: float) -> void:
	if not active or phase == Phase.TUTORIAL or phase == Phase.RESULTS:
		return
	for player in participants.values():
		player["age"] += delta
	# Pause the clock if the relay drops or all round participants disconnect.
	if online_count() == 0:
		$Timer.text = "PAUSED"
		$Arena/Countdown.text = "Waiting for players to reconnect"
		$Arena/Countdown.show()
		return
	if phase == Phase.COUNTDOWN:
		countdown = maxf(0.0, countdown - delta)
		$Arena/Countdown.text = str(ceili(countdown))
		if countdown <= 0.0:
			phase = Phase.PLAYING
			$Arena/Countdown.hide()
			state_changed.emit()
		return
	$Arena/Countdown.hide()
	time_left = maxf(0.0, time_left - delta)
	$Timer.text = "%02d SEC" % ceili(time_left)
	if time_left <= 0.0:
		finish_round()
		return
	for id in avatars:
		var player: Dictionary = participants[id]
		var avatar: CharacterBody2D = avatars[id]
		# Stale sensor input must stop movement rather than coast indefinitely.
		var tilt: Vector2 = player["tilt"] if player["connected"] and player["age"] < 0.3 else Vector2.ZERO
		avatar.velocity = tilt * move_speed
		avatar.move_and_slide()
		# Leave the compact top HUD clear while using the rest of the full screen.
		avatar.position = avatar.position.clamp(Vector2(30, 134), arena.size - Vector2(30, 30))


func spawn_snack() -> void:
	var snack := snack_scene.instantiate() as Area2D
	snacks.add_child(snack)
	# Prefer open space so fresh snacks do not appear inside a player or each other.
	for attempt in range(40):
		snack.position = Vector2(rng.randf_range(40, arena.size.x - 40), rng.randf_range(128, arena.size.y - 40))
		var clear := true
		for avatar in avatars.values():
			if avatar.position.distance_to(snack.position) < 65:
				clear = false
		for other in snacks.get_children():
			if other != snack and other.position.distance_to(snack.position) < 40:
				clear = false
		if clear:
			break
	snack.body_entered.connect(_on_snack_touched.bind(snack))


## Reserve each snack once; defer replacement until physics finishes its callback.
func _on_snack_touched(body: Node2D, snack: Area2D) -> void:
	var id: String = body.get_meta("player_id", "")
	if phase != Phase.PLAYING or snack.get_meta("consumed", false) or not participants.has(id):
		return
	if not participants[id]["connected"]:
		return
	snack.set_meta("consumed", true)
	snack.hide()
	collect_snack.call_deferred(id, snack)


func collect_snack(id: String, snack: Area2D) -> void:
	if is_instance_valid(snack):
		snack.queue_free()
	if phase != Phase.PLAYING:
		return
	participants[id]["score"] += 1
	spawn_snack()
	refresh_display()
	state_changed.emit()


## Rank everyone who entered the round, awarding shared wins for equal scores.
func finish_round() -> void:
	phase = Phase.RESULTS
	var ids := participants.keys()
	ids.sort_custom(func(a, b): return participants[a]["score"] > participants[b]["score"])
	var winners: Array[String] = []
	var best := int(participants[ids[0]]["score"]) if not ids.is_empty() else 0
	var lines := ""
	for id in ids:
		var player: Dictionary = participants[id]
		if player["score"] == best:
			winners.append(player["name"])
		lines += "%s    %d %s\n" % [player["name"], player["score"], "snack" if player["score"] == 1 else "snacks"]
	$Arena/Results/Heading.text = "SHARED WIN!" if winners.size() > 1 else "NICE MUNCHING!"
	$Arena/Results/Winner.text = ", ".join(winners) if winners.size() <= 3 else "%d players tied with %d snacks" % [winners.size(), best]
	$Arena/Results/ScoreScroll/Scores.text = lines
	refresh_display()
	state_changed.emit()


func clear_arena() -> void:
	for container in [bodies, snacks]:
		for child in container.get_children():
			container.remove_child(child)
			child.queue_free()
	avatars.clear()


func refresh_display() -> void:
	# The instructions/results use a reading layout. Countdown and play use the
	# entire viewport, with only scores, time, and the room code overlaid.
	var playing := phase == Phase.COUNTDOWN or phase == Phase.PLAYING
	arena.offset_left = 0.0 if playing else 48.0
	arena.offset_top = 0.0 if playing else 188.0
	arena.offset_right = 0.0 if playing else -48.0
	arena.offset_bottom = 0.0 if playing else -66.0
	$Arena/Field.visible = playing
	$Tag.visible = not playing
	$Tag.text = "HOW TO PLAY" if phase == Phase.TUTORIAL else "ROUND RESULTS"
	$Title.visible = not playing
	$Timer.visible = playing
	$Timer.offset_top = 28.0
	$Timer.offset_bottom = 76.0
	$Scoreboard.visible = playing
	$Scoreboard.offset_left = 32.0
	$Scoreboard.offset_top = 20.0
	$Scoreboard.offset_right = -480.0
	$Scoreboard.offset_bottom = 90.0
	$Scoreboard.add_theme_font_size_override("font_size", 14)
	$Arena/Tutorial/Instructions.text = "Tilt your phone to move.\nCollect lime snacks. Each one is worth 1 point.\nYou have %d seconds. Most points wins!\nHold your phone flat and tap Calibrate before starting." % int(round_seconds)
	$Arena/Tutorial.visible = phase == Phase.TUTORIAL
	$Arena/Countdown.visible = phase == Phase.COUNTDOWN
	$Arena/Results.visible = phase == Phase.RESULTS
	bodies.visible = phase == Phase.COUNTDOWN or phase == Phase.PLAYING
	snacks.visible = bodies.visible
	$Timer.text = "%02d SEC" % ceili(time_left)
	var scores: Array[String] = []
	for player in participants.values():
		scores.append("%s: %d" % [player["name"], player["score"]])
	$Scoreboard.text = "   /   ".join(scores)
	refresh_controls()


func _on_state_changed() -> void:
	session.changed.emit()
	session.sync_controllers()


## Keep the room code visible; show compact host controls only when needed.
func refresh_controls() -> void:
	var state := controller_state("")
	var button: Button = $HostControls/PrimaryButton
	button.text = state["hostButtonLabel"] if session.connected else "RECONNECT"
	button.disabled = session.busy or (session.connected and not state["hostButtonEnabled"])
	$RoomCode.text = session.room_code if not session.room_code.is_empty() else "------"
	$HostControls/BackToLobby.visible = phase == Phase.TUTORIAL or phase == Phase.RESULTS
	button.visible = not session.connected or not state["hostCommand"].is_empty()
	$HostControls.visible = button.visible or $HostControls/BackToLobby.visible
	$Hint.visible = phase == Phase.TUTORIAL or phase == Phase.RESULTS
	$Hint.offset_right = -440.0 if $HostControls.visible else -48.0
	$Hint.text = state["instructions"] if session.connected else session.status


func _on_primary_button() -> void:
	session.primary_action()


func _on_back_to_lobby() -> void:
	if phase == Phase.TUTORIAL or phase == Phase.RESULTS:
		session.return_to_lobby()


func _exit_tree() -> void:
	if session.active_game == self:
		session.active_game = null


## Describe the current step for both the host button and each phone.
func controller_state(id: String) -> Dictionary:
	var spectator := not id.is_empty() and not participants.has(id)
	var command := ""
	var button := "ROUND IN PROGRESS"
	var instruction := "Tilt to steer. Munch the lime snacks. Most snacks wins!"
	if phase == Phase.TUTORIAL:
		command = "start_round"
		button = "START ROUND"
		instruction = "Hold your phone flat and calibrate. Tilt to steer toward the lime snacks."
	elif phase == Phase.RESULTS:
		command = "play_again"
		button = "PLAY AGAIN"
		instruction = "Check the shared screen for scores. Ready for another snack hunt?"
	if phase != Phase.RESULTS and online_count() == 0:
		command = "show_final"
		button = "END ROUND"
		instruction = "Waiting for players to reconnect. The leader can end this round."
	if spectator:
		instruction = "Watch this round. You can join the next one!"
	return {
		"game": "tilt" if phase == Phase.PLAYING else "results" if phase == Phase.RESULTS else "lobby",
		"roundLabel": "MOTION MUNCH", "title": "Motion Munch",
		"instructions": instruction,
		"crowns": 0, "points": participants[id]["score"] if participants.has(id) else 0,
		"hostCommand": command, "hostButtonLabel": button,
		"hostButtonEnabled": not command.is_empty()
	}
