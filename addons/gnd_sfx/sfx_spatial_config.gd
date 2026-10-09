@tool
extends Resource
class_name SfxSpatialConfig

## Per-event overrides applied to AudioStreamPlayer3D voices. A negative
## max_distance leaves the owning SfxPlayer3D value unchanged.

@export var position: Vector3 = Vector3.ZERO:
    set(value):
        position = value
        emit_changed()

@export var attenuation_model: AudioStreamPlayer3D.AttenuationModel = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE:
    set(value):
        attenuation_model = value
        emit_changed()

@export var unit_size: float = 10.0:
    set(value):
        unit_size = value
        emit_changed()

@export var max_distance: float = -1.0:
    set(value):
        max_distance = value
        emit_changed()

@export_range(0.0, 3.0) var panning_strength: float = 1.0:
    set(value):
        panning_strength = value
        emit_changed()
