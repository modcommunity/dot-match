# History

Bugs worth recognising if they come back. The lessons that still apply are in [design.md](design.md).

## `pause_when_empty` was read off the wrong object

`pause_when_empty` was declared on `DotMatchRules` and read off `DotMatchConfig`. It parsed cleanly, and the match sat in `COUNTDOWN` forever; nothing but running a round would have found it, which the self-test now does. The fix put the threshold and the decision on the same object (the rules), and removed `DotMatchConfig.run_when_empty`, which overlapped it and which nothing read.

## A game cleared `spawn_points()` by reference

game-g2gfast cleared the array `spawn_points()` returns on every map load. It worked only because the return was not a copy. `remove_spawn_point` and `clear_spawn_points` were added so nobody has to mutate the returned array, and g2gfast now calls `clear_spawn_points()`.

## A freed spawn point crashed the engine

game-hungario's solo mode change (2026-10-12) builds a fresh client beside the old one and frees the old one. The new world's match had no `spawns_ref`, so `refresh_spawns` collected every point under the current scene, the old world's included; when the old world went, the next round's `point.reset()` in `_begin_round` crashed Godot with signal 11, not a script error. It only showed when the client was built late in a suite, with other worlds still in the tree. The match now forgets freed points before walking the list, and `match_selftest` frees a collected point and runs a round over it (it crashes without the fix).
