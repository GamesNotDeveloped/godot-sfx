@tool
class_name SfxPlayerCore
extends RefCounted

## Shared playback/preview logic for SfxPlayer and SfxPlayer3D. Composed
## instead of inherited because the two owners extend different Node types
## (Node vs Node3D) and GDScript has no multiple inheritance.
##
## `_owner` is deliberately untyped (Variant, not Node) so member access
## resolves dynamically at runtime. This is not a formal interface -
## GDScript has none - but the owner is expected to implement:
##   signal finished
##   var bank: SfxBank
##   var max_tracks: int
##   var playback_enabled: bool
##   var playback_effect: StringName
##   var playback_automation: StringName
##   var playback_automation_value: float
## plus the Node API (add_child, remove_child, set_process, is_inside_tree,
## notify_property_list_changed, emit_signal).

const PLAYBACK_NONE_OPTION := "<none>"

var _owner
var _make_player: Callable
var _configure_player: Callable
var _runtime := SfxPlaybackRuntime.new()
var _players: Array = []
var _watched_events: Array[SfxEvent] = []
var _watched_automations: Array[SfxAutomation] = []
var _preview_enabled: bool = false
var _preview_effect: StringName = &""
var _preview_automation: StringName = &""
var _preview_automation_value: float = 0.0


func _init(owner, make_player: Callable, configure_player: Callable) -> void:
    _owner = owner
    _make_player = make_player
    _configure_player = configure_player


func initialize() -> void:
    _reset_preview_state()
    if Engine.is_editor_hint():
        _owner.playback_enabled = false
        notify_playback_property_list_changed()


func activate() -> void:
    _ensure_runtime_connections()
    _connect_playback_resource_watchers()
    sync_values(true)
    _update_process_state()


func deactivate() -> void:
    _disconnect_playback_resource_watchers()


func advance(delta: float) -> void:
    _runtime.update(delta)


func events_changed() -> void:
    _disconnect_playback_resource_watchers()
    _connect_playback_resource_watchers()
    sanitize_playback_selection()
    notify_playback_property_list_changed()


func apply_player_config() -> void:
    for player in _players:
        _configure_player.call(player)


func sync_values(rebuild := false) -> void:
    _ensure_runtime_connections()
    if rebuild:
        _runtime.clear()
        for player in _players:
            if is_instance_valid(player):
                _owner.remove_child(player)
                player.queue_free()
        _players = []
        var index := 0
        var max_tracks: int = _owner.max_tracks
        while index < max_tracks:
            var player: Node = _make_player.call()
            _players.append(player)
            _owner.add_child(player)
            player.finished.connect(_on_player_finished.bind(player))
            index += 1
        _runtime.set_players(_players)

    apply_player_config()
    _sync_editor_playback()
    _update_process_state()


func play(event_name: StringName, offset_or_parameters = null, parameters: Dictionary = {}) -> void:
    var bank: SfxBank = _owner.bank
    if not bank:
        return

    var offset := 0.0
    if offset_or_parameters is Dictionary:
        parameters = offset_or_parameters
    elif offset_or_parameters:
        offset = float(offset_or_parameters)

    var event := bank.get_event(event_name)
    if event:
        _runtime.play(event, offset, parameters)


func seek(event_name: StringName, offset: float) -> void:
    _runtime.seek(event_name, offset)


func modulate(event_name: StringName, parameters: Dictionary) -> void:
    _runtime.modulate(event_name, parameters)


func set_parameters(parameters: Dictionary) -> void:
    _runtime.set_parameters(parameters)


func stop(event_name_or_immediate = null, immediate: bool = false) -> void:
    _runtime.stop(event_name_or_immediate, immediate)


func is_playing(event_name: StringName) -> bool:
    return _runtime.is_playing(event_name)


func get_event_visualization_state(event_name: StringName) -> Dictionary:
    return _runtime.get_event_visualization_state(event_name)


func play_automation(event_name: StringName, automation_name: StringName, value: float = 0.0, restart: bool = false) -> void:
    var bank: SfxBank = _owner.bank
    if not bank:
        return

    var event := bank.get_event(event_name)
    if event:
        _runtime.play_automation(event, automation_name, value, restart)


func stop_automation(event_name: StringName, automation_name: StringName, immediate: bool = false) -> void:
    var bank: SfxBank = _owner.bank
    if not bank:
        return

    var event := bank.get_event(event_name)
    if event:
        _runtime.stop_automation(event, automation_name, immediate)


func validate_property(property: Dictionary) -> void:
    if property.name == "playback_effect":
        property.hint = PROPERTY_HINT_ENUM
        property.hint_string = build_playback_effect_hint()
    elif property.name == "playback_automation":
        property.hint = PROPERTY_HINT_ENUM
        property.hint_string = build_playback_automation_hint()


