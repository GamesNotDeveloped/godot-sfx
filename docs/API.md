# gnd_sfx API

The addon is a GDExtension (`addons/gnd_sfx/libgndsfx.gdextension`, sources in `src/`) plus the
editor tools in GDScript. Every class below also has its reference in the editor (F1 / Help).

## Classes

| Class | What it is |
|---|---|
| `SfxPlayer`, `SfxPlayer3D` | Nodes that play the events of a bank (`SfxPlayer3D` at its place in the world) |
| `SfxBank` | Events plus the parameters a player of the bank has |
| `SfxEvent` | One playable sound: timeline clips, automations, modulations, triggers |
| `SfxClip` | One audio (or synthesized) segment of an event or automation |
| `SfxTrack` | Mixer channel: mute/solo/volume and an envelope |
| `SfxAutomation` | Clips that follow a parameter instead of the clock (crossfaded) |
| `SfxParameterModulation` | Parameter → gain / pitch / unit size of an event's voices |
| `SfxSpatialConfig` | Per-event overrides of the 3D voices |
| `SfxParameter` | A parameter of the player, declared by the bank |
| `SfxDerivedParameter` | A parameter computed from others (Expression + smoothing/derivative) |
| `SfxParameterTrigger` | Starts/stops its event from a parameter (gate, cross, step, every) |
| `SfxGeneratorPlayback` | Base of a synthesized clip (`AudioStreamGenerator`) |
| `GndSfxServer` | Ticks every player on worker threads; made by the first player that needs it |
| `SfxPlaybackRuntime` | The engine of one player, exposed for tests and tools |
| `SfxStreamLoopSupport` | Loop helpers for WAV / Ogg Vorbis / MP3 |

## Playing an event

```gdscript
@onready var player: SfxPlayer3D = $Engine

player.play(&"horn")                    # an instance of the event "horn"
player.play(&"horn", 1.5)               # ... 1.5 s into its timeline
player.play(&"horn", {&"pitch": 2.0})   # ... with instance parameters
player.stop(&"horn")                    # release: ADSR, fade-outs, then its sustain clips
player.stop(&"horn", true)              # cut at once
player.stop()                           # every event
player.is_playing(&"horn")
player.finished.connect(_on_silent)     # the last voice and instance are gone
```

An instance runs its event's timeline. A `TRIGGER_TIMELINE` clip starts when the clock reaches its
`offset`; a `TRIGGER_SUSTAIN` clip starts when the instance is released (a tail, a closing bookend).
With `polyphony_enabled` off a new `play()` replaces the playing instance.

## Parameters

A value can come from three places, looked up in this order:

1. **the instance**: `play(name, {...})`, `modulate(name, {...})`, `set_parameters({name: {...}})`;
2. **the player**: `set_parameter(name, value)`, read by every event of the bank;
3. **the default**: `SfxParameter.default_value`, else `SfxAutomation.min_domain` /
   `SfxParameterModulation.default_value`.

Player parameters are declared by the bank (`SfxBank.parameters`). The player shows them as
properties `parameters/<name>`, so the inspector, an `AnimationPlayer` or a `Tween` can drive them:

```gdscript
player.set_parameter(&"speed", velocity.length())   # from code, every frame is fine
player.set("parameters/speed", 12.0)                # the same, as a property
player.get_parameter(&"speed")
```

From C++ (a GDExtension of the game) every value is a `call()` through a Variant, so a game feeding
many values every step sets them all at once, in the bank's declaration order:

```cpp
PackedFloat64Array values;            // SfxBank.parameters order: speed, rpm, pressure, ...
values.push_back(speed); values.push_back(rpm); values.push_back(pressure);
player->call("set_parameter_values", values);
```

`set_parameter` only stores the value. The tick that follows, on a worker thread, works out what
reads it: a derived parameter is evaluated again only when one of its inputs changed (or while it
still moves), an automation and a trigger only when their own parameter changed. An undeclared name
is refused with a warning.

### Derived parameters

`SfxBank.derived_parameters` are computed every tick, in order, so one may read those before it.
`expression` is a Godot `Expression` of its `inputs`, plus `previous` (its own last value) and
`delta` (seconds since):

| Need | `expression` | `filter` |
|---|---|---|
| sum of several parameters | `ao + af * (power + 60 * rpm)` | `NONE` |
| function of two variables | `sqrt(fr * lerp(0.4, 1, v / (1 + vmax)))` | `NONE` |
| smoothing (lerp toward the value) | `volume` | `SMOOTH`, `time_constant` |
| rate of change (Δp/dt) | `pressure` | `DERIVATIVE` |
| slew rate, separate up/down | `previous + clamp(goal - previous, -0.2 * delta, 0.4 * delta)` | `NONE` |
| decay only under a condition | `previous - previous * 2.5 * delta if v < 2.5 else squeal` | `NONE` |

There is no integral: feed a counter the game integrates (distance run, momentum) as a raw parameter.
A derived parameter that keeps moving (smoothing, a slew) is ticked every frame until it settles.

### Triggers

`SfxEvent.triggers` start and stop their event from a player parameter, raw or derived. They are
evaluated after the value changes, not every frame:

| `mode` | Fires | Uses |
|---|---|---|
| `GATE` | plays while `value >= on_threshold`, releases below `off_threshold` (hysteresis) | squeal 0.075/0.05, valve 0.025/0.015 |
| `CROSS` | a one-shot when the value crosses `on_threshold` (`direction`) | |
| `STEP` | a one-shot when `floor(value / step)` changes (`direction`) | cylinder click at `int(15 * p / pmax)` |
| `EVERY` | a one-shot every `step` units the value travels | wheel clatter every rail length of a distance counter |

