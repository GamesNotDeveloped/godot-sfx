@tool
class_name SfxPlayerCore
extends RefCounted

## Shared playback/preview logic for SfxPlayer and SfxPlayer3D. Composed
## instead of inherited because the two owners extend different Node types
## (Node vs Node3D) and GDScript has no multiple inheritance.
##
## This is the main-thread half of a player: it owns the pool of
## AudioStreamPlayer(3D) nodes and is the only code that touches them. The
## playback engine itself (SfxPlaybackRuntime) runs on GndSfxServer's worker
## thread and only ever writes SfxVoiceSlots, which flush() copies into the
## nodes and observe() reads back. In the editor there is no server and no
## worker: the owning node's _process calls tick_preview() instead.
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

## True while GndSfxServer visits this core every frame; the server owns it
var ticking: bool = false

var _owner
var _make_player: Callable
var _configure_player: Callable
var _runtime := SfxPlaybackRuntime.new()
## Audio nodes, indexed like the runtime's voice slots
var _nodes: Array = []
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
    _connect_playback_resource_watchers()
    sync_values(true)


func deactivate() -> void:
    _disconnect_playback_resource_watchers()
    if not Engine.is_editor_hint():
        GndSfxServer.unregister_core(self)


## One step of the playback engine. Called by GndSfxServer on its worker thread,
## so nothing below it may touch a node.
func tick(delta: float) -> void:
    _runtime.update(delta)


## Editor preview: one whole frame in place, with no server and no worker.
func tick_preview(delta: float) -> void:
    _runtime.update(delta)
    flush()
    observe()
    _owner.set_process(_runtime.requires_process())


## Copies what the last tick decided into the audio nodes. Main thread only.
func flush() -> void:
    var slots: Array[SfxVoiceSlot] = _runtime.get_slots()
    for index in range(slots.size()):
        var slot: SfxVoiceSlot = slots[index]
        if slot.dirty == 0 and slot.play_serial == slot.applied_play_serial:
            continue

        var player = _nodes[index] if index < _nodes.size() else null
        if not player:
            # A slot that only ever asked to stop never had a node to stop
            if slot.play_serial == slot.applied_play_serial:
                slot.dirty = 0
                continue
            player = _make_player.call()
            _configure_player.call(player)
            while _nodes.size() <= index:
                _nodes.append(null)
            _nodes[index] = player
            _owner.add_child(player)
            player.finished.connect(_on_player_finished.bind(player))
            if player is AudioStreamPlayer3D:
                slot.base_max_db = player.max_db

        if slot.dirty & SfxVoiceSlot.Dirty.STREAM:
            player.stream = slot.stream
        if slot.dirty & SfxVoiceSlot.Dirty.GAIN:
            # AudioStreamPlayer3D clamps attenuation + volume_db to max_db
            # (audio_stream_player_3d.cpp, _get_attenuation_db), and close to the listener the
            # attenuation reaches about +100 dB - a gain applied through volume_db alone is then
            # clamped away (a muted clip plays at max_db). Shifting max_db by the same gain makes
            # it act after the clamp: min(att + g, max + g) = min(att, max) + g.
            player.volume_db = slot.volume_db
            if player is AudioStreamPlayer3D:
                player.max_db = slot.base_max_db + slot.volume_db
        if slot.dirty & SfxVoiceSlot.Dirty.PITCH:
            player.pitch_scale = slot.pitch_scale
        if slot.dirty & SfxVoiceSlot.Dirty.SPATIAL and player is AudioStreamPlayer3D:
            if slot.spatial_override:
                player.position = slot.spatial_position
                player.attenuation_model = slot.spatial_attenuation_model
                player.unit_size = slot.spatial_unit_size
                player.panning_strength = slot.spatial_panning_strength
                if slot.spatial_max_distance >= 0.0:
                    player.max_distance = slot.spatial_max_distance
            else:
                player.position = Vector3.ZERO
                _configure_player.call(player)

        if slot.play_serial > slot.applied_play_serial:
            slot.applied_play_serial = slot.play_serial
            player.play(slot.start_position)
            if slot.wants_generator:
                slot.generator_stream_playback = (
                        player.get_stream_playback() as AudioStreamGeneratorPlayback)
        elif slot.transport == SfxVoiceSlot.Transport.STOP and player.playing:
            player.stop()
        slot.dirty = 0

    if _runtime.consume_finished():
        _owner.emit_signal(&"finished")


