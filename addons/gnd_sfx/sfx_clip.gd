@tool
extends Resource
class_name SfxClip

enum TriggerMode {
    TRIGGER_TIMELINE,
    TRIGGER_SUSTAIN
}

@export var stream : AudioStream
@export var generator_playback: SfxGeneratorPlayback
@export var offset := 0.0
@export var length := 0.0
@export var stream_offset := 0.0
@export var phase_offset := 0.0
@export var fade_in_curve: Curve
@export var fade_out_curve: Curve
@export var pitch_curve: Curve
@export var trigger_mode: TriggerMode = TriggerMode.TRIGGER_TIMELINE
@export var cut := true
@export var track: SfxTrack
