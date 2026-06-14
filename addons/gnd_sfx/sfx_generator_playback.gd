@tool
extends Resource
class_name SfxGeneratorPlayback

## Base class for procedural (synthesized, not sample-based) clips. Assign
## a subclass to SfxClip.generator_playback and give the clip an
## AudioStreamGenerator as its stream; SfxPlaybackRuntime then drives your
## subclass through this lifecycle instead of just playing back audio
## data. See demo/demo_tone_generator_playback.gd (a simple sine tone) and
## demo/sounds/sfx_wind_generator_stream.gd (a more involved filtered-noise
## wind synth) for worked examples.
##
## Lifecycle: create_state() once when the voice starts, update() every
## frame for as long as the voice is active, cleanup() once when it stops.
## All three run on the same object instance across a voice's lifetime, so
## per-voice state belongs in the `state` value you return from
## create_state() - not in @export vars on the resource itself, since one
## SfxGeneratorPlayback resource can be shared by multiple simultaneous
## voices (e.g. polyphonic events, or the same clip used by two events at
## once).


## Called once when a voice using this generator starts playing. Return
## whatever per-voice state update()/cleanup() will need (e.g. filter
## history, a phase accumulator) - it's passed back to you unchanged as
## `state` in both. `playback` is the AudioStreamGeneratorPlayback to push
## frames into; `clip` is the SfxClip this voice was started from.
func create_state(playback: AudioStreamGeneratorPlayback, clip):
    return null


## Called every frame while the voice is active. Push audio frames into
## `context.stream_playback` (via AudioStreamGeneratorPlayback.push_frame)
## to fill however many frames it has room for - check
## get_frames_available() first. `context` also carries: delta,
## playback_position, event_name, clip, player, automation_name,
## automation_value, event_time and parameters (see
## _build_generator_context in sfx_playback_runtime.gd for the exact
## contents).
func update(state, context: Dictionary) -> void:
    pass


## Called once when the voice stops, with the same `state` value
## create_state() returned. Release any resources you allocated there;
## most generators don't need to do anything here.
func cleanup(state) -> void:
    pass
