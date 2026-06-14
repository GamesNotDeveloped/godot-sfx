extends GutTest

const TimelineViewScene := preload("res://addons/gnd_sfx/ui/timeline_view.tscn")


func test_timeline_layout_stabilizes_when_tracks_overflow_scroll_view() -> void:
    var timeline: TimelineView = TimelineViewScene.instantiate()
    timeline.custom_minimum_size = Vector2.ZERO
    timeline.size = Vector2(640.0, 520.0)
    add_child(timeline)

    var event := SfxEvent.new()
    var tracks: Array[SfxTrack] = []
    var clips: Array[SfxClip] = []
    for index in range(14):
        var track := SfxTrack.new()
        var clip := SfxClip.new()
        clip.offset = float(index) * 0.1
        clip.length = 0.5
        clip.track = track
        tracks.append(track)
        clips.append(clip)
    event.tracks = tracks
    event.clips = clips
    timeline.event = event
    await _wait_frames(3)

    timeline.size = Vector2(640.0, 180.0)
    await _wait_frames(3)

    var scroll_content: Control = timeline.get_node("Margin/VBox/Scroll/ScrollContent")
    var timeline_table: VBoxContainer = timeline.get_node("Margin/VBox/Scroll/ScrollContent/TimelineTable")
    var first_lane: TrackLaneView = timeline_table.get_child(0)
    var first_canvas: Control = first_lane.waveform
    var expected_height := maxf(timeline_table.get_combined_minimum_size().y, timeline_table.size.y)
    var initial_content_height := scroll_content.custom_minimum_size.y
    var initial_canvas_width := first_canvas.size.x

    await _wait_frames(4)

    assert_gt(scroll_content.custom_minimum_size.y, timeline.size.y, "Track stack should overflow the reduced viewport height")
    assert_almost_eq(scroll_content.custom_minimum_size.y, expected_height, 0.001, "Scroll content height should match the lane stack height")
    assert_almost_eq(scroll_content.custom_minimum_size.y, initial_content_height, 0.001, "Overflow layout should stabilize after the resize")
    assert_gt(first_canvas.size.x, 1.0, "Lane canvas should keep a usable width after overflow")
    assert_almost_eq(first_canvas.size.x, initial_canvas_width, 0.001, "Lane canvas width should stop oscillating once overflow settles")

    timeline.queue_free()
    await _wait_frames(1)


func _wait_frames(frame_count: int) -> void:
    for _index in range(frame_count):
        await get_tree().process_frame
