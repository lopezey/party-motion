extends Node
## Edit each round's text in Main > GameDefinitions in the Inspector.

@export var game_id := "tilt"
@export var title := "Tilt Treasure"
@export var verb := "TILT"
@export_multiline var instructions := "Tilt your phone to steer. Collect as many glowing stars as you can."
@export var goal := "Most stars wins"


func as_dictionary() -> Dictionary:
	return {"id": game_id, "title": title, "verb": verb, "instructions": instructions, "goal": goal}
