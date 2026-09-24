@tool
extends Node
class_name SfxPlayer

signal finished

var _core := SfxPlayerCore.new(
    self,
    func(): return AudioStreamPlayer.new(),
    func(player):
        player.max_polyphony = max_polyphony
        player.bus = bus
)

@export var bank: SfxBank:
    set(value):
        bank = value
        _core.events_changed()

@export var max_tracks: int = 4:
    set(value):
        max_tracks = value
        _core.sync_values(true)

@export var max_polyphony: int = 1:
    set(value):
        max_polyphony = value
        _core.apply_player_config()

## Audio bus of every voice this player creates.
@export var bus: StringName = &"Master":
    set(value):
        bus = value
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
    set_process(Engine.is_editor_hint())
    _core.activate()


func _exit_tree() -> void:
    _core.deactivate()


## Editor preview only - in game GndSfxServer ticks the core off the main thread
func _process(delta: float) -> void:
    _core.tick_preview(delta)


func _validate_property(property: Dictionary) -> void:
    _core.validate_property(property)


func sync_values(rebuild := false) -> void:
    _core.sync_values(rebuild)


## `start_fraction` shifts every voice of this event that far into its own clip - what holds one
## recording played by many emitters out of phase with itself (see SfxPlaybackRuntime).
func play(
        event_name: StringName, offset_or_parameters = null, parameters: Dictionary = {},
        start_fraction := 0.0) -> void:
    _core.play(event_name, offset_or_parameters, parameters, start_fraction)


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
