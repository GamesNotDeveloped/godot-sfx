extends Window
class_name EventViewer

const TracksTimelineViewScene := preload("./timeline_view.tscn")
const AutomationTimelineViewScene := preload("./automation_timeline_view.tscn")
const ParameterEditorScene := preload("./parameter_editor.tscn")
const TabContentWrapperScene := preload("./tab_content_wrapper.tscn")

@export var event: SfxEvent:
    set(value):
        event = value
        _reset_parameter_values()
        _refresh()

var player: SfxPlayer
var _tracks_timeline: TimelineView
var _automation_timelines := {}
var _parameter_controls := {}
var _suppress_parameter_control_updates := false
var _manual_time_cursor_value := 0.0
var _manual_time_cursor_visible := false

@onready var _window_title_label: Label = $Root/VBox/TopBar/WindowTitleLabel
@onready var _play_button: Button = $Root/VBox/TopBar/TransportPanel/TransportBox/PlayButton
@onready var _stop_button: Button = $Root/VBox/TopBar/TransportPanel/TransportBox/StopButton
@onready var _stop_immediate_button: Button = $Root/VBox/TopBar/TransportPanel/TransportBox/StopImmediateButton
@onready var _current_time_label: Label = $Root/VBox/TopBar/CurrentTimeLabel
@onready var _follow_cursor_toggle: CheckButton = $Root/VBox/TopBar/FollowCursorToggle
@onready var _params_container: HFlowContainer = $Root/VBox/ParamsScroll/ParamsContainer
@onready var _no_params_label: Label = $Root/VBox/ParamsScroll/ParamsContainer/NoParamsLabel
@onready var _tabs: TabContainer = $Root/VBox/Tabs
@onready var _empty_tabs_label: Label = $Root/VBox/EmptyTabsLabel

var _parameter_values: Dictionary = {}
var _parameter_snapshot_seeded := false


func _ready() -> void:
    close_requested.connect(queue_free)
    _play_button.pressed.connect(_on_play_pressed)
    _stop_button.pressed.connect(_on_stop_pressed)
    _stop_immediate_button.pressed.connect(_on_stop_immediate_pressed)
    _follow_cursor_toggle.toggled.connect(_on_follow_cursor_toggled)
    set_process(true)
    _refresh()


func configure(event_value: SfxEvent, player_value: SfxPlayer) -> void:
    player = player_value
    event = event_value


func _refresh() -> void:
    if not is_node_ready():
        return

    title = _resolve_event_title()
    _window_title_label.text = title
    _current_time_label.text = _format_playback_time(0.0)
    _seed_parameter_values_from_runtime_snapshot()
    _rebuild_parameter_controls()
    _show_tabs_loading_state()

    var pending_event := event
    await get_tree().process_frame
    if event == pending_event:
        _rebuild_tabs()


func _show_tabs_loading_state() -> void:
    for child in _tabs.get_children():
        child.queue_free()
    _tracks_timeline = null
    _automation_timelines.clear()
    _empty_tabs_label.text = "No event selected" if event == null else "Loading previews..."
    _empty_tabs_label.show()


func _resolve_event_title() -> String:
    if event == null or String(event.name).is_empty():
        return "Event Viewer"
    return "Event Viewer: %s" % String(event.name)


func _reset_parameter_values() -> void:
    _parameter_values.clear()
    _parameter_snapshot_seeded = false
    _manual_time_cursor_value = 0.0
    _manual_time_cursor_visible = false
    if event == null:
        return
    for automation in event.automations:
        if automation == null or String(automation.parameter_name).is_empty():
            continue
        _parameter_values[automation.parameter_name] = automation.min_domain


func _seed_parameter_values_from_runtime_snapshot() -> void:
    if _parameter_snapshot_seeded:
        return
    if player == null or event == null or String(event.name).is_empty():
        return
    _parameter_snapshot_seeded = true
    var visualization_state: Dictionary = player.get_event_visualization_state(event.name)
    if not bool(visualization_state.get("playing", false)):
        return
    var parameters = visualization_state.get("parameters", {})
    if not (parameters is Dictionary):
        return
    for automation in event.automations:
        if automation == null or String(automation.parameter_name).is_empty():
            continue
        if parameters.has(automation.parameter_name):
            _parameter_values[automation.parameter_name] = float(parameters[automation.parameter_name])


