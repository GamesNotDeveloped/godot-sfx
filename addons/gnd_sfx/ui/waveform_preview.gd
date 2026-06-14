extends Control
class_name WaveformPreview

@export var fill_color := Color("2f6fb8")
@export var line_color := Color("8fd3ff")
@export var synthetic_line_color := Color("b8ecff")
@export var center_line_color := Color(1.0, 1.0, 1.0, 0.12)
@export var border_color := Color(1.0, 1.0, 1.0, 0.18)
@export var border_width := 1.0
@export var selection_border_color := Color(1.0, 0.831373, 0.117647, 1.0)
@export var selection_border_width := 2.0
@export var cursor_color := Color("fff4a3")
@export var cursor_width := 2.0
@export var fade_in_color := Color("8cffb0")
@export var fade_out_color := Color("ffb885")
@export var name_strip_color := Color("3a4a5c")
@export var name_strip_text_color := Color(1.0, 1.0, 1.0, 0.92)
@export var name_strip_height := 14.0

var _mins := PackedFloat32Array()
var _maxs := PackedFloat32Array()
var _cursor_visible := false
var _cursor_ratio := 0.0
var _sample_window_start := 0.0
var _sample_window_end := 1.0
var _preview_kind := "empty"
var _preview_label := ""
var _preview_duration := 0.0
var _fade_lines: Array[Dictionary] = []
var _clip_name := ""
var selected := false:
    set(value):
        if selected == value:
            return
        selected = value
        queue_redraw()


func set_waveform_preview(preview: Dictionary) -> void:
    var mins: PackedFloat32Array = preview.get("mins", PackedFloat32Array())
    var maxs: PackedFloat32Array = preview.get("maxs", PackedFloat32Array())
    var preview_kind := String(preview.get("kind", "empty"))
    var preview_label := String(preview.get("label", ""))
    var preview_duration := maxf(float(preview.get("duration", 0.0)), 0.0)
    if _mins == mins and _maxs == maxs and _preview_kind == preview_kind and _preview_label == preview_label and is_equal_approx(_preview_duration, preview_duration):
        return
    _mins = mins
    _maxs = maxs
    _preview_kind = preview_kind
    _preview_label = preview_label
    _preview_duration = preview_duration
    queue_redraw()


func set_waveform_window(start_ratio: float, end_ratio: float) -> void:
    var sample_window_start := clampf(start_ratio, 0.0, 1.0)
    var sample_window_end := clampf(maxf(end_ratio, sample_window_start + 0.0001), 0.0, 1.0)
    if is_equal_approx(_sample_window_start, sample_window_start) and is_equal_approx(_sample_window_end, sample_window_end):
        return
    _sample_window_start = sample_window_start
    _sample_window_end = sample_window_end
    queue_redraw()


func set_cursor_position(normalized_ratio: float, visible: bool) -> void:
    var cursor_ratio := clampf(normalized_ratio, 0.0, 1.0)
    if _cursor_visible == visible and is_equal_approx(_cursor_ratio, cursor_ratio):
        return
    _cursor_visible = visible
    _cursor_ratio = cursor_ratio
    queue_redraw()


func set_fade_overlay_lines(lines: Array[Dictionary]) -> void:
    if _fade_lines == lines:
        return
    _fade_lines = lines
    queue_redraw()


func set_clip_name(clip_name: String) -> void:
    if _clip_name == clip_name:
        return
    _clip_name = clip_name
    queue_redraw()


func get_preview_duration() -> float:
    return _preview_duration


func _draw() -> void:
    var full_rect := Rect2(Vector2.ZERO, size)
    if full_rect.size.x <= 0.0 or full_rect.size.y <= 0.0:
        return

    var strip_height := minf(name_strip_height, full_rect.size.y) if _clip_name else 0.0
    var content_rect := Rect2(Vector2(0.0, strip_height), Vector2(full_rect.size.x, full_rect.size.y - strip_height))

    draw_rect(content_rect, fill_color, true)

    var center_y := content_rect.position.y + content_rect.size.y * 0.5
    draw_line(Vector2(0.0, center_y), Vector2(content_rect.size.x, center_y), center_line_color, 1.0)

    _draw_waveform_envelope(content_rect)
    _draw_fade_lines()

    if _cursor_visible:
        var cursor_x := _cursor_ratio * content_rect.size.x
        draw_line(Vector2(cursor_x, content_rect.position.y), Vector2(cursor_x, content_rect.position.y + content_rect.size.y), cursor_color, cursor_width)

    if _preview_label:
        var font: Font = get_theme_default_font()
        var font_size := maxi(get_theme_default_font_size() - 2, 10)
        if font:
            draw_string(
                font,
                Vector2(6.0, content_rect.position.y + content_rect.size.y - 7.0),
                _preview_label,
                HORIZONTAL_ALIGNMENT_LEFT,
                -1.0,
                font_size,
                Color(1.0, 1.0, 1.0, 0.56)
            )

    if strip_height > 0.0:
        _draw_name_strip(full_rect, strip_height)

    if selected:
        draw_rect(full_rect, selection_border_color, false, selection_border_width)
    else:
        draw_rect(full_rect, border_color, false, border_width)


func _draw_name_strip(rect: Rect2, strip_height: float) -> void:
    var strip_rect := Rect2(rect.position, Vector2(rect.size.x, strip_height))
    draw_rect(strip_rect, name_strip_color, true)
    var font: Font = get_theme_default_font()
    if not font:
        return
    var font_size := maxi(get_theme_default_font_size() - 3, 9)
    draw_string(
        font,
        Vector2(4.0, strip_height - 3.0),
        _clip_name,
        HORIZONTAL_ALIGNMENT_LEFT,
        rect.size.x - 6.0,
        font_size,
        name_strip_text_color
    )


func _draw_waveform_envelope(rect: Rect2) -> void:
    if not _mins or not _maxs:
        return
    var envelope_color := synthetic_line_color if not (_preview_kind == "file") else line_color
    var polygon := _build_waveform_polygon(rect)
    if polygon.size() >= 3:
        draw_colored_polygon(polygon, envelope_color)


func _draw_fade_lines() -> void:
    for line_data in _fade_lines:
        var points: PackedVector2Array = line_data.get("points", PackedVector2Array())
        if points.size() < 2:
            continue
        var color: Color = line_data.get("color", fade_in_color)
        draw_polyline(points, color, 1.5, true)


func _build_waveform_polygon(rect: Rect2) -> PackedVector2Array:
    var polygon := PackedVector2Array()
    var point_count := clampi(int(round(rect.size.x)), 24, 256)
    if point_count < 2:
        return polygon

    polygon.resize(point_count * 2)
    var center_y := rect.position.y + rect.size.y * 0.5
    var amplitude := rect.size.y * 0.42
    for index in range(point_count):
        var ratio := float(index) / maxf(point_count - 1, 1.0)
        var sample_ratio := lerpf(_sample_window_start, _sample_window_end, ratio)
        var min_value := clampf(WaveformPreviewCache.sample_envelope_array(_mins, sample_ratio), -1.0, 1.0)
        var max_value := clampf(WaveformPreviewCache.sample_envelope_array(_maxs, sample_ratio), -1.0, 1.0)
        var x := rect.position.x + ratio * rect.size.x
        polygon[index] = Vector2(x, center_y - (max_value * amplitude))
        polygon[(point_count * 2) - 1 - index] = Vector2(x, center_y - (min_value * amplitude))
    return polygon
