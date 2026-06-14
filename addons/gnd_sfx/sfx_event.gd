@tool
extends Resource
class_name SfxEvent

## One playable sound in an SfxBank (e.g. "footstep", "engine_loop") -
## roughly FMOD's "event". Owns a timeline of `clips` plus any number of
## parameter-driven `automations`; SfxPlaybackRuntime.play() starts one
## EventInstance of it. `master_track` is the mixer fallback for any clip
## that doesn't have its own `track` assigned; attack/decay/sustain/
## release here gate the whole event's voices together, separate from any
## individual track's own ADSR.

@export var clips: Array[SfxClip] = []:
    set(value):
        clips = value
        emit_changed()

@export var tracks: Array[SfxTrack] = []:
    set(value):
        tracks = value
        emit_changed()

@export var master_track: SfxTrack = _make_master_track():
    set(value):
        master_track = value
        emit_changed()

@export var polyphony_enabled := true:
    set(value):
        polyphony_enabled = value
        emit_changed()

@export var adsr_enabled := false:
    set(value):
        adsr_enabled = value
        emit_changed()

@export_range(0.0, 30.0, 0.01) var attack := 0.0:
    set(value):
        attack = value
        emit_changed()

@export_range(0.0, 30.0, 0.01) var decay := 0.0:
    set(value):
        decay = value
        emit_changed()

@export_range(0.0, 1.0, 0.01) var sustain := 1.0:
    set(value):
        sustain = value
        emit_changed()

@export_range(0.0, 30.0, 0.01) var release := 0.0:
    set(value):
        release = value
        emit_changed()

@export var name: StringName = "":
    set(value):
        name = value
        emit_changed()

@export var automations: Array[SfxAutomation] = []:
    set(value):
        automations = value
        emit_changed()


static func _make_master_track() -> SfxTrack:
    var track := SfxTrack.new()
    track.track_name = &"Master"
    return track
