@tool
extends Resource
class_name SfxParameterModulation

## Maps one event parameter to a voice property. Multiple mappings may use
## the same parameter and their results are multiplied with the clip state.

enum Target {
    GAIN,
    PITCH,
    UNIT_SIZE,
}

@export var parameter_name: StringName = &"":
    set(value):
        parameter_name = value
        emit_changed()

@export var target: Target = Target.GAIN:
    set(value):
        target = value
        emit_changed()

@export var min_domain: float = 0.0:
    set(value):
        min_domain = value
        emit_changed()

@export var max_domain: float = 1.0:
    set(value):
        max_domain = value
        emit_changed()

@export var default_value: float = 0.0:
    set(value):
        default_value = value
        emit_changed()

@export var curve: Curve:
    set(value):
        curve = value
        emit_changed()