func _rebuild_parameter_controls() -> void:
    _parameter_controls.clear()
    for child in _params_container.get_children():
        if not (child == _no_params_label):
            child.queue_free()

    _no_params_label.hide()

    if event == null or event.automations.is_empty():
        _no_params_label.text = "No automations"
        _no_params_label.show()
        return

    var has_parameter := false
    for automation in event.automations:
        if automation == null or String(automation.parameter_name).is_empty():
            continue
        has_parameter = true
        _build_parameter_editor(automation)

    if not has_parameter:
        _no_params_label.text = "No named automation parameters"
        _no_params_label.show()
    _sync_automation_cursors()


func _build_parameter_editor(automation: SfxAutomation) -> Control:
    var panel: ParameterEditor = ParameterEditorScene.instantiate()
    _params_container.add_child(panel)
    var slider := panel.slider
    var spinbox := panel.spinbox

    panel.title_label.text = String(automation.parameter_name)
    slider.min_value = automation.min_domain
    slider.max_value = maxf(automation.max_domain, automation.min_domain + 0.001)
    slider.step = maxf((slider.max_value - slider.min_value) / 200.0, 0.001)
    slider.value = float(_parameter_values.get(automation.parameter_name, automation.min_domain))
    spinbox.min_value = slider.min_value
    spinbox.max_value = slider.max_value
    spinbox.step = slider.step
    spinbox.value = slider.value

    slider.value_changed.connect(_on_parameter_control_changed.bind(automation.parameter_name, slider, spinbox, true))
    spinbox.value_changed.connect(_on_parameter_control_changed.bind(automation.parameter_name, slider, spinbox, false))
    _parameter_controls[automation.parameter_name] = {
        "slider": slider,
        "spinbox": spinbox,
    }

    return panel


func _on_parameter_control_changed(value: float, parameter_name: StringName, slider: HSlider, spinbox: SpinBox, from_slider: bool) -> void:
    if _suppress_parameter_control_updates:
        return
    if from_slider:
        if not is_equal_approx(spinbox.value, value):
            spinbox.value = value
    else:
        if not is_equal_approx(slider.value, value):
            slider.value = value

    _apply_parameter_value(parameter_name, value, true, false)


func _rebuild_tabs() -> void:
    if event == null:
        _empty_tabs_label.text = "No event selected"
        _empty_tabs_label.show()
        return

    _empty_tabs_label.hide()
    _add_tracks_tab("Tracks", event)

    for automation in event.automations:
        if automation == null:
            continue
        var tab_title := String(automation.parameter_name)
        if tab_title.is_empty():
            tab_title = "Automation"
        _add_automation_tab(tab_title, event, automation)
    _sync_automation_cursors()


func _wrap_tab(tab_title: String, content: Control) -> MarginContainer:
    var tab: MarginContainer = TabContentWrapperScene.instantiate()
    tab.name = "TabContent_%s" % tab_title.validate_node_name()
    tab.add_child(content)
    return tab


func _add_tab(tab_title: String, content: Control) -> void:
    _tabs.add_child(_wrap_tab(tab_title, content))
    var tab_index := _tabs.get_tab_count() - 1
    if tab_index >= 0:
        _tabs.set_tab_title(tab_index, tab_title)


func _add_tracks_tab(tab_title: String, for_event: SfxEvent) -> void:
    var timeline: TimelineView = TracksTimelineViewScene.instantiate()
    timeline.title = tab_title
    timeline.event = for_event
    timeline.axis_value_selected.connect(_on_timeline_axis_value_selected.bind(timeline))
    _tracks_timeline = timeline
    _tracks_timeline.set_follow_cursor_enabled(_follow_cursor_toggle.button_pressed)
    _tracks_timeline.set_time_cursor(_manual_time_cursor_value, _manual_time_cursor_visible)
    _add_tab(tab_title, timeline)


func _add_automation_tab(tab_title: String, for_event: SfxEvent, for_automation: SfxAutomation) -> void:
    var timeline: AutomationTimelineView = AutomationTimelineViewScene.instantiate()
    timeline.title = tab_title
    timeline.event = for_event
    timeline.automation = for_automation
    timeline.axis_value_selected.connect(_on_automation_axis_value_selected.bind(timeline))
    _automation_timelines[StringName(tab_title)] = timeline
    _add_tab(tab_title, timeline)


