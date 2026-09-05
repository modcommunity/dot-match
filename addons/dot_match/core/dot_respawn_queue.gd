class_name DotRespawnQueue
extends RefCounted

## Who is waiting to come back, and when.
##
## Counted in ticks against a target, never as a countdown decremented per call. A
## countdown is wrong twice over: it drifts against a variable frame time, and a
## replayed tick advances it a second time, which respawns someone early.

## key -> tick they may respawn on.
var _waiting: Dictionary = {}

var _tick_rate: int = 60


func _init(tick_rate: int = 60) -> void:
	_tick_rate = maxi(1, tick_rate)


func set_tick_rate(rate: int) -> void:
	_tick_rate = maxi(1, rate)


## Puts a player in the queue. Re-queuing an existing entry replaces it.
func enqueue(key: String, tick: int, delay_sec: float) -> int:
	var target := tick + maxi(0, int(round(delay_sec * float(_tick_rate))))
	_waiting[key] = target
	return target


## Puts a player in with an explicit tick. For a round start, where everyone comes
## back at once regardless of when they died.
func enqueue_at(key: String, target_tick: int) -> void:
	_waiting[key] = target_tick


func cancel(key: String) -> void:
	_waiting.erase(key)


func is_waiting(key: String) -> bool:
	return _waiting.has(key)


func ready_tick(key: String) -> int:
	return int(_waiting.get(key, -1))


## Seconds until a player comes back. Negative when they are not waiting.
func seconds_remaining(key: String, tick: int) -> float:
	if not _waiting.has(key):
		return -1.0
	return float(int(_waiting[key]) - tick) / float(_tick_rate)


## Everyone due on [param tick], removed from the queue.
##
## Sorted so two machines produce the same order. Dictionary iteration order is not a
## guarantee, and the order players respawn in decides which of them gets the good
## spawn point when several come back on the same tick.
func take_ready(tick: int) -> Array[String]:
	var out: Array[String] = []

	for key in _waiting.keys():
		if tick >= int(_waiting[key]):
			out.append(key)

	out.sort()

	for key in out:
		_waiting.erase(key)

	return out


func waiting_count() -> int:
	return _waiting.size()


func waiting_keys() -> Array[String]:
	var out: Array[String] = []
	for key in _waiting.keys():
		out.append(str(key))
	out.sort()
	return out


func clear() -> void:
	_waiting.clear()


func describe() -> Dictionary:
	return {
		"waiting": _waiting.size(),
		"keys": waiting_keys(),
	}
