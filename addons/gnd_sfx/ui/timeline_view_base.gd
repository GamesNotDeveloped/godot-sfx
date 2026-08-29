extends PanelContainer
class_name TimelineViewBase

## Shared ruler/zoom/scroll-navigation for TimelineView (time axis) and
## AutomationTimelineView (parameter-domain axis). Subclasses declare
## `_zoom`/`_view_offset` fields and override the axis-specific hooks below;
## everything else (ruler drawing, scrollbar wiring, zoom buttons) lives here.

const TrackLaneViewScene := preload("./track_lane_view.tscn")

signal axis_value_selected(value: float)

@export var title := ""
@export var empty_message := ""
@export var lane_height := 52.0
@export var label_column_width := 220.0
@export var global_cursor_width := 2.0
@export var zoom_step := 1.25
@export var ruler_tick_color := Color(1.0, 1.0, 1.0, 0.28)
@export var ruler_text_color := Color(0.78, 0.84, 0.92, 1.0)
@export var ruler_cursor_color := Color(1.0, 0.956863, 0.639216, 0.95)

var _zoom := 1.0
var _view_offset := 0.0
var _clip_cursor_states := {}
var _updating_scrollbar := false
var _scrollbar_drag_in_progress := false
var _layout_refresh_queued := false
var _lane_views: Array[TrackLaneView] = []

@onready var _title_label: Label = $Margin/VBox/HeaderRow/HeaderBox/TitleLabel
@onready var _axis_label: Label = $Margin/VBox/HeaderRow/HeaderBox/AxisLabel
@onready var _ruler: Control = $Margin/VBox/HeaderRow/HeaderBox/Ruler
@onready var _header_spacer: Control = $Margin/VBox/HeaderRow/HeaderSpacer
@onready var _empty_label: Label = $Margin/VBox/EmptyLabel
@onready var _scroll: ScrollContainer = $Margin/VBox/Scroll
@onready var _scroll_content: Control = $Margin/VBox/Scroll/ScrollContent
@onready var _timeline_table: VBoxContainer = $Margin/VBox/Scroll/ScrollContent/TimelineTable
@onready var _nav_row: HBoxContainer = $Margin/VBox/NavRow
@onready var _view_scrollbar: HScrollBar = $Margin/VBox/NavRow/ViewScrollbar
@onready var _zoom_out_button: Button = $Margin/VBox/NavRow/ZoomOutButton
@onready var _zoom_in_button: Button = $Margin/VBox/NavRow/ZoomInButton
@onready var _zoom_reset_button: Button = $Margin/VBox/NavRow/ZoomResetButton


func _ready() -> void:
    # Connected in code, not in .tscn: this base is shared by two scenes
    # (timeline_view.tscn, automation_timeline_view.tscn), so wiring here
    # keeps a single source of truth instead of duplicating 10 connections
    # in both files.
    _sync_header_width()
    _ruler.draw.connect(_draw_ruler)
    _ruler.gui_input.connect(_on_ruler_gui_input)
    _ruler.resized.connect(_queue_layout_refresh)
    _scroll.resized.connect(_queue_layout_refresh)
    _timeline_table.resized.connect(_queue_layout_refresh)
    _view_scrollbar.value_changed.connect(_on_view_scrollbar_value_changed)
    _view_scrollbar.gui_input.connect(_on_view_scrollbar_gui_input)
    _zoom_out_button.pressed.connect(zoom_out_view)
    _zoom_in_button.pressed.connect(zoom_in_view)
    _zoom_reset_button.pressed.connect(reset_view_navigation)
    _on_ready_finished()


func _notification(what: int) -> void:
    if what == NOTIFICATION_RESIZED:
        _queue_layout_refresh()
    elif what == NOTIFICATION_WM_MOUSE_EXIT:
        if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
            _scrollbar_drag_in_progress = false


func zoom_in_view() -> void:
    _set_zoom(_zoom * zoom_step)


func zoom_out_view() -> void:
    _set_zoom(_zoom / maxf(zoom_step, 1.01))


func reset_view_navigation() -> void:
    _zoom = 1.0
    _view_offset = 0.0
    _refresh_labels()
    _queue_layout_refresh()