func _sync_automation_cursors() -> void:
    for automation_key in _automation_timelines.keys():
        var timeline = _automation_timelines[automation_key]
        var visible := _parameter_values.has(automation_key)
        var value := float(_parameter_values.get(automation_key, 0.0))
        if timeline:
            timeline.set_domain_cursor(value, visible)
            timeline.apply_clip_playback_visualization({})


func _process(_delta: float) -> void:
    if _tracks_timeline == null or player == null or event == null or String(event.name).is_empty():
        return
    var visualization_state: Dictionary = player.get_event_visualization_state(event.name)
    _tracks_timeline.apply_time_visualization(visualization_state)
    var event_time := float(visualization_state.get("event_time", 0.0))
    var playing := bool(visualization_state.get("playing", false))
    var automation_clip_states: Dictionary = visualization_state.get("automation_clips", {})
    for automation_key in _automation_timelines.keys():
        var automation_timeline = _automation_timelines[automation_key]
        if automation_timeline:
            automation_timeline.apply_clip_playback_visualization(
                automation_clip_states.get(automation_key, {})
            )
    if playing:
        _manual_time_cursor_visible = false
        _current_time_label.text = _format_playback_time(event_time)
    elif _manual_time_cursor_visible:
        _tracks_timeline.set_time_cursor(_manual_time_cursor_value, true)
        _current_time_label.text = _format_playback_time(_manual_time_cursor_value)
    else:
        _current_time_label.text = _format_playback_time(0.0)


func _on_follow_cursor_toggled(enabled: bool) -> void:
    if _tracks_timeline:
        _tracks_timeline.set_follow_cursor_enabled(enabled)


func _format_playback_time(seconds: float) -> String:
    var safe_seconds := maxf(seconds, 0.0)
    var total_millis := int(round(safe_seconds * 1000.0))
    var millis := total_millis % 1000
    var total_seconds := total_millis / 1000
    var secs := total_seconds % 60
    var minutes := total_seconds / 60
    return "%02d:%02d:%03d" % [minutes, secs, millis]


func _on_play_pressed() -> void:
    if player == null or event == null or String(event.name).is_empty():
        return
    player.play(event.name, _parameter_values.duplicate(true))


func _on_stop_pressed() -> void:
    if player == null or event == null or String(event.name).is_empty():
        return
    player.stop(event.name)


func _on_stop_immediate_pressed() -> void:
    if player == null or event == null or String(event.name).is_empty():
        return
    player.stop(event.name, true)


func _apply_parameter_value(parameter_name: StringName, value: float, propagate_runtime: bool, sync_controls: bool) -> void:
    _parameter_values[parameter_name] = value
    var automation_timeline = _automation_timelines.get(parameter_name)
    if automation_timeline:
        automation_timeline.set_domain_cursor(value, true)
    if sync_controls:
        var controls: Dictionary = _parameter_controls.get(parameter_name, {})
        var slider: HSlider = controls.get("slider")
        var spinbox: SpinBox = controls.get("spinbox")
        _suppress_parameter_control_updates = true
        if slider and not is_equal_approx(slider.value, value):
            var slider_step := slider.step
            slider.step = 0.0
            slider.value = value
            slider.step = slider_step
        if spinbox and not is_equal_approx(spinbox.value, value):
            var spinbox_step := spinbox.step
            spinbox.step = 0.0
            spinbox.value = value
            spinbox.step = spinbox_step
        _suppress_parameter_control_updates = false
    if propagate_runtime and player and event and not String(event.name).is_empty():
        player.modulate(event.name, {parameter_name: value})


func _on_timeline_axis_value_selected(value: float, timeline: TimelineView) -> void:
    if not timeline or not timeline == _tracks_timeline:
        return
    _manual_time_cursor_value = maxf(value, 0.0)
    _manual_time_cursor_visible = true
    _tracks_timeline.set_time_cursor(_manual_time_cursor_value, true)
    _current_time_label.text = _format_playback_time(_manual_time_cursor_value)
    if player and event and not String(event.name).is_empty() and player.is_playing(event.name):
        player.seek(event.name, _manual_time_cursor_value)


func _on_automation_axis_value_selected(value: float, timeline) -> void:
    if timeline == null:
        return
    for automation_key in _automation_timelines.keys():
        if _automation_timelines[automation_key] == timeline:
            _apply_parameter_value(StringName(automation_key), value, true, true)
            return
