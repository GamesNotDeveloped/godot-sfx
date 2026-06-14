@tool
extends Node3D
class_name SfxPlayer3D

signal finished

var _core := SfxPlayerCore.new(
    self,
    func(): return AudioStreamPlayer3D.new(),
    func(player):
        player.max_polyphony = max_polyphony
        player.max_distance = max_distance
        player.panning_strength = panning_strength
        player.attenuation_model = attenuation_model
        player.unit_size = unit_size
)

@export var bank: SfxBank:
    set(value):
        bank = value
        _core.events_changed()

@export var max_tracks: int = 10:
    set(value):
        max_tracks = value
        _core.sync_values(true)

@export var attenuation_model: AudioStreamPlayer3D.AttenuationModel = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE:
    set(value):
        attenuation_model = value
        _core.apply_player_config()

@export_range(0.01, 100.0, 0.01) var unit_size: float = 10:
    set(value):
        unit_size = value
        _core.apply_player_config()

@export var max_distance: int = 0:
    set(value):
        max_distance = value
        _core.apply_player_config()

@export var max_polyphony: int = 1:
    set(value):
        max_polyphony = value
        _core.apply_player_config()

@export_range(0.0, 3.0) var panning_strength: float = 1.0:
    set(value):
        panning_strength = value
        _core.apply_player_config()

@export_group("Playback", "playback")
@export var playback_enabled: bool = false:
    set(value):
        playback_enabled = value
        _core.sync_values()

@export var playback_effect: StringName = "":
    set(value):
        if value == SfxPlayerCore.PLAYBACK_NONE_OPTION:
            value = &""
        playback_effect = value
        _core.sanitize_playback_selection()
        _core.notify_playback_property_list_changed()
        _core.sync_values()

@export var playback_automation: StringName = "":
    set(value):
        if value == SfxPlayerCore.PLAYBACK_NONE_OPTION:
            value = &""
        playback_automation = value
        _core.sync_values()

@export var playback_automation_value: float = 0.0:
    set(value):
        playback_automation_value = value
        _core.sync_values()


func _enter_tree() -> void:
    _core.initialize()


func _ready() -> void:
    _core.activate()


func _exit_tree() -> void:
    _core.deactivate()


func _process(delta: float) -> void:
    _core.advance(delta)


func _validate_property(property: Dictionary) -> void:
    _core.validate_property(property)


func sync_values(rebuild := false) -> void:
    _core.sync_values(rebuild)


func play(event_name: StringName, offset_or_parameters = null, parameters: Dictionary = {}) -> void:
    _core.play(event_name, offset_or_parameters, parameters)


func seek(event_name: StringName, offset: float) -> void:
    _core.seek(event_name, offset)


func modulate(event_name: StringName, parameters: Dictionary) -> void:
    _core.modulate(event_name, parameters)


func set_parameters(parameters: Dictionary) -> void:
    _core.set_parameters(parameters)


func stop(event_name_or_immediate = null, immediate: bool = false) -> void:
    _core.stop(event_name_or_immediate, immediate)


func is_playing(event_name: StringName) -> bool:
    return _core.is_playing(event_name)


func get_event_visualization_state(event_name: StringName) -> Dictionary:
    return _core.get_event_visualization_state(event_name)


func play_automation(event_name: StringName, automation_name: StringName, value: float = 0.0, restart: bool = false) -> void:
    _core.play_automation(event_name, automation_name, value, restart)


func stop_automation(event_name: StringName, automation_name: StringName, immediate: bool = false) -> void:
    _core.stop_automation(event_name, automation_name, immediate)
