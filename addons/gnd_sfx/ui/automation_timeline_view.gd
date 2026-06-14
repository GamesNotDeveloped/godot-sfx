extends TimelineViewBase
class_name AutomationTimelineView

var event: SfxEvent:
    set(value):
        event = value
        _rebuild_from_automation()

var automation: SfxAutomation:
    set(value):
        automation = value
        _rebuild_from_automation()

var _clips: Array[SfxClip] = []
var _domain_min := 0.0
var _domain_max := 1.0
var _domain_cursor_value := 0.0
var _domain_cursor_visible := false
var _pending_rebuild := false


func _init() -> void:
    title = "Automation"
    empty_message = "This automation has no clips."


func _on_ready_finished() -> void:
    if _pending_rebuild:
        _pending_rebuild = false
        _rebuild_lanes()
    else:
        _refresh_navigation_visibility()
        _refresh_labels()
        _queue_layout_refresh()


func _resolve_clip_track(clip: SfxClip) -> SfxTrack:
    if clip.track:
        return clip.track
    return event.master_track if event else null


func _track_sort_key(clip: SfxClip) -> int:
    if not event:
        return 0
    var found := event.tracks.find(_resolve_clip_track(clip))
    return found if found >= 0 else event.tracks.size()


func _rebuild_from_automation() -> void:
    _clips.clear()
    if automation:
        for clip in automation.clips:
            if clip is SfxClip:
                _clips.append(clip as SfxClip)
        _clips.sort_custom(func(a: SfxClip, b: SfxClip) -> bool: return _track_sort_key(a) < _track_sort_key(b))
        _domain_min = automation.min_domain
        _domain_max = automation.max_domain
        if _domain_max <= _domain_min:
            _domain_max = _domain_min + 1.0
    _clip_cursor_states.clear()
    _zoom = 1.0
    _view_offset = 0.0
    if is_node_ready():
        _rebuild_lanes()
    else:
        _pending_rebuild = true


func set_domain_cursor(value: float, visible: bool) -> void:
    _domain_cursor_value = value
    _domain_cursor_visible = visible
    _update_lane_cursors()
    _update_global_cursor()


func apply_clip_playback_visualization(clip_states: Dictionary) -> void:
    _clip_cursor_states = clip_states
    _update_lane_cursors()


func _rebuild_lanes() -> void:
    _clear_track_cells()
    _lane_views.clear()

    if _clips.is_empty():
        _empty_label.text = empty_message
        _empty_label.show()
        _refresh_labels()
        _update_global_cursor()
        return

    _empty_label.hide()
    for index in range(_clips.size()):
        var clip := _clips[index]
        var track := _resolve_clip_track(clip)
        var lane: TrackLaneView = TrackLaneViewScene.instantiate()
        _timeline_table.add_child(lane)
        lane.index = event.tracks.find(track) if event else -1
        lane.column_width = label_column_width
        lane.row_height = lane_height
        lane.track = track
        lane.clips = [clip]

        if not lane.waveform.gui_input.is_connected(_on_lane_canvas_gui_input):
            lane.waveform.gui_input.connect(_on_lane_canvas_gui_input.bind(lane.waveform))

        lane.waveform.get_bar(0).set_clip_name(WaveformPreviewCache.get_clip_name(clip))
        lane.waveform.get_bar(0).set_fade_overlay_lines([])
        _assign_waveform_preview(lane.waveform.get_bar(0), clip)

        _lane_views.append(lane)

    _refresh_labels()
    _queue_layout_refresh()


func _flush_layout_refresh() -> void:
    var content_height := _measure_lane_stack_height()
    var content_size := Vector2(0.0, content_height)
    if not (_scroll_content.custom_minimum_size == content_size):
        _scroll_content.custom_minimum_size = content_size
        _queue_layout_refresh()
        return

    var visible_range := _get_visible_range()
    var visible_start := float(visible_range["start"])
    var visible_end := float(visible_range["end"])
    var domain_span := maxf(visible_end - visible_start, 0.001)
    for lane_index in range(_lane_views.size()):
        var lane := _lane_views[lane_index]
        var clip := _clips[lane_index]
        var canvas: Control = lane.waveform
        var bar: WaveformPreview = lane.waveform.get_bar(0)
        var current_lane_height := maxf(canvas.size.y, lane_height)
        var lane_width := maxf(canvas.size.x, 1.0)
        var clip_start := _resolve_clip_start(clip)
        var clip_end := _resolve_clip_end(clip)
        var clipped_start := clampf(clip_start, visible_start, visible_end)
        var clipped_end := clampf(clip_end, visible_start, visible_end)

        if clipped_end <= clipped_start:
            if bar.visible:
                bar.visible = false
            bar.set_waveform_window(0.0, 1.0)
            bar.set_cursor_position(0.0, false)
            bar.set_fade_overlay_lines([])
            continue

        if not bar.visible:
            bar.visible = true

        var x := clampf(((clipped_start - visible_start) / domain_span) * lane_width, 0.0, lane_width)
        var end_x := clampf(((clipped_end - visible_start) / domain_span) * lane_width, 0.0, lane_width)
        var width := maxf(end_x - x, 1.0)
        var bar_position := Vector2(x, 0.0)
        var bar_size := Vector2(width, current_lane_height)
        if not (bar.position == bar_position):
            bar.position = bar_position
        if not (bar.size == bar_size):
            bar.size = bar_size

        var waveform_window := lane.waveform.resolve_waveform_window(clip, bar.get_preview_duration(), clip_start, clipped_start, clipped_end)
        bar.set_waveform_window(float(waveform_window["start_ratio"]), float(waveform_window["end_ratio"]))
        var sampler := func(c: Curve, v: float, fo: bool) -> float:
            return _sample_clip_curve(clip, c, v, clip_start, clip_end, fo)
        bar.set_fade_overlay_lines(lane.waveform.build_fade_overlay_lines(clip, clipped_start, clipped_end, bar.size, sampler))

    _update_lane_cursors()
    _update_global_cursor()
    _refresh_navigation_controls()
    if is_instance_valid(_ruler):
        _ruler.queue_redraw()


