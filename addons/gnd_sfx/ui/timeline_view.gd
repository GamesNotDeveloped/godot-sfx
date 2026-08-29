extends TimelineViewBase
class_name TimelineView

@export var pixels_per_second := 480.0

var event: SfxEvent:
    set(value):
        event = value
        _rebuild_from_event()

var _clips: Array[SfxClip] = []
var _lane_groups: Array[Dictionary] = []
var _axis_max := 1.0
var _pending_refresh := false
var _time_cursor_value := 0.0
var _time_cursor_visible := false
var _follow_cursor_enabled := false
var _manual_time_cursor_value := 0.0
var _manual_time_cursor_visible := false
var _selected_track: SfxTrack = null
var _selected_clip: SfxClip = null

@onready var _details_title_label: Label = $Margin/VBox/DetailsPanel/DetailsMargin/DetailsBox/DetailsTitleLabel
@onready var _details_body_label: Label = $Margin/VBox/DetailsPanel/DetailsMargin/DetailsBox/DetailsBodyLabel


func _init() -> void:
    title = "Tracks"
    empty_message = "This event has no timeline clips."


func _on_ready_finished() -> void:
    _refresh_details_panel()
    if _pending_refresh:
        _pending_refresh = false
        _rebuild_lanes()
    else:
        _refresh_navigation_visibility()
        _refresh_labels()
        _queue_layout_refresh()


func _rebuild_from_event() -> void:
    _clips.clear()
    _lane_groups.clear()
    if event:
        for clip in event.clips:
            if clip is SfxClip:
                _clips.append(clip as SfxClip)
        var tracks := event.tracks.duplicate()
        tracks.append(event.master_track)
        _lane_groups = _build_lane_groups(tracks, _clips, event.master_track)
    _clip_cursor_states.clear()
    _view_offset = 0.0
    _zoom = 1.0
    _manual_time_cursor_value = 0.0
    _manual_time_cursor_visible = false
    _axis_max = _compute_time_axis_max()
    _selected_track = null
    _selected_clip = null
    _refresh_details_panel()
    if is_node_ready():
        _rebuild_lanes()
    else:
        _pending_refresh = true


func apply_time_visualization(state: Dictionary) -> void:
    _clip_cursor_states = state.get("clips", {})
    _time_cursor_value = float(state.get("event_time", 0.0))
    _time_cursor_visible = bool(state.get("playing", false))
    var previous_view_offset := _view_offset
    _update_virtual_view_offset()
    if not is_equal_approx(previous_view_offset, _view_offset):
        _refresh_labels()
        _queue_layout_refresh()
        return
    _update_lane_cursors()
    _update_global_cursor()


func set_follow_cursor_enabled(enabled: bool) -> void:
    _follow_cursor_enabled = enabled
    _update_global_cursor()


func set_time_cursor(value: float, visible: bool) -> void:
    _manual_time_cursor_value = value
    _manual_time_cursor_visible = visible
    _update_global_cursor()


func set_view_offset_seconds(value: float) -> void:
    _view_offset = _clamp_view_offset(value)
    _refresh_labels()
    _queue_layout_refresh()


func _build_lane_groups(tracks: Array, clips: Array[SfxClip], master_track: SfxTrack) -> Array[Dictionary]:
    var groups: Array[Dictionary] = []
    var clips_by_track: Dictionary = {}

    for clip in clips:
        var track: SfxTrack = clip.track if clip.track else master_track
        if not track:
            continue
        if not clips_by_track.has(track):
            var track_group: Array[SfxClip] = []
            clips_by_track[track] = track_group
        clips_by_track[track].append(clip)

    for track in tracks:
        if not (track is SfxTrack):
            continue
        var track_clips: Array[SfxClip] = _get_group_clips(clips_by_track, track)
        groups.append({
            "track": track,
            "clips": track_clips,
            "sub_rows": _pack_sub_rows(track_clips),
        })

    return groups


