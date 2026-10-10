# Displays the lobby. The persistent PartySession owns networking and scene swaps.
extends Control

@export var player_slot_scene: PackedScene = preload("res://party motion/scenes/lobby_player.tscn")

@onready var session: Node = get_node("/root/PartySession")
@onready var slots: GridContainer = $Lobby/PlayerScroll/Slots


func _ready() -> void:
	session.transitioning = false
	session.changed.connect(refresh_players)
	refresh_players()
	session.sync_controllers()


func _on_primary_button() -> void:
	session.primary_action()


## Fill saved slots in join order, keeping offline players in their original place.
func refresh_players() -> void:
	var ids: Array = session.players.keys()
	while slots.get_child_count() < ids.size():
		slots.add_child(player_slot_scene.instantiate())
	for index in range(ids.size()):
		var player: Dictionary = session.players[ids[index]]
		var slot := slots.get_child(index)
		var online: bool = player["connected"]
		slot.get_node("Swatch").color = player["color"] if online else Color("34473f")
		slot.get_node("Name").text = player["name"]
		slot.get_node("Name").add_theme_color_override("font_color", Color.WHITE if online else Color("99a89e"))
		slot.get_node("Detail").text = "READY" if online else "OFFLINE"
		slot.get_node("Detail").add_theme_color_override("font_color", Color("40e0c8") if online else Color("99a89e"))
	$Lobby/PlayerCount.text = "%d PLAYERS IN" % session.online_count()
	$JoinPanel/JoinURL.text = session.server_base.trim_prefix("https://").trim_prefix("http://")
	$JoinPanel/CodeStrip/RoomCode.text = session.room_code if not session.room_code.is_empty() else "------"
	$JoinPanel/QRStamp/QRCode.texture = session.qr_texture
	$JoinPanel/QRStamp/QRPlaceholder.visible = session.qr_texture == null
	$JoinPanel/QRStamp/PlaceholderPhone.visible = session.qr_texture == null
	$JoinPanel/Status.text = session.status
	var button: Button = $JoinPanel/PrimaryButton
	button.disabled = session.busy or session.transitioning
	if session.room_code.is_empty():
		button.text = "CREATE ROOM"
	elif not session.connected:
		button.text = "RECONNECT"
	else:
		button.text = "START PARTY" if session.online_count() > 0 else "ROOM OPEN"
		button.disabled = session.online_count() == 0
	$Hint.text = "Create a room, then grab your phones." if session.room_code.is_empty() else "Everyone in? Start Motion Munch on the leader's phone."