func _measure_lane_stack_height() -> float:
    return maxf(_timeline_table.get_combined_minimum_size().y, _timeline_table.size.y)


func _on_lane_canvas_gui_input(event: InputEvent, lane_canvas: Control) -> void:
    if not (event is InputEventMouseButton):
        return
    var mouse_event := event as InputEventMouseButton
    if not (mouse_event.button_index == MOUSE_BUTTON_LEFT) or not mouse_event.pressed:
        return
    _emit_axis_value_at_ratio(clampf(mouse_event.position.x / maxf(lane_canvas.size.x, 1.0), 0.0, 1.0))


func _on_ruler_gui_input(event: InputEvent) -> void:
    var button_event := event as InputEventMouseButton
    var motion_event := event as InputEventMouseMotion
    if not (
        (button_event and button_event.button_index == MOUSE_BUTTON_LEFT and button_event.pressed)
        or (motion_event and motion_event.button_mask == MOUSE_BUTTON_MASK_LEFT)
    ):
        return

    var wave_width := maxf(_ruler.size.x, 1.0)
    if event.position.x < 0.0 or event.position.x > wave_width:
        return
    _emit_axis_value_at_ratio(clampf(event.position.x / wave_width, 0.0, 1.0))


func _get_visible_range() -> Dictionary:
    var full_span := maxf(_domain_max - _domain_min, 0.001)
    var visible_span := maxf(full_span / maxf(_zoom, 0.0001), 0.001)
    var clamped_offset := _clamp_view_offset(_view_offset, visible_span)
    return {
        "start": _domain_min + clamped_offset,
        "end": _domain_min + clamped_offset + visible_span,
    }


func _format_axis_label(visible_range: Dictionary) -> String:
    return "Domain: %.2f -> %.2f" % [float(visible_range["start"]), float(visible_range["end"])]


func _clamp_view_offset(value: float, visible_span := -1.0) -> float:
    if visible_span < 0.0:
        visible_span = maxf((_domain_max - _domain_min) / maxf(_zoom, 0.0001), 0.001)
    return clampf(value, 0.0, _get_max_view_offset(visible_span))


func _get_max_view_offset(visible_span: float) -> float:
    return maxf((_domain_max - _domain_min) - visible_span, 0.0)


func _update_lane_cursors() -> void:
    for lane_index in range(_lane_views.size()):
        var lane := _lane_views[lane_index]
        var clip := _clips[lane_index]
        var bar: WaveformPreview = lane.waveform.get_bar(0)

        var clip_state: Dictionary = _clip_cursor_states.get(clip, {})
        var active := bool(clip_state.get("active", false))
        var position := float(clip_state.get("position", 0.0))
        var visible_span := maxf(float(clip_state.get("visible_span", 0.0)), 0.0)
        if not active or visible_span <= 0.0 or not bar.visible:
            bar.set_cursor_position(0.0, false)
            continue
        bar.set_cursor_position(clampf(position / visible_span, 0.0, 1.0), true)


func _get_cursor_state() -> Dictionary:
    return {"visible": _domain_cursor_visible, "value": _domain_cursor_value}


func _format_ruler_label(value: float) -> String:
    if absf(value) >= 10.0:
        return "%.0f" % value
    return "%.2f" % value


func _resolve_clip_start(clip: SfxClip) -> float:
    return maxf(clip.offset, _domain_min)


func _resolve_clip_end(clip: SfxClip) -> float:
    if clip.length > 0.0:
        return maxf(clip.offset + clip.length, clip.offset)
    return maxf(clip.offset, _domain_max)


func _sample_clip_curve(clip: SfxClip, curve: Curve, axis_value: float, _clip_start: float, _clip_end: float, fade_out: bool) -> float:
    if curve == null:
        return 1.0
    if not fade_out:
        return clampf(_sample_automation_curve(curve, clip, axis_value), 0.0, 1.0)
    return clampf(_sample_automation_fade_out_curve(curve, clip, axis_value), 0.0, 1.0)


func _sample_automation_curve(curve: Curve, clip: SfxClip, value: float) -> float:
    if curve == null:
        return 1.0
    var local_value := clampf(value - clip.offset, curve.min_domain, curve.max_domain)
    return curve.sample(local_value)


func _sample_automation_fade_out_curve(curve: Curve, clip: SfxClip, value: float) -> float:
    if curve == null:
        return 1.0
    if clip.length > 0.0:
        var duration := _get_curve_duration(curve)
        if duration <= 0.0:
            return curve.sample(curve.max_domain)
        var fade_end := clip.offset + clip.length
        var remaining := maxf(fade_end - value, 0.0)
        var clamped_remaining := clampf(remaining, 0.0, duration)
        return curve.sample(curve.min_domain + (duration - clamped_remaining))
    var local_value := clampf(value - clip.offset, curve.min_domain, curve.max_domain)
    return curve.sample(curve.min_domain + (curve.max_domain - local_value))