func _get_group_clips(clips_by_track: Dictionary, track: SfxTrack) -> Array[SfxClip]:
    var track_clips: Array[SfxClip] = []
    for clip: SfxClip in clips_by_track.get(track, []):
        track_clips.append(clip)
    return track_clips


func _get_lane_group_clips(group: Dictionary) -> Array[SfxClip]:
    var clips: Array[SfxClip] = []
    for clip: SfxClip in group.get("clips", []):
        clips.append(clip)
    return clips


func _pack_sub_rows(clips: Array[SfxClip]) -> Array[int]:
    var sub_rows: Array[int] = []
    sub_rows.resize(clips.size())
    var entries: Array[Dictionary] = []
    for index in range(clips.size()):
        entries.append({
            "index": index,
            "start": _resolve_clip_start(clips[index]),
            "end": _resolve_clip_end(clips[index]),
        })
    entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["start"] < b["start"])

    var row_ends: Array[float] = []
    for entry in entries:
        var placed := false
        for row in range(row_ends.size()):
            if row_ends[row] <= entry["start"]:
                row_ends[row] = entry["end"]
                sub_rows[entry["index"]] = row
                placed = true
                break
        if not placed:
            row_ends.append(entry["end"])
            sub_rows[entry["index"]] = row_ends.size() - 1

    return sub_rows


func _compute_time_axis_max() -> float:
    var computed_max := 1.0
    for clip in _clips:
        computed_max = maxf(computed_max, _resolve_clip_end(clip))
    return computed_max


func _rebuild_lanes() -> void:
    _clear_track_cells()
    _lane_views.clear()

    if _lane_groups.is_empty():
        _empty_label.text = empty_message
        _empty_label.show()
        _sync_scroll_content_size()
        _refresh_selection_visuals()
        return

    _empty_label.hide()
    for index in range(_lane_groups.size()):
        var group: Dictionary = _lane_groups[index]
        var clips: Array[SfxClip] = _get_lane_group_clips(group)
        var sub_row_count: int = 1
        for sub_row in group["sub_rows"]:
            sub_row_count = maxi(sub_row_count, int(sub_row) + 1)

        var lane: TrackLaneView = TrackLaneViewScene.instantiate()
        _timeline_table.add_child(lane)
        lane.index = index
        lane.column_width = label_column_width
        lane.row_height = lane_height * sub_row_count
        lane.track = group["track"]
        lane.clips = clips

        if not lane.waveform.gui_input.is_connected(_on_lane_canvas_gui_input):
            lane.waveform.gui_input.connect(_on_lane_canvas_gui_input.bind(lane))
        if not lane.header.gui_input.is_connected(_on_lane_header_gui_input):
            lane.header.gui_input.connect(_on_lane_header_gui_input.bind(group["track"]))

        for clip in clips:
            var bar: WaveformPreview = lane.waveform.get_bar(clips.find(clip))
            bar.set_clip_name(WaveformPreviewCache.get_clip_name(clip))
            bar.set_fade_overlay_lines([])
            _assign_waveform_preview(bar, clip)

        _lane_views.append(lane)

    _refresh_selection_visuals()
    _queue_layout_refresh()


