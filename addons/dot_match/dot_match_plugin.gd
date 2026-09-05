@tool
extends EditorPlugin

## Editor entry point for dot-match. Registers inspector types only.
##
## No autoload, for the family's reason: a process may run two matches at once — which
## is what this project's own self-test does — and a singleton match makes that
## impossible. [DotMatch] registers itself in [DotRegistry] instead.

const _ICON := "res://addons/dot_match/icon_placeholder.svg"

const _TYPES := [
	[
		"DotMatch",
		"Node",
		"res://addons/dot_match/dot_match.gd",
	],
	[
		"DotScoreboard",
		"Node",
		"res://addons/dot_match/core/dot_scoreboard.gd",
	],
	[
		"DotTeamManager",
		"Node",
		"res://addons/dot_match/core/dot_team_manager.gd",
	],
	[
		"DotKillFeed",
		"Node",
		"res://addons/dot_match/core/dot_kill_feed.gd",
	],
	[
		"DotSpawnPoint",
		"Node3D",
		"res://addons/dot_match/spawn/dot_spawn_point.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
