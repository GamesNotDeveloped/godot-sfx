extends Control
class_name TrackLaneWaveform

const BarScene := preload("./waveform_preview.tscn")

@onready var global_cursor: ColorRect = $GlobalCursor
@onready var _bar_template: WaveformPreview = $Bar

var bars: Array[WaveformPreview] = [_bar_template]


func _ready() -> void:
    bars = [_bar_template]


func get_bar(index: int) -> WaveformPreview:
    return bars[index]


func hide_cursor() -> void:
    global_cursor.visible = false


func ensure_bar_count(count: int) -> void:
    var target := maxi(count, 1)
    while bars.size() < target:
        var bar: WaveformPreview = BarScene.instantiate()
        add_child(bar)
        bars.append(bar)
    while bars.size() > target:
        bars.pop_back().queue_free()
    _bar_template.visible = count > 0
    if is_instance_valid(global_cursor):
        move_child(global_cursor, -1)


func resolve_waveform_window(clip: SfxClip, preview_duration: float, clip_start: float, clipped_start: float, clipped_end: float) -> Dictionary:
    var source_duration := maxf(preview_duration, 0.0)
    if source_duration <= 0.0 and clip and clip.stream:
        source_duration = maxf(clip.stream.get_length(), 0.0)
    if source_duration <= 0.0:
        return {
            "start_ratio": 0.0,
            "end_ratio": 1.0,
        }

    var local_visible_start := maxf(clip.stream_offset, 0.0) + maxf(clipped_start - clip_start, 0.0)
    var local_visible_end := maxf(clip.stream_offset, 0.0) + maxf(clipped_end - clip_start, 0.0)
    return {
        "start_ratio": clampf(local_visible_start / source_duration, 0.0, 1.0),
        "end_ratio": clampf(local_visible_end / source_duration, 0.0, 1.0),
    }


func build_fade_overlay_lines(clip: SfxClip, clipped_start: float, clipped_end: float, bar_size: Vector2, sampler: Callable) -> Array[Dictionary]:
    var lines: Array[Dictionary] = []
    if clip == null or bar_size.x <= 1.0 or bar_size.y <= 1.0:
        return lines
    if clip.fade_in_curve:
        var fade_in_points := build_curve_overlay_points(clip.fade_in_curve, clipped_start, clipped_end, bar_size, false, sampler)
        if fade_in_points.size() >= 2:
            lines.append({"points": fade_in_points, "color": Color("8cffb0")})
    if clip.fade_out_curve:
        var fade_out_points := build_curve_overlay_points(clip.fade_out_curve, clipped_start, clipped_end, bar_size, true, sampler)
        if fade_out_points.size() >= 2:
            lines.append({"points": fade_out_points, "color": Color("ffb885")})
    return lines


func build_curve_overlay_points(curve: Curve, clipped_start: float, clipped_end: float, bar_size: Vector2, fade_out: bool, sampler: Callable) -> PackedVector2Array:
    var points := PackedVector2Array()
    if curve == null or clipped_end <= clipped_start:
        return points
    var sample_count := clampi(int(round(bar_size.x / 5.0)), 12, 64)
    points.resize(sample_count)
    for index in range(sample_count):
        var t := float(index) / maxf(sample_count - 1, 1.0)
        var axis_value := lerpf(clipped_start, clipped_end, t)
        var normalized_value: float = sampler.call(curve, axis_value, fade_out)
        var x := t * bar_size.x
        var y := (1.0 - normalized_value) * (bar_size.y - 1.0)
        points[index] = Vector2(x, y)
    return points
