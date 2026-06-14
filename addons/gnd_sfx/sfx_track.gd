@tool
extends Resource
class_name SfxTrack

@export var track_name: StringName = "":
    set(value):
        track_name = value
        emit_changed()

@export var volume_db := 0.0:
    set(value):
        volume_db = value
        emit_changed()

@export var mute := false:
    set(value):
        mute = value
        emit_changed()

@export var solo := false:
    set(value):
        solo = value
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