## Reads back what the audio nodes are doing, for the next tick to work from.
## Main thread only.
func observe() -> void:
    var slots: Array[SfxVoiceSlot] = _runtime.get_slots()
    for index in range(mini(slots.size(), _nodes.size())):
        var player = _nodes[index]
        if not player:
            continue
        var slot: SfxVoiceSlot = slots[index]
        slot.playing = player.playing
        slot.playback_position = player.get_playback_position()


func requires_process() -> bool:
    return _runtime.requires_process()



func events_changed() -> void:
    _disconnect_playback_resource_watchers()
    _connect_playback_resource_watchers()
    sanitize_playback_selection()
    notify_playback_property_list_changed()


func apply_player_config() -> void:
    for player in _nodes:
        if is_instance_valid(player):
            _configure_player.call(player)


func clear() -> void:
    _runtime.clear()
    _request_tick()


func sync_values(rebuild := false) -> void:
    if rebuild:
        _runtime.clear()
        for player in _nodes:
            if is_instance_valid(player):
                _owner.remove_child(player)
                player.queue_free()
        _nodes = []
        _runtime.release_slots()

    _runtime.set_slot_capacity(_owner.max_tracks)
    apply_player_config()
    _sync_editor_playback()


## There is work for the next tick: in game the server starts visiting this
## core again, in the editor the owning node's own _process does the ticking.
func _request_tick() -> void:
    if Engine.is_editor_hint():
        _owner.set_process(true)
        return
    GndSfxServer.activate_core(self)


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
        _request_tick()


func seek(event_name: StringName, offset: float) -> void:
    _runtime.seek(event_name, offset)
    _request_tick()


func modulate(event_name: StringName, parameters: Dictionary) -> void:
    _runtime.modulate(event_name, parameters)
    _request_tick()


func set_parameters(parameters: Dictionary) -> void:
    _runtime.set_parameters(parameters)
    _request_tick()


func stop(event_name_or_immediate = null, immediate: bool = false) -> void:
    _runtime.stop(event_name_or_immediate, immediate)
    _request_tick()


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
        _request_tick()


func stop_automation(event_name: StringName, automation_name: StringName, immediate: bool = false) -> void:
    var bank: SfxBank = _owner.bank
    if not bank:
        return

    var event := bank.get_event(event_name)
    if event:
        _runtime.stop_automation(event, automation_name, immediate)
        _request_tick()


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
        if not event or not event.name:
            continue
        options.append(event.name)
    return ",".join(options)


func build_playback_automation_hint() -> String:
    var options := PackedStringArray([PLAYBACK_NONE_OPTION])
    var event := _find_playback_event()
    if not event:
        return ",".join(options)

    for automation in event.automations:
        if not automation or not automation.parameter_name:
            continue
        options.append(automation.parameter_name)
    for modulation in event.parameter_modulations:
        if not modulation or not modulation.parameter_name or options.has(modulation.parameter_name):
            continue
        options.append(modulation.parameter_name)
    return ",".join(options)


func sanitize_playback_selection() -> void:
    var event := _find_playback_event()
    var effect: StringName = _owner.playback_effect
    if effect and not event:
        _owner.playback_effect = &""
        _owner.playback_automation = &""
        return

    var automation_name: StringName = _owner.playback_automation
    if not automation_name or not event:
        return

    for automation in event.automations:
        if automation and automation.parameter_name == automation_name:
            return
    for modulation in event.parameter_modulations:
        if modulation and modulation.parameter_name == automation_name:
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


## A node reached the end of its stream on its own. A node this runtime stopped
## deliberately is already off the active list, and Godot emits `finished` for
## those too, hence the playing check.
func _on_player_finished(player) -> void:
    if player.playing:
        return
    var index := _nodes.find(player)
    var slots: Array[SfxVoiceSlot] = _runtime.get_slots()
    if index == -1 or index >= slots.size():
        return
    var slot: SfxVoiceSlot = slots[index]
    slot.playing = false
    _runtime.handle_slot_finished(slot)
    _request_tick()


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

    if not enabled or not effect:
        if _preview_enabled and _preview_effect:
            stop(_preview_effect)
        else:
            _runtime.clear()
        _store_preview_state()
        return

    if config_changed:
        _runtime.clear()
        var preview_parameters := {} if not automation else {automation: automation_value}
        play(effect, 0.0, preview_parameters)
        _store_preview_state()
        return

    if value_changed and automation:
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