func build_playback_effect_hint() -> String:
    var bank: SfxBank = _owner.bank
    if not bank:
        return ""

    var options := PackedStringArray([PLAYBACK_NONE_OPTION])
    for event in bank.events:
        if not event or String(event.name).is_empty():
            continue
        options.append(String(event.name))
    return ",".join(options)


func build_playback_automation_hint() -> String:
    var options := PackedStringArray([PLAYBACK_NONE_OPTION])
    var event := _find_playback_event()
    if not event:
        return ",".join(options)

    for automation in event.automations:
        if not automation or String(automation.parameter_name).is_empty():
            continue
        options.append(String(automation.parameter_name))
    return ",".join(options)


func sanitize_playback_selection() -> void:
    var event := _find_playback_event()
    var effect: StringName = _owner.playback_effect
    if not String(effect).is_empty() and not event:
        _owner.playback_effect = &""
        _owner.playback_automation = &""
        return

    var automation_name: StringName = _owner.playback_automation
    if String(automation_name).is_empty() or not event:
        return

    for automation in event.automations:
        if automation and automation.parameter_name == automation_name:
            return
    _owner.playback_automation = &""


func _find_playback_event() -> SfxEvent:
    var bank: SfxBank = _owner.bank
    var effect: StringName = _owner.playback_effect
    if not bank or not effect:
        return null
    return bank.get_event(effect)


func notify_playback_property_list_changed() -> void:
    if Engine.is_editor_hint():
        _owner.notify_property_list_changed()


func _ensure_runtime_connections() -> void:
    if not _runtime.process_requirement_changed.is_connected(_on_runtime_process_requirement_changed):
        _runtime.process_requirement_changed.connect(_on_runtime_process_requirement_changed)
    if not _runtime.finished.is_connected(_on_runtime_finished):
        _runtime.finished.connect(_on_runtime_finished)


func _on_runtime_process_requirement_changed(required: bool) -> void:
    if Engine.is_editor_hint():
        _update_process_state()
        return
    _owner.set_process(required)


func _on_runtime_finished() -> void:
    _owner.emit_signal(&"finished")


func _on_player_finished(player) -> void:
    _runtime.handle_player_finished(player)


func _sync_editor_playback() -> void:
    if not Engine.is_editor_hint() or not _owner.is_inside_tree():
        return

    var enabled: bool = _owner.playback_enabled
    var effect: StringName = _owner.playback_effect
    var automation: StringName = _owner.playback_automation
    var automation_value: float = _owner.playback_automation_value

    var config_changed := (
        not enabled == _preview_enabled
        or not effect == _preview_effect
        or not automation == _preview_automation
    )
    var value_changed := not is_equal_approx(automation_value, _preview_automation_value)

    if not config_changed and not value_changed:
        return

    if not enabled or String(effect).is_empty():
        if _preview_enabled and _preview_effect:
            stop(_preview_effect)
        else:
            _runtime.clear()
        _store_preview_state()
        return

    if config_changed:
        _runtime.clear()
        var preview_parameters := {} if String(automation).is_empty() else {automation: automation_value}
        play(effect, 0.0, preview_parameters)
        _store_preview_state()
        return

    if value_changed and not String(automation).is_empty():
        modulate(effect, {automation: automation_value})
        _store_preview_state()


func _store_preview_state() -> void:
    _preview_enabled = _owner.playback_enabled
    _preview_effect = _owner.playback_effect
    _preview_automation = _owner.playback_automation
    _preview_automation_value = _owner.playback_automation_value


func _reset_preview_state() -> void:
    _preview_enabled = false
    _preview_effect = &""
    _preview_automation = &""
    _preview_automation_value = 0.0


func _update_process_state() -> void:
    if Engine.is_editor_hint():
        _owner.set_process(_runtime.requires_process())


func _connect_playback_resource_watchers() -> void:
    var bank: SfxBank = _owner.bank
    if not Engine.is_editor_hint() or not bank:
        return

    for event in bank.events:
        if not event or _watched_events.has(event):
            continue
        event.changed.connect(_on_playback_source_changed)
        _watched_events.append(event)

        for automation in event.automations:
            if not automation or _watched_automations.has(automation):
                continue
            automation.changed.connect(_on_playback_source_changed)
            _watched_automations.append(automation)


func _disconnect_playback_resource_watchers() -> void:
    for event in _watched_events:
        if is_instance_valid(event) and event.changed.is_connected(_on_playback_source_changed):
            event.changed.disconnect(_on_playback_source_changed)
    for automation in _watched_automations:
        if is_instance_valid(automation) and automation.changed.is_connected(_on_playback_source_changed):
            automation.changed.disconnect(_on_playback_source_changed)
    _watched_events.clear()
    _watched_automations.clear()


func _on_playback_source_changed() -> void:
    sanitize_playback_selection()
    sync_values()