`min_interval` drops a fire too soon after the last, `exclusive` drops one while the event still
plays, `resume_offset` is where a gate starts its event again after a cut (past its opening). To
start an event "from its resulting gain", derive the gain and gate on it.

### Chunks chosen at start

`SfxAutomation.latch_on_start` picks the automation's clip by the value when the instance starts and
never again. An event made of such an automation over one-shot clips is a chunked one-shot (clatter
by speed, click by step) that ends with its chunk. Fire it with a `STEP` / `CROSS` / `EVERY` trigger.

## Cutting a player

`cut = true` silences a player at once: its sounds stop, `play()` is ignored, its triggers start
nothing. With `cut = false` it comes back: open gates start their events again at
`resume_offset`, and step/cross/every edges restart from the values found then. `SfxPlayer3D` is
also cut beyond `gnd_sfx/hard_cut_distance` of the camera (unless `hard_cut_enabled` is off). The
effective cut is either of the two.

## Threading

```
frame N   _process ... every node ... GndSfxServerPoster (last)  -> post the tick
          [render, physics of N+1 | worker threads tick the players]
frame N+1 GndSfxServer._process (first): wait, copy what changed into the audio nodes
```

- `gnd_sfx/worker_threads` (default 2) is how many threads tick at once, each player on one. With
  `0` the tick runs on the main thread.
- The main thread only copies changed values into the nodes (`volume_db`, `pitch_scale`, `play()`,
  …). It does not read the nodes back: a voice's position follows from the clock and its pitch, and
  the node's `finished` reports the end.
- A player is ticked only while it has work: a held loop, an automation at rest or a sound between
  its fades is not visited until `set_parameter` / `modulate` / `stop` / `finished` or a scheduled
  moment (the next clip's offset, the start of a fade-out) wakes it.
- The player API waits for a running tick first, so calling it from `_physics_process` or a signal is
  safe. The API is main-thread only.
- `SfxGeneratorPlayback._update` runs on a worker thread.
- The runtime runs on audio time: `Engine.time_scale` does not slow the sounds, while
  `AudioServer.playback_speed_scale` does. A paused player (`can_process()` false) stops its clock.

## Project settings

| Setting | Default | |
|---|---|---|
| `gnd_sfx/worker_threads` | 2 | threads of the tick; 0 = main thread |
| `gnd_sfx/hard_cut_distance` | 1000 | `SfxPlayer3D` falls silent beyond this distance of the camera |
| `gnd_sfx/hard_cut_check_interval` | 5 | seconds between distance checks (of the playing players) |

## Synthesized clips

Give the clip an `AudioStreamGenerator` stream and an `SfxGeneratorPlayback` subclass:

```gdscript
extends SfxGeneratorPlayback

func _create_state(playback: AudioStreamGeneratorPlayback, clip: SfxClip):
    return {"phase": 0.0}

func _update(state, context: Dictionary) -> void:
    var playback: AudioStreamGeneratorPlayback = context.stream_playback
    ...  # push_buffer() what get_frames_available() allows

func _cleanup(state) -> void:
    pass
```

`context` holds `delta`, `playback_position`, `event_name`, `clip`, `stream_playback`, `event_time`,
`parameters`, `automation_name` and `automation_value`.

## Building

```sh
git submodule update --init --recursive
make compile-debug                          # the editor's library, single precision
make compile-debug PRECISION=double         # for a double precision Godot (godot-double)
make compile-release-linux [PRECISION=...]  # in ci/docker/linux-sdk: glibc 2.34, checked
make compile-windows-release [PRECISION=...]  # MinGW
make compile-android-release [PRECISION=...]  # arm64, ANDROID_NDK_ROOT=<ndk> (API 24, ANDROID_API=...)
make import test                            # the GUT tests (GODOT=godot-double for double)
make docs                                   # refresh doc_classes/ after an API change
```

`compile-debug` builds the debug library optimized with symbols (`RelWithDebInfo`), like the
engine's own template_debug: it is what the editor and a game started from it load.
`BUILD_TYPE=Debug` builds it unoptimized for stepping through it.

The libraries land in `addons/gnd_sfx/bin/<platform>/libgndsfx.<platform>.<target>[.double].<arch>`.
`libgndsfx.gdextension` picks the double ones by the `double` feature tag. The double precision API
is dumped from `godot-double` into `extension_api.double.json` (not versioned).

## Moving from the GDScript version

- Resources are native classes now. Run `tools/migrate_tres.py <dir>` over your banks and scenes:
  `script = ExtResource("…/sfx_*.gd")` becomes the native type, and `Array[ExtResource(…)]` becomes
  `Array[SfxClip]` etc.
- `SfxGeneratorPlayback` subclasses rename `create_state` / `update` / `cleanup` to `_create_state` /
  `_update` / `_cleanup`.
- There is no `GndSfxServer` autoload any more (the plugin removes the old one).
- An `SfxEvent` made in code has no `master_track` (the editor makes one for a new event): a clip
  without a track then plays at unity.
- Resource arrays (`clips`, `events`, …) must be assigned, not changed in place.

## Behaviour changes

- A looping timeline clip no longer dips at the end of every lap through its `fade_out_curve`; the
  curve fades it only when it is stopped.
- A drained loop (`SfxClip.cut` off) plays its tail at its pitch; it used to be cut short (pitch < 1)
  or held past its end (pitch > 1).
- A time-domain `pitch_curve` may raise the pitch above 1 (it was clamped to 0..1).
- The runtime runs on audio time, not on `Engine.time_scale`.
