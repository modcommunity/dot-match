class_name DotMatchNetSync
extends RefCounted

## What a match has to tell every client, and how to get it there.
##
## [b]dot-net is not a dependency and is not imported here.[/b] Only dot-core is a hard
## dependency in this family, and a script that [i]mentions[/i] a [code]class_name[/code]
## the project does not have fails to parse — taking every script that references it
## down with it. Types are named as strings and a bridge resolves them with
## [code]DotNetVar.Type[spec.type][/code].
##
## [codeblock]
## class_name MatchNet extends DotNetBehaviour
##
## @export var match_node: DotMatch
##
## var net_state: int
## var net_round: int
## var net_ends_at: int
##
## func _register_net_vars() -> void:
##     for spec in DotMatchNetSync.specs():
##         var declaration := replicate(spec.property, DotNetVar.Type[spec.type])
##         if spec.bits > 0:
##             declaration.bits(spec.bits)
##
## func _net_simulate(tick: int, _delta: float) -> void:
##     match_node.tick(tick)
##     DotMatchNetSync.pull(match_node, self, tick)
## [/codeblock]

const STATE_BITS := 3
const ROUND_BITS := 6

## Ticks are absolute and 32 bits. A relative "seconds remaining" would be smaller and
## would have to be re-sent every tick to stay accurate; an absolute end tick is sent
## once per state change and every client counts down from the clock they already share
## with the server.
const TICK_BITS := 32


static func specs() -> Array[Dictionary]:
	return [
		{
			"property": &"net_state",
			"type": "UINT",
			"bits": STATE_BITS,
			"interpolated": false,
		},
		{
			"property": &"net_round",
			"type": "UINT",
			"bits": ROUND_BITS,
			"interpolated": false,
		},
		{
			"property": &"net_ends_at",
			"type": "UINT",
			"bits": TICK_BITS,
			"interpolated": false,
		},
		{
			"property": &"net_winner",
			"type": "UINT",
			"bits": 6,
			"interpolated": false,
		},
	]


static func properties() -> Array[StringName]:
	var out: Array[StringName] = []
	for spec in specs():
		out.append(spec["property"])
	return out


## Copies the match state onto a replicating object.
##
## The end tick is what makes a clock work without sending it every frame: the server
## says "this ends at tick 41320" once, and every client already agrees what tick it is
## because the netcode's clock is what they are all running on.
static func pull(match_node: DotMatch, target: Object, _tick: int) -> void:
	if match_node == null or target == null:
		return

	target.set(&"net_state", int(match_node.state))
	target.set(&"net_round", clampi(match_node.round_number, 0, (1 << ROUND_BITS) - 1))
	target.set(&"net_winner", clampi(match_node.last_winner(), 0, 63))

	var remaining := match_node.seconds_remaining()

	if remaining < 0.0:
		target.set(&"net_ends_at", 0)
		return

	target.set(
		&"net_ends_at",
		maxi(0, _tick + int(round(remaining * float(match_node.config.tick_rate))))
	)


## Seconds left on a client, from the replicated end tick and the client's own tick.
##
## Returns -1 when there is no clock, matching [method DotMatch.seconds_remaining], so
## a HUD has one branch rather than two.
static func seconds_remaining(
	source: Object,
	current_tick: int,
	tick_rate: int
) -> float:
	if source == null:
		return -1.0

	var ends_at := int(source.get(&"net_ends_at"))

	if ends_at <= 0:
		return -1.0

	return maxf(0.0, float(ends_at - current_tick) / float(maxi(1, tick_rate)))


static func estimated_bits() -> int:
	return STATE_BITS + ROUND_BITS + TICK_BITS + 6