func _flush_layout_refresh() -> void:
    if _sync_scroll_content_size():
        _queue_layout_refresh()
        return
    _view_offset = _clamp_view_offset(_view_offset)
    var visible_range := _get_visible_range()
    var visible_start := float(visible_range["start"])
    var visible_end := float(visible_range["end"])
    var axis_span := maxf(visible_end - visible_start, 0.001)
    for lane_index in range(_lane_views.size()):
        var lane := _lane_views[lane_index]
        var group: Dictionary = _lane_groups[lane_index]
        var clips: Array[SfxClip] = _get_lane_group_clips(group)
        var sub_rows: Array = group["sub_rows"]
        var canvas: Control = lane.waveform
        var lane_width := maxf(canvas.size.x, 1.0)

        for clip_index in range(clips.size()):
            var clip: SfxClip = clips[clip_index]
            var bar: WaveformPreview = lane.waveform.get_bar(clip_index)
            var sub_row: int = sub_rows[clip_index]

            var start := _resolve_clip_start(clip)
            var end := _resolve_clip_end(clip)
            var clipped_start := clampf(start, visible_start, visible_end)
            var clipped_end := clampf(end, visible_start, visible_end)
            if clipped_end <= visible_start or clipped_start >= visible_end or clipped_end <= clipped_start:
                if bar.visible:
                    bar.visible = false
                bar.set_waveform_window(0.0, 1.0)
                bar.set_cursor_position(0.0, false)
                bar.set_fade_overlay_lines([])
                continue
            if not bar.visible:
                bar.visible = true
            var x := clampf(((clipped_start - visible_start) / axis_span) * lane_width, 0.0, lane_width)
            var end_x := clampf(((clipped_end - visible_start) / axis_span) * lane_width, 0.0, lane_width)
            var width := maxf(end_x - x, 1.0)
            var bar_position := Vector2(x, float(sub_row) * lane_height)
            var bar_size := Vector2(width, lane_height)
            if not (bar.position == bar_position):
                bar.position = bar_position
            if not (bar.size == bar_size):
                bar.size = bar_size
            var waveform_window := lane.waveform.resolve_waveform_window(clip, bar.get_preview_duration(), start, clipped_start, clipped_end)
            bar.set_waveform_window(float(waveform_window["start_ratio"]), float(waveform_window["end_ratio"]))
            var sampler := func(c: Curve, v: float, fo: bool) -> float:
                return _sample_clip_curve(c, v, start, end, fo)
            bar.set_fade_overlay_lines(lane.waveform.build_fade_overlay_lines(clip, clipped_start, clipped_end, bar.size, sampler))

    _update_lane_cursors()
    _update_global_cursor()
    _refresh_navigation_controls()
    if is_instance_valid(_ruler):
        _ruler.queue_redraw()


func _on_lane_canvas_gui_input(event: InputEvent, lane: TrackLaneView) -> void:
    if not (event is InputEventMouseButton):
        return
    var mouse_event := event as InputEventMouseButton
    if not (mouse_event.button_index == MOUSE_BUTTON_LEFT) or not mouse_event.pressed:
        return
    var lane_canvas: Control = lane.waveform
    _emit_axis_value_at_ratio(clampf(mouse_event.position.x / maxf(lane_canvas.size.x, 1.0), 0.0, 1.0))
    var clicked_clip := _find_clip_at_position(lane, mouse_event.position)
    if clicked_clip:
        _select_clip(clicked_clip)


func _on_lane_header_gui_input(event: InputEvent, track: SfxTrack) -> void:
    if not (event is InputEventMouseButton):
        return
    var mouse_event := event as InputEventMouseButton
    if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
        _select_track(track)


func _find_clip_at_position(lane: TrackLaneView, position: Vector2) -> SfxClip:
    if lane.index < 0 or lane.index >= _lane_groups.size():
        return null
    var clips := _get_lane_group_clips(_lane_groups[lane.index])
    for clip_index in range(clips.size()):
        var bar: WaveformPreview = lane.waveform.get_bar(clip_index)
        if bar.visible and Rect2(bar.position, bar.size).has_point(position):
            return clips[clip_index]
    return null


func _select_track(track: SfxTrack) -> void:
    _selected_track = track
    _selected_clip = null
    _refresh_selection_visuals()
    _refresh_details_panel()


func _select_clip(clip: SfxClip) -> void:
    _selected_clip = clip
    _selected_track = null
    _refresh_selection_visuals()
    _refresh_details_panel()


