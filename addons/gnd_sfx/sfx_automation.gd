@tool
extends Resource
class_name SfxAutomation

enum CrossfadeMode {
    LINEAR,
    EQUAL_POWER
}

@export var crossfade_mode: CrossfadeMode = CrossfadeMode.LINEAR:
    set(value):
        crossfade_mode = value
        emit_changed()

@export var parameter_name : StringName = "":
    set(value):
        parameter_name = value
        emit_changed()

@export var clips : Array[SfxClip]:
    set(value):
        clips = value
        emit_changed()

@export var min_domain = 0.0:
    set(value):
        min_domain = value
        emit_changed()

@export var max_domain = 1.0:
    set(value):
        max_domain = value
        emit_changed()

@export var pitch_curve: Curve:
    set(value):
        pitch_curve = value
        emit_changed()

@export var phase_locked := false:
    set(value):
        phase_locked = value
        emit_changed()

@export var phase_period := 0.0:
    set(value):
        phase_period = value
        emit_changed()
