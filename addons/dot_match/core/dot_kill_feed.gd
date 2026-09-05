@tool
class_name DotKillFeed
extends Node

## The last few kills, bounded.
##
## A ring rather than a list: a match runs for an hour and a kill feed nobody trims is
## a leak proportional to how long the server has been up. [member capacity] entries is
## more than any HUD shows and enough for a "what just happened" panel.

const CHANNEL := "match.feed"

signal entry_added(entry: Entry)

@export_range(4, 256, 4) var capacity: int = 32


## One line. Kept as data rather than as a formatted string so a client can render it
## in its own language, with its own icons, and with team colours the server does not
## know about.
class Entry extends RefCounted:
	var tick: int = 0

	## Empty for a world death.
	var killer_key: String = ""
	var killer_name: String = ""
	var killer_team: int = 0

	var victim_key: String = ""
	var victim_name: String = ""
	var victim_team: int = 0

	## What did it. A weapon id, or a damage type id for a fall or a trap.
	var cause: StringName = &""

	var headshot: bool = false

	## Killer and victim are the same, or there was no killer.
	var suicide: bool = false

	## Killer and victim were on the same side. A client usually renders this
	## differently, and it is the one case a scoreboard treats specially.
	var team_kill: bool = false

	## Kills the killer has without dying, at this moment.
	var streak: int = 0

	func _to_string() -> String:
		if suicide:
			return "%s died (%s)" % [victim_name, cause]
		return "%s [%s%s] %s" % [
			killer_name, cause, " HS" if headshot else "", victim_name
		]


var _entries: Array[Entry] = []


func add(entry: Entry) -> void:
	if entry == null:
		return

	_entries.append(entry)

	while _entries.size() > capacity:
		_entries.remove_at(0)

	entry_added.emit(entry)


## Builds and adds an entry from a kill.
##
## [param killer] may be null — a world death, a fall, a player who has already
## disconnected. Handling that here rather than at the call site is what stops the
## "killed by someone who has left" case being a null dereference.
func add_kill(
	killer: DotPlayerScore,
	victim: DotPlayerScore,
	cause: StringName,
	tick: int,
	headshot: bool = false
) -> Entry:
	var entry := Entry.new()
	entry.tick = tick
	entry.cause = cause
	entry.headshot = headshot

	if victim != null:
		entry.victim_key = victim.key
		entry.victim_name = victim.display_name
		entry.victim_team = victim.team

	if killer == null or (victim != null and killer.key == victim.key):
		entry.suicide = true
	else:
		entry.killer_key = killer.key
		entry.killer_name = killer.display_name
		entry.killer_team = killer.team
		entry.streak = killer.streak
		entry.team_kill = (
			killer.team > 0 and victim != null and killer.team == victim.team
		)

	add(entry)
	return entry


func entries() -> Array[Entry]:
	return _entries


## The most recent [param count] entries, newest last.
func recent(count: int) -> Array[Entry]:
	var start := maxi(0, _entries.size() - count)
	return _entries.slice(start)


## Entries added since [param tick]. What a reconnecting client is caught up with.
func since(tick: int) -> Array[Entry]:
	var out: Array[Entry] = []
	for entry in _entries:
		if entry.tick > tick:
			out.append(entry)
	return out


func clear() -> void:
	_entries.clear()


func describe() -> Dictionary:
	var lines := []
	for entry in recent(8):
		lines.append(str(entry))

	return {
		"entries": _entries.size(),
		"capacity": capacity,
		"recent": lines,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for entry in recent(8):
		out.append("  %s" % entry)
	return out