func _refresh_selection_visuals() -> void:
    for lane_index in range(_lane_views.size()):
        var lane := _lane_views[lane_index]
        lane.header.selected = (lane.track == _selected_track) and _selected_track
        var clips := _get_lane_group_clips(_lane_groups[lane_index])
        for clip_index in range(clips.size()):
            var bar: WaveformPreview = lane.waveform.get_bar(clip_index)
            bar.selected = (clips[clip_index] == _selected_clip) and _selected_clip


func _refresh_details_panel() -> void:
    if not is_node_ready():
        return
    if _selected_clip:
        _details_title_label.text = "Clip: %s" % WaveformPreviewCache.get_clip_name(_selected_clip)
        _details_body_label.text = _format_clip_details(_selected_clip)
    elif _selected_track:
        var track_index := event.tracks.find(_selected_track) if event else -1
        var track_name := String(_selected_track.track_name)
        var title_name := track_name if not track_name.is_empty() else "Track %d" % (track_index + 1)
        _details_title_label.text = "Track: %s" % title_name
        _details_body_label.text = _format_track_details(_selected_track)
    else:
        _details_title_label.text = "No selection"
        _details_body_label.text = "Click a track header or a clip to see details."


func _format_track_details(track: SfxTrack) -> String:
    var lines: Array[String] = [
        "Volume: %.1f dB" % track.volume_db,
        "Mute: %s   Solo: %s" % [track.mute, track.solo],
    ]
    if track.adsr_enabled:
        lines.append("ADSR: attack %.2fs, decay %.2fs, sustain %.2f, release %.2fs" % [track.attack, track.decay, track.sustain, track.release])
    return "\n".join(lines)


func _format_clip_details(clip: SfxClip) -> String:
    var track_name := "None"
    if clip.track:
        var track_label := String(clip.track.track_name)
        track_name = track_label if not track_label.is_empty() else "Track %d" % (event.tracks.find(clip.track) + 1 if event else 0)
    var trigger_mode_name := "Timeline" if clip.trigger_mode == SfxClip.TriggerMode.TRIGGER_TIMELINE else "Sustain"
    var lines: Array[String] = [
        "Offset: %.2fs   Length: %.2fs" % [clip.offset, clip.length],
        "Stream offset: %.2fs" % clip.stream_offset,
        "Trigger mode: %s   Cut: %s" % [trigger_mode_name, clip.cut],
        "Track: %s" % track_name,
    ]
    return "\n".join(lines)


func _sync_scroll_content_size() -> bool:
    if not is_node_ready():
        return false
    var total_height := maxf(_timeline_table.get_combined_minimum_size().y, _timeline_table.size.y)
    var content_size := Vector2(0.0, total_height)
    if not (_scroll_content.custom_minimum_size == content_size):
        _scroll_content.custom_minimum_size = content_size
        return true
    return false


func _update_lane_cursors() -> void:
    for lane_index in range(_lane_views.size()):
        var lane := _lane_views[lane_index]
        var group: Dictionary = _lane_groups[lane_index]
        var clips: Array[SfxClip] = _get_lane_group_clips(group)

        for clip_index in range(clips.size()):
            var clip: SfxClip = clips[clip_index]
            var bar: WaveformPreview = lane.waveform.get_bar(clip_index)
            var clip_state: Dictionary = _clip_cursor_states.get(clip, {})
            var active := bool(clip_state.get("active", false))
            var position := float(clip_state.get("position", 0.0))

            var clip_start := _resolve_clip_start(clip)
            var clip_end := _resolve_clip_end(clip)
            var visible_range := _get_visible_range()
            var clipped_start := clampf(clip_start, float(visible_range["start"]), float(visible_range["end"]))
            var clipped_end := clampf(clip_end, float(visible_range["start"]), float(visible_range["end"]))
            var cursor_time := clip_start + position
            if not active or cursor_time < clipped_start or cursor_time > clipped_end or clipped_end <= clipped_start:
                bar.set_cursor_position(0.0, false)
                continue
            var ratio := (cursor_time - clipped_start) / maxf(clipped_end - clipped_start, 0.001)
            bar.set_cursor_position(ratio, true)


