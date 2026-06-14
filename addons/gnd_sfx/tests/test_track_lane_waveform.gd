extends GutTest

const TrackLaneWaveformScene := preload("res://addons/gnd_sfx/ui/track_lane_waveform.tscn")


func test_waveform_window_uses_stream_offset_and_visible_segment() -> void:
    var clip := SfxClip.new()
    clip.stream_offset = 2.0

    var waveform: TrackLaneWaveform = TrackLaneWaveformScene.instantiate()
    var window := waveform.resolve_waveform_window(clip, 10.0, 4.0, 5.0, 7.5)
    waveform.queue_free()

    assert_almost_eq(window["start_ratio"], 0.3, 0.0001, "Preview should start at stream_offset plus visible clip offset")
    assert_almost_eq(window["end_ratio"], 0.55, 0.0001, "Preview should end at the clipped segment within the source stream")