func _set_zoom(value: float) -> void:
    var bounds := _zoom_bounds()
    _zoom = clampf(value, bounds.x, bounds.y)
    _view_offset = _clamp_view_offset(_view_offset)
    _refresh_labels()
    _queue_layout_refresh()


func _zoom_bounds() -> Vector2:
    return Vector2(1.0, 32.0)


func _refresh_labels() -> void:
    if not is_node_ready():
        return
    _title_label.text = title
    var visible_range := _get_visible_range()
    _axis_label.text = _format_axis_label(visible_range)
    if is_instance_valid(_ruler):
        _ruler.queue_redraw()


func _queue_layout_refresh() -> void:
    if not is_node_ready() or _layout_refresh_queued:
        return
    _layout_refresh_queued = true
    call_deferred("_run_layout_refresh")


func _run_layout_refresh() -> void:
    _layout_refresh_queued = false
    _flush_layout_refresh()


func _assign_waveform_preview(bar: WaveformPreview, clip: SfxClip) -> void:
    var preview: Dictionary = await WaveformPreviewCache.get_clip_preview(clip)
    if is_instance_valid(bar):
        bar.set_waveform_preview(preview)


func _get_waveform_width() -> float:
    if not _lane_views.is_empty():
        var first_canvas: Control = _lane_views[0].waveform
        return maxf(first_canvas.size.x, 1.0)
    if is_instance_valid(_ruler):
        return maxf(_ruler.size.x, 1.0)
    return maxf(_scroll.size.x - label_column_width, 1.0)


func _axis_value_to_ratio(value: float, visible_range: Dictionary) -> float:
    return (value - float(visible_range["start"])) / maxf(float(visible_range["end"]) - float(visible_range["start"]), 0.001)


func _axis_ratio_to_value(ratio: float, visible_range: Dictionary) -> float:
    return float(visible_range["start"]) + clampf(ratio, 0.0, 1.0) * maxf(float(visible_range["end"]) - float(visible_range["start"]), 0.0)


func _emit_axis_value_at_ratio(ratio: float) -> void:
    axis_value_selected.emit(_axis_ratio_to_value(ratio, _get_visible_range()))


func _update_lane_cursors() -> void:
    pass


func _update_global_cursor() -> void:
    if not is_node_ready():
        return
    _hide_global_cursors()
    if is_instance_valid(_ruler):
        _ruler.queue_redraw()


func _draw_ruler() -> void:
    if not is_node_ready():
        return
    var rect := Rect2(Vector2.ZERO, _ruler.size)
    if rect.size.x <= 0.0 or rect.size.y <= 0.0:
        return

    var wave_start := 0.0
    var wave_width := maxf(_ruler.size.x, 1.0)
    var base_y: float = rect.size.y - 6.0
    _ruler.draw_line(Vector2(wave_start, base_y), Vector2(wave_start + wave_width, base_y), ruler_tick_color, 1.0)

    var visible_range := _get_visible_range()
    var range_start := float(visible_range["start"])
    var range_end := float(visible_range["end"])
    var step: float = _choose_ruler_step(maxf(range_end - range_start, 0.001), wave_width)
    var first_tick: float = ceil(range_start / step) * step
    var font: Font = _ruler.get_theme_default_font()
    var font_size: int = maxi(_ruler.get_theme_default_font_size() - 1, 10)
    var tick_index := 0
    var tick_value: float = first_tick
    while tick_value <= range_end + (step * 0.5):
        var ratio: float = _axis_value_to_ratio(tick_value, visible_range)
        var x: float = wave_start + ratio * wave_width
        var tick_height: float = 7.0 if tick_index % 2 == 0 else 4.0
        _ruler.draw_line(Vector2(x, base_y - tick_height), Vector2(x, base_y), ruler_tick_color, 1.0)
        if font and tick_index % 2 == 0:
            _ruler.draw_string(font, Vector2(x - 10.0, base_y - 10.0), _format_ruler_label(tick_value), HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, ruler_text_color)
        tick_index += 1
        tick_value += step

    var cursor_state := _get_cursor_state()
    if bool(cursor_state["visible"]) and not _lane_views.is_empty():
        var ratio := _axis_value_to_ratio(float(cursor_state["value"]), visible_range)
        if ratio >= 0.0 and ratio <= 1.0:
            var x := wave_start + (ratio * wave_width)
            _ruler.draw_line(Vector2(x, 0.0), Vector2(x, rect.size.y), ruler_cursor_color, global_cursor_width)