func _get_visible_range() -> Dictionary:
    var visible_span := maxf(_get_waveform_width() / maxf(pixels_per_second * _zoom, 1.0), 0.05)
    var clamped_start := _clamp_view_offset(_view_offset, visible_span)
    return {
        "start": clamped_start,
        "end": clamped_start + visible_span,
    }


func _zoom_bounds() -> Vector2:
    return Vector2(0.25, 32.0)


func _format_axis_label(visible_range: Dictionary) -> String:
    return "Time: %.2f -> %.2fs" % [visible_range["start"], visible_range["end"]]


func _format_ruler_label(value: float) -> String:
    return "%.2fs" % value


func _get_cursor_state() -> Dictionary:
    var cursor_visible := _time_cursor_visible or _manual_time_cursor_visible
    var axis_value := _time_cursor_value if _time_cursor_visible else _manual_time_cursor_value
    return {"visible": cursor_visible, "value": axis_value}


func _update_virtual_view_offset() -> void:
    if _scrollbar_drag_in_progress and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
        _scrollbar_drag_in_progress = false
    var visible_range := _get_visible_range()
    if _follow_cursor_enabled and not _scrollbar_drag_in_progress:
        var clamped_cursor := clampf(_time_cursor_value, 0.0, _axis_max)
        if _time_cursor_value <= _axis_max and clamped_cursor >= visible_range["end"]:
            _view_offset = clamped_cursor
    _view_offset = _clamp_view_offset(_view_offset)


func _resolve_clip_start(clip: SfxClip) -> float:
    return maxf(clip.offset, 0.0)


func _resolve_clip_end(clip: SfxClip) -> float:
    var visible_length := clip.length
    if visible_length <= 0.0:
        visible_length = _resolve_clip_stream_length(clip)
    if visible_length <= 0.0:
        visible_length = 0.35
    return maxf(clip.offset + visible_length, clip.offset + 0.05)


func _resolve_clip_stream_length(clip: SfxClip) -> float:
    if not clip.stream:
        return 0.0
    var stream_length := maxf(clip.stream.get_length(), 0.0) - maxf(clip.stream_offset, 0.0)
    return maxf(stream_length, 0.0)


func _sample_clip_curve(curve: Curve, axis_value: float, clip_start: float, clip_end: float, fade_out: bool) -> float:
    if not curve:
        return 1.0
    var local_time := maxf(axis_value - clip_start, 0.0)
    if not fade_out:
        return clampf(_sample_time_curve(curve, local_time), 0.0, 1.0)
    var remaining := maxf(clip_end - axis_value, 0.0)
    return clampf(_sample_time_fade_out_curve(curve, remaining), 0.0, 1.0)


func _sample_time_curve(curve: Curve, local_time: float) -> float:
    if not curve:
        return 1.0
    var sample_position := clampf(local_time, curve.min_domain, curve.max_domain)
    return curve.sample(sample_position)


func _sample_time_fade_out_curve(curve: Curve, remaining: float) -> float:
    if not curve:
        return 1.0
    var duration := _get_curve_duration(curve)
    if duration <= 0.0:
        return curve.sample(curve.max_domain)
    var clamped_remaining := clampf(remaining, 0.0, duration)
    var sample_position := curve.min_domain + (duration - clamped_remaining)
    return curve.sample(sample_position)


func _clamp_view_offset(value: float, visible_span := -1.0) -> float:
    if visible_span < 0.0:
        var current_visible_range := _get_visible_range()
        visible_span = maxf(float(current_visible_range["end"]) - float(current_visible_range["start"]), 0.05)
    return clampf(value, 0.0, _get_max_view_offset(visible_span))


func _get_max_view_offset(visible_span: float) -> float:
    return maxf(_axis_max - maxf(visible_span, 0.05), 0.0)