func _choose_ruler_step(axis_span: float, pixel_width: float) -> float:
    var target_ticks: float = maxf(pixel_width / 90.0, 2.0)
    var rough_step: float = axis_span / target_ticks
    var bases: Array[float] = [1.0, 2.0, 5.0]
    var magnitude: float = pow(10.0, floor(log(maxf(rough_step, 0.0001)) / log(10.0)))
    for factor in bases:
        var candidate: float = factor * magnitude
        if candidate >= rough_step:
            return candidate
    return 10.0 * magnitude


func _sync_header_width() -> void:
    if is_instance_valid(_header_spacer):
        _header_spacer.custom_minimum_size.x = label_column_width


func _clear_track_cells() -> void:
    while _timeline_table.get_child_count() > 0:
        var child := _timeline_table.get_child(_timeline_table.get_child_count() - 1)
        _timeline_table.remove_child(child)
        child.queue_free()


func _hide_global_cursors() -> void:
    for lane in _lane_views:
        lane.waveform.hide_cursor()


func _get_curve_duration(curve: Curve) -> float:
    if curve == null:
        return 0.0
    return maxf(curve.max_domain - curve.min_domain, 0.0)


func _refresh_navigation_visibility() -> void:
    if not is_instance_valid(_nav_row):
        return
    _nav_row.visible = true


func _refresh_navigation_controls() -> void:
    if not is_instance_valid(_view_scrollbar):
        return
    _nav_row.visible = true
    var visible_range := _get_visible_range()
    var visible_span := maxf(float(visible_range["end"]) - float(visible_range["start"]), 0.001)
    var max_offset := _get_max_view_offset(visible_span)
    _updating_scrollbar = true
    _view_scrollbar.min_value = 0.0
    _view_scrollbar.max_value = maxf(max_offset + visible_span, visible_span)
    _view_scrollbar.page = visible_span
    _view_scrollbar.value = _clamp_view_offset(_view_offset, visible_span)
    _view_scrollbar.mouse_filter = Control.MOUSE_FILTER_STOP if max_offset > 0.0001 else Control.MOUSE_FILTER_IGNORE
    _view_scrollbar.modulate = Color(1.0, 1.0, 1.0, 1.0) if max_offset > 0.0001 else Color(1.0, 1.0, 1.0, 0.45)
    _zoom_reset_button.disabled = is_equal_approx(_zoom, 1.0) and is_equal_approx(_view_offset, 0.0)
    _updating_scrollbar = false


func _on_view_scrollbar_value_changed(value: float) -> void:
    if _updating_scrollbar:
        return
    _view_offset = _clamp_view_offset(value)
    _refresh_labels()
    _queue_layout_refresh()


func _on_view_scrollbar_gui_input(event: InputEvent) -> void:
    if not (event is InputEventMouseButton):
        return
    var mouse_event := event as InputEventMouseButton
    if not (mouse_event.button_index == MOUSE_BUTTON_LEFT):
        return
    _scrollbar_drag_in_progress = mouse_event.pressed


func _on_ruler_gui_input(event: InputEvent) -> void:
    var button_event := event as InputEventMouseButton
    if not (button_event and button_event.button_index == MOUSE_BUTTON_LEFT and button_event.pressed):
        return
    var wave_width := maxf(_ruler.size.x, 1.0)
    if event.position.x < 0.0 or event.position.x > wave_width:
        return
    _emit_axis_value_at_ratio(clampf(event.position.x / wave_width, 0.0, 1.0))


# --- axis-specific hooks implemented by TimelineView / AutomationTimelineView ---

func _on_ready_finished() -> void:
    pass


func _get_visible_range() -> Dictionary:
    return {"start": 0.0, "end": 1.0}


func _clamp_view_offset(value: float, _visible_span := -1.0) -> float:
    return value


func _get_max_view_offset(_visible_span: float) -> float:
    return 0.0


func _flush_layout_refresh() -> void:
    pass


func _format_ruler_label(value: float) -> String:
    return "%.2f" % value


func _format_axis_label(_visible_range: Dictionary) -> String:
    return ""


func _get_cursor_state() -> Dictionary:
    return {"visible": false, "value": 0.0}
