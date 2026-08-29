extends GutTest

var runtime: SfxPlaybackRuntime
var players: Array = []


func before_each() -> void:
    runtime = SfxPlaybackRuntime.new()
    players = []
    for _i in range(4):
        var player := AudioStreamPlayer.new()
        players.append(player)
        add_child_autoqfree(player)
    runtime.set_players(players)


func after_each() -> void:
    runtime.clear()
    players.clear()


func _make_local_runtime(player_count: int) -> SfxPlaybackRuntime:
    var local_runtime := SfxPlaybackRuntime.new()
    var local_players: Array = []
    for _i in range(player_count):
        var player := AudioStreamPlayer.new()
        local_players.append(player)
        add_child_autoqfree(player)
    local_runtime.set_players(local_players)
    return local_runtime


func test_time_offset_track_starts_only_after_threshold() -> void:
    var event := SfxEvent.new()
    event.name = &"timed"
    event.clips = [_make_clip(0.5)]

    runtime.play(event)
    assert_eq(runtime._active_voices.size(), 0, "Clip should not start before crossing time offset")

    runtime.update(0.6)
    assert_eq(runtime._active_voices.size(), 1, "Clip should start after time threshold is crossed")


func test_seek_rebuilds_event_tracks_for_new_offset() -> void:
    var event := SfxEvent.new()
    event.name = &"seekable"
    event.clips = [_make_clip(1.0)]

    runtime.play(event)
    assert_eq(runtime._active_voices.size(), 0)

    runtime.seek(event.name, 1.1)
    assert_eq(runtime._active_voices.size(), 1, "Seek should activate clips whose offset is already behind playback time")


func test_stream_offset_is_separate_from_timeline_offset() -> void:
    var event := SfxEvent.new()
    event.name = &"stream_offset"
    var clip := _make_clip(1.0)
    clip.stream_offset = 0.25
    event.clips = [clip]

    runtime.play(event, 1.5)
    assert_eq(runtime._active_voices.size(), 1)

    var start_position := runtime._resolve_voice_start_position(runtime._get_latest_instance(event.name), clip)
    assert_eq(start_position, 0.75, "Time clips should add elapsed event time on top of stream_offset")


func test_time_track_length_limits_playback_segment() -> void:
    var event := SfxEvent.new()
    event.name = &"time_length"
    var clip := _make_clip(0.0, 25.0)
    clip.stream_offset = 14.0
    clip.length = 4.0
    clip.fade_out_curve = _make_linear_curve(0.0, 4.0, 1.0, 0.0)
    event.clips = [clip]

    runtime.play(event)
    var voice: SfxPlaybackRuntime.ActiveVoice = runtime._active_voices[0]

    assert_eq(voice.stream_end_position, 18.0, "Clip length should cap playback at stream_offset + length")
    assert_eq(runtime._resolve_remaining_clip_time(voice, 14.0), 4.0, "Remaining time should be measured against the shortened segment")
    assert_eq(runtime._sample_time_fade_out_curve(clip.fade_out_curve, 4.0), 1.0, "Fade-out should start at the beginning of the shortened tail")
    assert_eq(runtime._sample_time_fade_out_curve(clip.fade_out_curve, 0.0), 0.0, "Fade-out should end at silence at the shortened segment end")


func test_time_track_curves_use_local_time_and_remaining_time() -> void:
    var event := SfxEvent.new()
    event.name = &"curve_domains"
    var clip := _make_clip(0.0, 25.0)
    clip.stream_offset = 14.0
    clip.fade_in_curve = _make_linear_curve(0.0, 4.0, 0.0, 1.0)
    clip.fade_out_curve = _make_linear_curve(0.0, 4.0, 1.0, 0.0)
    event.clips = [clip]

    runtime.play(event)
    var voice: SfxPlaybackRuntime.ActiveVoice = runtime._active_voices[0]

    assert_eq(runtime._resolve_local_clip_time(voice, voice.stream_start_position), 0.0, "Fade-in domain should start at local clip time")
    assert_eq(runtime._resolve_remaining_clip_time(voice, voice.stream.get_length() - 4.0), 4.0, "Fade-out domain should count remaining playback time")
    assert_eq(runtime._sample_time_fade_out_curve(clip.fade_out_curve, 4.0), 1.0, "Fade-out should stay at full gain when four seconds remain")
    assert_eq(runtime._sample_time_fade_out_curve(clip.fade_out_curve, 0.0), 0.0, "Fade-out should reach silence at the end of playback")


func test_time_track_fade_out_curve_does_not_require_reversed_shape() -> void:
    var clip := _make_clip(0.0, 25.0)
    clip.stream_offset = 14.0
    clip.fade_out_curve = _make_linear_curve(0.0, 4.0, 1.0, 0.0)

    assert_eq(clip.stream.get_length(), 25.0)
    assert_eq(runtime._sample_time_fade_out_curve(clip.fade_out_curve, 11.0), 1.0, "Playback should start audible before the last four seconds")
    assert_eq(runtime._sample_time_fade_out_curve(clip.fade_out_curve, 4.0), 1.0, "Fade-out should start when four seconds remain")
    assert_eq(runtime._sample_time_fade_out_curve(clip.fade_out_curve, 2.0), 0.5, "Fade-out should interpolate naturally toward the end")
    assert_eq(runtime._sample_time_fade_out_curve(clip.fade_out_curve, 0.0), 0.0, "Fade-out should end at silence")


func test_automation_tracks_start_after_parameter_threshold_crossing() -> void:
    var event := SfxEvent.new()
    event.name = &"engine"
    event.automations = [_make_automation(&"rpm", 0.0, 1000.0, 500.0)]

    runtime.play(event, 0.0, {"rpm": 250.0})
    assert_eq(runtime._active_voices.size(), 0, "Automation clip should not start below offset threshold")

    runtime.modulate(event.name, {"rpm": 750.0})
    assert_eq(runtime._active_voices.size(), 1, "Automation clip should start after threshold crossing")


func test_automation_track_stops_after_parameter_leaves_track_range() -> void:
    var event := SfxEvent.new()
    event.name = &"automation_range_stop"
    var automation := _make_automation(&"rpm", 0.0, 1000.0, 500.0)
    var clip: SfxClip = automation.clips[0]
    clip.length = 100.0
    clip.cut = true
    event.automations = [automation]

    runtime.play(event, 0.0, {"rpm": 550.0})
    assert_eq(runtime._active_voices.size(), 1, "Automation clip should start while the parameter is inside its range")

    runtime.modulate(event.name, {"rpm": 650.0})
    assert_eq(runtime._active_voices.size(), 0, "Automation clip should stop once the parameter leaves offset + length")


func test_automation_track_uses_track_adsr_release_after_leaving_range() -> void:
    var event := SfxEvent.new()
    event.name = &"automation_range_release"
    var automation := _make_automation(&"rpm", 0.0, 1000.0, 500.0)
    var clip: SfxClip = automation.clips[0]
    clip.length = 100.0
    clip.cut = true
    var mixer_track := SfxTrack.new()
    mixer_track.adsr_enabled = true
    mixer_track.release = 0.2
    clip.track = mixer_track
    event.automations = [automation]

    runtime.play(event, 0.0, {"rpm": 550.0})
    assert_eq(runtime._active_voices.size(), 1)

    runtime.modulate(event.name, {"rpm": 650.0})
    assert_eq(runtime._active_voices.size(), 1, "Track ADSR release should keep the automation voice alive briefly")
    assert_eq(runtime._active_voices[0].track_adsr.stage, SfxPlaybackRuntime.AdsrStage.RELEASE, "Leaving range should begin track ADSR release")

    runtime.update(0.25)
    assert_eq(runtime._active_voices.size(), 0, "Automation voice should be removed after track ADSR release finishes")


func test_automation_track_retriggers_after_reentering_range() -> void:
    var event := SfxEvent.new()
    event.name = &"automation_range_reentry"
    var automation := _make_automation(&"rpm", 0.0, 1000.0, 500.0)
    var clip: SfxClip = automation.clips[0]
    clip.length = 100.0
    clip.cut = true
    var mixer_track := SfxTrack.new()
    mixer_track.adsr_enabled = true
    mixer_track.attack = 0.1
    mixer_track.release = 0.2
    clip.track = mixer_track
    event.automations = [automation]

    runtime.play(event, 0.0, {"rpm": 550.0})
    assert_eq(runtime._active_voices.size(), 1)
    var voice: SfxPlaybackRuntime.ActiveVoice = runtime._active_voices[0]
    runtime.update(0.2)

    runtime.modulate(event.name, {"rpm": 650.0})
    assert_eq(runtime._active_voices.size(), 1)
    assert_eq(voice.track_adsr.stage, SfxPlaybackRuntime.AdsrStage.RELEASE, "Leaving range should release the existing voice")

    runtime.modulate(event.name, {"rpm": 550.0})
    assert_eq(runtime._active_voices.size(), 1, "Re-entering range should reuse the releasing voice instead of duplicating it")
    assert_eq(runtime._active_voices[0], voice, "Re-entry should restart the existing releasing voice")
    assert_eq(voice.track_adsr.stage, SfxPlaybackRuntime.AdsrStage.ATTACK, "Re-entry should restart track ADSR")


func test_automation_track_without_cut_finishes_sample_after_leaving_range() -> void:
    var event := SfxEvent.new()
    event.name = &"automation_range_tail"
    var automation := _make_automation(&"rpm", 0.0, 1000.0, 500.0)
    var clip: SfxClip = automation.clips[0]
    clip.length = 100.0
    clip.cut = false
    event.automations = [automation]

    runtime.play(event, 0.0, {"rpm": 550.0})
    var voice: SfxPlaybackRuntime.ActiveVoice = runtime._active_voices[0]

    runtime.modulate(event.name, {"rpm": 650.0})
    assert_eq(runtime._active_voices.size(), 1, "Non-cut automation voice should stay alive after leaving range")
    assert_true(voice.finish_on_end, "Non-cut automation voice should finish at sample end")
    assert_eq(voice.track_adsr.stage, SfxPlaybackRuntime.AdsrStage.SUSTAIN, "Non-cut automation voice should not enter track ADSR release")

    voice.player.stop()
    runtime.handle_player_finished(voice.player)
    assert_eq(runtime._active_voices.size(), 0, "Non-cut automation voice should disappear after the sample finishes")


func _start_non_cut_automation_voice(event_name: StringName) -> Dictionary:
    var event := SfxEvent.new()
    event.name = event_name
    var automation := _make_automation(&"rpm", 0.0, 1000.0, 500.0)
    var clip: SfxClip = automation.clips[0]
    clip.stream = _make_test_wav(0.5, true)
    clip.length = 100.0
    clip.cut = false
    event.automations = [automation]

    runtime.play(event, 0.0, {"rpm": 550.0})
    var voice: SfxPlaybackRuntime.ActiveVoice = runtime._active_voices[0]
    return {"event": event, "clip": clip, "voice": voice}


func test_automation_track_without_cut_disables_loop_on_voice_copy_only() -> void:
    var fixture := _start_non_cut_automation_voice(&"automation_loop_tail")
    var clip: SfxClip = fixture["clip"]
    var voice: SfxPlaybackRuntime.ActiveVoice = fixture["voice"]
    var event: SfxEvent = fixture["event"]
    assert_true(SfxStreamLoopSupport.is_looping(clip.stream), "Original stream should keep its loop")

    runtime.modulate(event.name, {"rpm": 650.0})
    assert_false(SfxStreamLoopSupport.is_looping(voice.stream), "Draining voice copy should not loop")
    assert_eq(voice.player.stream, voice.stream, "Active player should use the non-looping drain stream")
    assert_true(SfxStreamLoopSupport.is_looping(clip.stream), "Disabling drain loop should not mutate the clip stream")


func test_automation_track_without_cut_restarts_same_voice_after_reentry() -> void:
    var fixture := _start_non_cut_automation_voice(&"automation_tail_reentry")
    var voice: SfxPlaybackRuntime.ActiveVoice = fixture["voice"]
    var event: SfxEvent = fixture["event"]
    runtime.modulate(event.name, {"rpm": 650.0})
    assert_true(voice.finish_on_end)

    runtime.modulate(event.name, {"rpm": 550.0})
    assert_eq(runtime._active_voices.size(), 1, "Re-entry should reuse the draining voice")
    assert_eq(runtime._active_voices[0], voice, "Re-entry should not duplicate the automation voice")
    assert_false(voice.finish_on_end, "Re-entry should clear finish-on-end state")
    assert_true(SfxStreamLoopSupport.is_looping(voice.stream), "Re-entry should restore the loop-capable stream copy")


func test_automation_track_without_cut_wraps_loop_position_before_tail() -> void:
    assert_almost_eq(runtime._resolve_tail_start_position(1.2, 0.5, true), 0.2, 0.001, "Loop tail should wrap elapsed playback into sample time")
    assert_almost_eq(runtime._resolve_tail_start_position(1.2, 0.5, false), 0.0, 0.001, "Tail should not start at sample end")


func test_event_visualization_state_exposes_latest_parameters() -> void:
    var event := SfxEvent.new()
    event.name = &"visualized"
    event.automations = [_make_automation(&"rpm", 0.0, 1000.0, 500.0)]

    runtime.play(event, 0.0, {"rpm": 250.0})
    var initial_state: Dictionary = runtime.get_event_visualization_state(event.name)
    assert_eq(initial_state.get("parameters", {}).get("rpm"), 250.0, "Visualization state should expose the latest runtime parameter snapshot")

    runtime.modulate(event.name, {"rpm": 700.0})
    var updated_state: Dictionary = runtime.get_event_visualization_state(event.name)
    assert_eq(updated_state.get("parameters", {}).get("rpm"), 700.0, "Visualization state should update after modulation")


func test_event_visualization_time_tracks_follow_event_clock() -> void:
    var event := SfxEvent.new()
    event.name = &"time_visual_alignment"
    var clip := _make_clip(0.0, 2.0)
    event.clips = [clip]

    runtime.play(event)
    runtime.update(0.75)

    var state: Dictionary = runtime.get_event_visualization_state(event.name)
    var clip_state: Dictionary = state.get("clips", {}).get(clip, {})
    assert_true(bool(clip_state.get("active", false)), "Timeline clip should be active after playback starts")
    assert_almost_eq(float(state.get("event_time", 0.0)), 0.75, 0.0001, "Visualization should expose the event clock")
    assert_almost_eq(float(clip_state.get("position", 0.0)), 0.75, 0.0001, "Timeline lane cursor should align to event_time for offset 0 clips")


func test_event_visualization_exposes_active_automation_track_states() -> void:
    var event := SfxEvent.new()
    event.name = &"automation_visuals"
    var automation := _make_automation(&"rpm", 0.0, 1000.0, 500.0)
    event.automations = [automation]

    runtime.play(event, 0.0, {&"rpm": 800.0})

    var state: Dictionary = runtime.get_event_visualization_state(event.name)
    var automation_states: Dictionary = state.get("automation_clips", {}).get(&"rpm", {})
    var clip_state: Dictionary = automation_states.get(automation.clips[0], {})
    assert_true(bool(clip_state.get("active", false)), "Automation visualization should expose the active automation voice")
    assert_gt(float(clip_state.get("visible_span", 0.0)), 0.0, "Automation visualization should include the visible playback span")


func test_automation_tracks_use_stream_offset_without_parameter_delta() -> void:
    var event := SfxEvent.new()
    event.name = &"automation_stream_offset"
    var automation := _make_automation(&"rpm", 0.0, 1000.0, 500.0)
    var clip: SfxClip = automation.clips[0]
    clip.stream_offset = 0.4
    event.automations = [automation]

    runtime.play(event, 0.0, {"rpm": 800.0})
    assert_eq(runtime._active_voices.size(), 1)

    var start_position := runtime._resolve_voice_start_position(runtime._get_latest_instance(event.name), clip, automation)
    assert_eq(start_position, 0.4, "Automation clips should start from stream_offset only")


func test_phase_locked_automation_tracks_use_event_clock_for_start_position() -> void:
    var event := SfxEvent.new()
    event.name = &"phase_locked"
    var automation := _make_automation(&"speed", 0.0, 200.0, 10.0)
    automation.phase_locked = true
    automation.phase_period = 2.0
    var clip: SfxClip = automation.clips[0]
    clip.stream = _make_test_wav(4.0)
    clip.stream_offset = 0.25
    event.automations = [automation]

    runtime.play(event, 1.25, {"speed": 20.0})
    assert_eq(runtime._active_voices.size(), 1)

    var expected_start := 1.5
    var voice: SfxPlaybackRuntime.ActiveVoice = runtime._active_voices[0]
    assert_almost_eq(voice.stream_start_position, expected_start, 0.0001, "Phase-locked automation clips should derive start position from event time")


func test_phase_locked_automation_tracks_apply_phase_offset() -> void:
    var event := SfxEvent.new()
    event.name = &"phase_offset"
    var automation := _make_automation(&"speed", 0.0, 200.0, 10.0)
    automation.phase_locked = true
    automation.phase_period = 2.0
    var clip: SfxClip = automation.clips[0]
    clip.stream = _make_test_wav(4.0)
    clip.phase_offset = 0.5
    event.automations = [automation]

    runtime.play(event, 1.25, {"speed": 20.0})
    assert_eq(runtime._active_voices.size(), 1)

    var voice: SfxPlaybackRuntime.ActiveVoice = runtime._active_voices[0]
    assert_almost_eq(voice.stream_start_position, 1.75, 0.0001, "Clip phase_offset should shift the shared automation phase")


func test_automation_curves_are_shifted_by_track_offset() -> void:
    var clip := _make_clip(460.0)
    clip.fade_in_curve = _make_linear_curve(0.0, 100.0, 0.0, 1.0)

    assert_eq(runtime._sample_automation_curve(clip.fade_in_curve, 460.0, clip.offset), 0.0, "Fade-in should start at the clip offset")
    assert_eq(runtime._sample_automation_curve(clip.fade_in_curve, 510.0, clip.offset), 0.5, "Curve midpoint should land offset units later in automation space")
    assert_eq(runtime._sample_automation_curve(clip.fade_in_curve, 560.0, clip.offset), 1.0, "Curve max domain should also be shifted by the clip offset")


func test_automation_pitch_curve_uses_full_automation_domain() -> void:
    var automation := _make_automation(&"rpm", 0.0, 1000.0, 460.0)
    automation.pitch_curve = _make_linear_curve(0.0, 1000.0, 1.0, 2.0)
    var clip: SfxClip = automation.clips[0]
    clip.pitch_curve = _make_linear_curve(0.0, 100.0, 1.0, 1.5)

    assert_eq(runtime._sample_automation_curve(automation.pitch_curve, 0.0), 1.0, "Automation pitch curve should start at the automation domain start")
    assert_eq(runtime._sample_automation_curve(automation.pitch_curve, 500.0), 1.5, "Automation pitch curve should sample directly from automation_value")
    assert_eq(runtime._sample_automation_curve(automation.pitch_curve, 1000.0), 2.0, "Automation pitch curve should reach the end of its domain")
    assert_eq(runtime._sample_automation_curve(clip.pitch_curve, 460.0, clip.offset), 1.0, "Clip pitch curve should still be local to clip offset")
    assert_eq(runtime._sample_automation_curve(clip.pitch_curve, 560.0, clip.offset), 1.5, "Clip pitch curve should still use local automation value")


func test_automation_fade_out_curve_is_reversed_in_local_track_domain() -> void:
    var clip := _make_clip(310.0)
    clip.fade_in_curve = _make_linear_curve(0.0, 90.0, 0.0, 1.0)
    clip.fade_out_curve = _make_linear_curve(0.0, 90.0, 1.0, 0.0)

    assert_eq(runtime._sample_automation_curve(clip.fade_in_curve, 310.0, clip.offset), 0.0, "Fade-in should start silent at the threshold")
    assert_eq(runtime._sample_automation_curve(clip.fade_in_curve, 355.0, clip.offset), 0.5, "Fade-in should use local automation value")
    assert_eq(runtime._sample_automation_curve(clip.fade_in_curve, 400.0, clip.offset), 1.0, "Fade-in should reach full gain at the end of the local domain")
    assert_eq(runtime._sample_automation_fade_out_curve(clip.fade_out_curve, clip, 310.0), 0.0, "Fade-out should read the end of the curve at the threshold")
    assert_eq(runtime._sample_automation_fade_out_curve(clip.fade_out_curve, clip, 355.0), 0.5, "Fade-out midpoint should mirror local automation space")
    assert_eq(runtime._sample_automation_fade_out_curve(clip.fade_out_curve, clip, 400.0), 1.0, "Fade-out should not zero the clip at the end of the local domain")


func test_automation_length_shifts_fade_out_curve_to_track_end() -> void:
    var clip := _make_clip(405.0)
    clip.length = 285.0
    clip.fade_in_curve = _make_linear_curve(0.0, 90.0, 0.0, 1.0)
    clip.fade_out_curve = _make_linear_curve(0.0, 90.0, 1.0, 0.0)

    assert_eq(runtime._sample_automation_curve(clip.fade_in_curve, 600.0, clip.offset), 1.0, "Fade-in should already be at full gain by the time fade-out starts")
    assert_eq(runtime._sample_automation_fade_out_curve(clip.fade_out_curve, clip, 600.0), 1.0, "Fade-out should start one curve duration before offset + length")
    assert_eq(runtime._sample_automation_fade_out_curve(clip.fade_out_curve, clip, 645.0), 0.5, "Fade-out should interpolate across the last curve duration before clip end")
    assert_eq(runtime._sample_automation_fade_out_curve(clip.fade_out_curve, clip, 690.0), 0.0, "Fade-out should end exactly at offset + length")


func test_automation_length_uses_last_curve_window_before_track_end() -> void:
    var clip := _make_clip(760.0)
    clip.length = 180.0
    clip.fade_in_curve = _make_linear_curve(0.0, 90.0, 0.0, 1.0)
    clip.fade_out_curve = _make_linear_curve(0.0, 90.0, 1.0, 0.0)

    assert_eq(runtime._sample_automation_curve(clip.fade_in_curve, 856.0, clip.offset), 1.0, "Fade-in should already be fully open at 856")
    assert_gt(runtime._sample_automation_fade_out_curve(clip.fade_out_curve, clip, 856.0), 0.9, "Fade-out should only be slightly attenuated at 856")


func test_stop_with_release_keeps_instance_alive_until_adsr_finishes() -> void:
    var event := SfxEvent.new()
    event.name = &"released"
    event.adsr_enabled = true
    event.release = 0.2
    event.clips = [_make_clip(0.0)]

    runtime.play(event)
    assert_true(runtime._instances.has(event.name))
    assert_eq(runtime._active_voices.size(), 1)

    runtime.stop(event.name, false)
    assert_true(runtime._instances.has(event.name), "Event instance should stay alive during release")

    runtime.update(0.1)
    assert_true(runtime._instances.has(event.name), "Release should still be in progress")

    runtime.update(0.2)
    assert_false(runtime._instances.has(event.name), "Event instance should be removed after release")
    assert_eq(runtime._active_voices.size(), 0, "Voices should be stopped after release")


func test_polyphony_enabled_allows_multiple_instances_of_same_event() -> void:
    var event := SfxEvent.new()
    event.name = &"poly"
    event.polyphony_enabled = true
    event.clips = [_make_clip(0.0)]

    runtime.play(event)
    runtime.play(event)

    assert_eq(runtime._get_instances_for_event(event.name).size(), 2, "Polyphonic event should keep multiple instances alive")
    assert_eq(runtime._active_voices.size(), 2, "Each polyphonic instance should allocate its own voice")


func test_polyphony_disabled_replaces_existing_instance() -> void:
    var event := SfxEvent.new()
    event.name = &"mono"
    event.polyphony_enabled = false
    event.clips = [_make_clip(0.0)]

    runtime.play(event)
    runtime.play(event)

    assert_eq(runtime._get_instances_for_event(event.name).size(), 1, "Monophonic event should replace the previous instance")
    assert_eq(runtime._active_voices.size(), 1, "Monophonic event should keep only one active voice")


func test_stop_targets_latest_instance_for_polyphonic_event() -> void:
    var event := SfxEvent.new()
    event.name = &"poly_stop"
    event.polyphony_enabled = true
    event.clips = [_make_clip(0.0)]

    runtime.play(event)
    runtime.play(event)
    assert_eq(runtime._get_instances_for_event(event.name).size(), 2)

    runtime.stop(event.name, true)

    assert_eq(runtime._get_instances_for_event(event.name).size(), 1, "Named stop should only remove the newest polyphonic instance")
    assert_eq(runtime._active_voices.size(), 1, "One older polyphonic voice should remain active")


func test_is_playing_tracks_instance_lifecycle() -> void:
    var event := SfxEvent.new()
    event.name = &"playing_state"
    event.clips = [_make_clip(0.0)]

    assert_false(runtime.is_playing(event.name))

    runtime.play(event)
    assert_true(runtime.is_playing(event.name))

    runtime.stop(event.name, true)
    assert_false(runtime.is_playing(event.name))


func test_one_shot_event_finishes_after_last_voice_ends() -> void:
    var event := SfxEvent.new()
    event.name = &"one_shot_finishes"
    event.clips = [_make_clip(0.0, 0.2)]

    runtime.play(event)
    assert_true(runtime.is_playing(event.name))
    assert_eq(runtime._active_voices.size(), 1)

    var player: AudioStreamPlayer = runtime._active_voices[0].player
    player.stop()
    runtime.handle_player_finished(player)
    runtime.update(0.01)

    assert_false(runtime.is_playing(event.name), "Event instance should disappear after its last one-shot voice ends naturally")


func test_automation_one_shot_event_finishes_after_triggered_voice_ends() -> void:
    var event := SfxEvent.new()
    event.name = &"automation_one_shot_finishes"
    var automation := _make_automation(&"toggle", 0.0, 1.0, 0.0)
    var clip: SfxClip = automation.clips[0]
    clip.stream = _make_test_wav(0.2)
    event.automations = [automation]

    runtime.play(event, 0.0, {"toggle": 0.0})
    assert_true(runtime.is_playing(event.name))
    assert_eq(runtime._active_voices.size(), 1)

    var player: AudioStreamPlayer = runtime._active_voices[0].player
    player.stop()
    runtime.handle_player_finished(player)
    runtime.update(0.01)

    assert_false(runtime.is_playing(event.name), "Automation one-shot event should disappear after all triggered voices end naturally")


func test_sustain_track_does_not_start_during_initial_playback() -> void:
    var event := SfxEvent.new()
    event.name = &"sustain_wait"
    var sustain_track := _make_clip(0.0)
    sustain_track.trigger_mode = SfxClip.TriggerMode.TRIGGER_SUSTAIN
    event.clips = [sustain_track]

    runtime.play(event)

    assert_eq(runtime._active_voices.size(), 0, "Sustain clips should not start on play")
    assert_true(runtime._instances.has(event.name), "Event instance should remain active until stopped")


func test_stop_with_release_triggers_sustain_track_once() -> void:
    var event := SfxEvent.new()
    event.name = &"sustain_once"
    event.adsr_enabled = true
    event.release = 0.5
    var sustain_track := _make_clip(0.0)
    sustain_track.trigger_mode = SfxClip.TriggerMode.TRIGGER_SUSTAIN
    event.clips = [sustain_track]

    runtime.play(event)
    runtime.stop(event.name, false)

    assert_eq(runtime._active_voices.size(), 1, "Sustain clip should start on non-immediate stop")

    runtime.stop(event.name, false)
    assert_eq(runtime._active_voices.size(), 1, "Repeated non-immediate stop should not retrigger sustain clip")


func test_sustain_track_offset_uses_release_clock_and_stream_offset() -> void:
    var event := SfxEvent.new()
    event.name = &"sustain_offset"
    var sustain_track := _make_clip(0.15, 1.0)
    sustain_track.trigger_mode = SfxClip.TriggerMode.TRIGGER_SUSTAIN
    sustain_track.stream_offset = 0.3
    event.clips = [sustain_track]

    runtime.play(event)
    runtime.stop(event.name, false)
    assert_eq(runtime._active_voices.size(), 0, "Delayed sustain clip should not be queued after stop")
    assert_false(runtime._instances.has(event.name), "Instance should be collected when only delayed sustain remains")


func test_sustain_track_start_position_does_not_inherit_event_playback_time() -> void:
    var event := SfxEvent.new()
    event.name = &"sustain_stream_start"
    var sustain_track := _make_clip(0.0, 1.0)
    sustain_track.trigger_mode = SfxClip.TriggerMode.TRIGGER_SUSTAIN
    sustain_track.stream_offset = 0.1
    event.clips = [sustain_track]

    runtime.play(event)
    runtime.update(0.25)
    runtime.stop(event.name, false)

    var voice: SfxPlaybackRuntime.ActiveVoice = runtime._active_voices[0]
    assert_eq(voice.stream_start_position, 0.1, "Sustain clip should start from stream_offset, not from elapsed event playback time")


func test_immediate_stop_does_not_trigger_sustain_track() -> void:
    var event := SfxEvent.new()
    event.name = &"sustain_immediate"
    var sustain_track := _make_clip(0.0)
    sustain_track.trigger_mode = SfxClip.TriggerMode.TRIGGER_SUSTAIN
    event.clips = [sustain_track]

    runtime.play(event)
    runtime.stop(event.name, true)

    assert_false(runtime._instances.has(event.name), "Immediate stop should remove the event instance")
    assert_eq(runtime._active_voices.size(), 0, "Immediate stop should not start sustain clips")


func test_stop_without_adsr_keeps_instance_alive_until_sustain_track_finishes() -> void:
    var event := SfxEvent.new()
    event.name = &"sustain_no_adsr"
    var sustain_track := _make_clip(0.0, 0.2)
    sustain_track.trigger_mode = SfxClip.TriggerMode.TRIGGER_SUSTAIN
    event.clips = [sustain_track]

    runtime.play(event)
    runtime.stop(event.name, false)

    assert_true(runtime._instances.has(event.name), "Non-immediate stop without ADSR should keep the instance alive for sustain playback")
    assert_eq(runtime._active_voices.size(), 1, "Sustain clip should still start without ADSR")

    runtime._players[0].stop()
    runtime.handle_player_finished(runtime._players[0])
    runtime.update(0.0)

    assert_false(runtime._instances.has(event.name), "Instance should be removed after sustain playback ends")
    assert_eq(runtime._active_voices.size(), 0, "No voices should remain after sustain playback ends")


func test_stop_without_adsr_stops_existing_timeline_loop_before_starting_sustain_track() -> void:
    var event := SfxEvent.new()
    event.name = &"sustain_cuts_loop"
    var timeline_track := _make_clip(0.0, 1.0)
    timeline_track.stream = _make_test_wav(1.0, true)
    var sustain_track := _make_clip(0.0, 0.2)
    sustain_track.trigger_mode = SfxClip.TriggerMode.TRIGGER_SUSTAIN
    event.clips = [timeline_track, sustain_track]

    runtime.play(event)
    assert_eq(runtime._active_voices.size(), 1, "Timeline clip should start on play")
    assert_eq(runtime._active_voices[0].clip, timeline_track, "Initial voice should belong to the looping timeline clip")

    runtime.stop(event.name, false)

    assert_eq(runtime._active_voices.size(), 1, "Only the sustain clip should remain after non-ADSR stop")
    assert_eq(runtime._active_voices[0].clip, sustain_track, "Non-ADSR stop should cut the old loop and start the sustain clip")


func _run_stop_without_adsr_release_scenario(event_name: StringName, configure_timeline_track: Callable) -> Dictionary:
    var event := SfxEvent.new()
    event.name = event_name
    var timeline_track := _make_clip(0.0, 1.0)
    timeline_track.stream = _make_test_wav(1.0, true)
    configure_timeline_track.call(timeline_track)
    var sustain_track := _make_clip(0.0, 0.2)
    sustain_track.trigger_mode = SfxClip.TriggerMode.TRIGGER_SUSTAIN
    event.clips = [timeline_track, sustain_track]

    runtime.play(event)
    runtime.stop(event.name, false)
    var voices_after_stop := runtime._active_voices.size()

    runtime.update(0.1)
    var fading_voice := runtime._find_voice(runtime._get_latest_instance(event.name), timeline_track)
    var mid_gain := db_to_linear(fading_voice.player.volume_db) if fading_voice else -1.0

    runtime.update(0.11)
    var voice_after_release := runtime._find_voice(runtime._get_latest_instance(event.name), timeline_track)

    return {
        "voices_after_stop": voices_after_stop,
        "fading_voice": fading_voice,
        "mid_gain": mid_gain,
        "voice_after_release": voice_after_release,
    }


func test_stop_without_adsr_uses_track_fade_out_curve_for_existing_voice() -> void:
    var result := _run_stop_without_adsr_release_scenario(
        &"sustain_fades_loop",
        func(track: SfxClip): track.fade_out_curve = _make_linear_curve(0.0, 0.2, 1.0, 0.0)
    )
    assert_eq(result["voices_after_stop"], 2, "Looping timeline voice should fade out while sustain clip starts")
    assert_not_null(result["fading_voice"], "Timeline voice should still exist halfway through its stop fade")
    assert_almost_eq(result["mid_gain"], 0.5, 0.1, "Timeline voice should follow the fade_out_curve during non-ADSR stop")
    assert_null(result["voice_after_release"], "Timeline voice should be removed after its fade_out_curve duration")


func test_stop_without_event_adsr_uses_track_adsr_release_for_looping_voice() -> void:
    var result := _run_stop_without_adsr_release_scenario(
        &"track_adsr_release",
        func(track: SfxClip):
            var mixer_track := SfxTrack.new()
            mixer_track.adsr_enabled = true
            mixer_track.release = 0.2
            track.track = mixer_track
    )
    assert_eq(result["voices_after_stop"], 2, "Looping voice should release while sustain clip starts")
    assert_not_null(result["fading_voice"], "Timeline voice should still exist halfway through track ADSR release")
    assert_almost_eq(result["mid_gain"], 0.5, 0.1, "Track ADSR release should attenuate the looping voice immediately after stop")
    assert_null(result["voice_after_release"], "Timeline voice should end after its track ADSR release")


func test_track_adsr_sustain_applies_while_voice_is_held() -> void:
    var event := SfxEvent.new()
    event.name = &"track_adsr_hold"
    var clip := _make_clip(0.0, 1.0)
    var mixer_track := SfxTrack.new()
    mixer_track.adsr_enabled = true
    mixer_track.attack = 0.1
    mixer_track.decay = 0.1
    mixer_track.sustain = 0.25
    clip.track = mixer_track
    event.clips = [clip]

    runtime.play(event)
    runtime.update(0.1)
    runtime.update(0.1)
    runtime.update(0.05)

    assert_eq(runtime._active_voices.size(), 1)
    assert_almost_eq(_player_linear_gain(0), 0.25, 0.1, "Track ADSR sustain should hold the voice below unity even before stop")


func test_horn_like_overlap_stop_starts_sustain_track() -> void:
    var local_runtime := _make_local_runtime(2)

    var event := SfxEvent.new()
    event.name = &"horn_like"

    var start_track := _make_clip(0.0, 0.36)
    var loop_track := _make_clip(0.2, 1.0)
    loop_track.stream = _make_test_wav(1.0, true)
    var sustain_track := _make_clip(0.0, 0.3)
    sustain_track.trigger_mode = SfxClip.TriggerMode.TRIGGER_SUSTAIN

    event.clips = [start_track, loop_track, sustain_track]

    local_runtime.play(event)
    local_runtime.update(0.25)
    assert_eq(local_runtime._active_voices.size(), 2, "Horn overlap should have start and loop voices active before stop")

    local_runtime.stop(event.name, false)
    assert_eq(local_runtime._active_voices.size(), 1, "Sustain clip should replace overlapping horn voices on stop")

    var sustain_voice := local_runtime._find_voice(local_runtime._get_latest_instance(event.name), sustain_track)
    assert_not_null(sustain_voice, "Horn-like sustain clip should start during overlap stop")
    assert_true(sustain_voice.player.playing, "Sustain voice should still be playing after overlapping voices are stopped")


func test_new_voice_steals_oldest_releasing_voice_before_delaying_start() -> void:
    var local_runtime := _make_local_runtime(2)

    var releasing_event := SfxEvent.new()
    releasing_event.name = &"releasing"
    var releasing_track := _make_clip(0.0, 1.0)
    releasing_track.stream = _make_test_wav(1.0, true)
    releasing_track.fade_out_curve = _make_linear_curve(0.0, 0.5, 1.0, 0.0)
    var releasing_sustain := _make_clip(0.0, 0.25)
    releasing_sustain.trigger_mode = SfxClip.TriggerMode.TRIGGER_SUSTAIN
    releasing_event.clips = [releasing_track, releasing_sustain]

    var held_event := SfxEvent.new()
    held_event.name = &"held"
    var held_track := _make_clip(0.0, 1.0)
    held_track.stream = _make_test_wav(1.0, true)
    held_event.clips = [held_track]

    var newcomer_event := SfxEvent.new()
    newcomer_event.name = &"newcomer"
    newcomer_event.clips = [_make_clip(0.0, 0.2)]

    local_runtime.play(releasing_event)
    local_runtime.play(held_event)
    local_runtime.stop(releasing_event.name, false)

    assert_eq(local_runtime._active_voices.size(), 2, "Releasing sustain and held voice should occupy the full pool before the steal")
    assert_null(local_runtime._find_voice(local_runtime._get_latest_instance(releasing_event.name), releasing_track), "Stop should already evict the older releasing loop when sustain starts at the limit")
    assert_not_null(local_runtime._find_voice(local_runtime._get_latest_instance(releasing_event.name), releasing_sustain), "Sustain should be the remaining releasing voice before the next play")

    local_runtime.play(newcomer_event)

    assert_eq(local_runtime._active_voices.size(), 2, "New voice should start immediately by stealing a slot")
    assert_not_null(local_runtime._find_voice(local_runtime._get_latest_instance(newcomer_event.name), newcomer_event.clips[0]), "Newcomer voice should exist right after play")
    assert_null(local_runtime._find_voice(local_runtime._get_latest_instance(releasing_event.name), releasing_sustain), "Remaining releasing voice should be stolen before touching non-releasing voices")
    assert_not_null(local_runtime._find_voice(local_runtime._get_latest_instance(held_event.name), held_track), "Non-releasing voice should not be stolen while a releasing one exists")


func test_new_voice_steals_oldest_global_voice_when_no_releasing_voice_exists() -> void:
    var local_runtime := _make_local_runtime(2)

    var first_event := SfxEvent.new()
    first_event.name = &"first"
    var first_track := _make_clip(0.0, 1.0)
    first_track.stream = _make_test_wav(1.0, true)
    first_event.clips = [first_track]

    var second_event := SfxEvent.new()
    second_event.name = &"second"
    var second_track := _make_clip(0.0, 1.0)
    second_track.stream = _make_test_wav(1.0, true)
    second_event.clips = [second_track]

    var newcomer_event := SfxEvent.new()
    newcomer_event.name = &"newest"
    newcomer_event.clips = [_make_clip(0.0, 0.2)]

    local_runtime.play(first_event)
    local_runtime.play(second_event)
    local_runtime.play(newcomer_event)

    assert_eq(local_runtime._active_voices.size(), 2, "New voice should steal instead of waiting for a free player")
    assert_null(local_runtime._find_voice(local_runtime._get_latest_instance(first_event.name), first_track), "Oldest global voice should be stolen first")
    assert_not_null(local_runtime._find_voice(local_runtime._get_latest_instance(second_event.name), second_track), "More recent global voice should remain active")
    assert_not_null(local_runtime._find_voice(local_runtime._get_latest_instance(newcomer_event.name), newcomer_event.clips[0]), "New voice should start immediately")


func test_rapid_replay_with_non_immediate_stop_does_not_delay_new_starts_at_track_limit() -> void:
    var local_runtime := _make_local_runtime(2)

    var event := SfxEvent.new()
    event.name = &"rapid"
    event.polyphony_enabled = true
    var loop_track := _make_clip(0.0, 1.0)
    loop_track.stream = _make_test_wav(1.0, true)
    loop_track.fade_out_curve = _make_linear_curve(0.0, 0.5, 1.0, 0.0)
    var sustain_track := _make_clip(0.0, 0.2)
    sustain_track.trigger_mode = SfxClip.TriggerMode.TRIGGER_SUSTAIN
    event.clips = [loop_track, sustain_track]

    local_runtime.play(event)
    local_runtime.stop(event.name, false)
    local_runtime.play(event)

    var instances := local_runtime._get_instances_for_event(event.name)
    assert_eq(instances.size(), 2, "Polyphonic replay should keep the releasing instance while starting a new one")
    assert_eq(local_runtime._active_voices.size(), 2, "Replay should reuse a slot immediately instead of delaying the new start")
    assert_not_null(local_runtime._find_voice(instances[1], loop_track), "Newest instance should start its loop immediately")
    assert_not_null(local_runtime._find_voice(instances[0], sustain_track), "Existing sustain should remain audible if it is not the stolen voice")


func test_linear_crossfade_normalizes_overlapping_automation_tracks() -> void:
    var event := SfxEvent.new()
    event.name = &"linear_overlap"
    var automation := SfxAutomation.new()
    automation.parameter_name = &"param"
    automation.min_domain = 0.0
    automation.max_domain = 1.0
    automation.crossfade_mode = SfxAutomation.CrossfadeMode.LINEAR
    var first_track := _make_clip(0.0)
    first_track.fade_in_curve = _make_constant_curve(1.0)
    first_track.fade_out_curve = _make_linear_curve(0.0, 1.0, 1.0, 0.0)
    var second_track := _make_clip(0.0)
    second_track.fade_in_curve = _make_linear_curve(0.0, 1.0, 0.0, 1.0)
    second_track.fade_out_curve = _make_constant_curve(1.0)
    automation.clips = [first_track, second_track]
    event.automations = [automation]

    runtime.play(event, 0.0, {&"param": 0.5})

    assert_eq(runtime._active_voices.size(), 2, "Both overlapping automation clips should be active")
    assert_almost_eq(_player_linear_gain(0), 0.5, 0.01, "The first clip should be normalized to half gain at midpoint")
    assert_almost_eq(_player_linear_gain(1), 0.5, 0.01, "The second clip should be normalized to half gain at midpoint")
    assert_almost_eq(_sum_player_linear_gain([0, 1]), 1.0, 0.01, "Linear overlap should preserve total amplitude")


func test_equal_power_crossfade_normalizes_group_power() -> void:
    var event := SfxEvent.new()
    event.name = &"equal_power_overlap"
    var automation := SfxAutomation.new()
    automation.parameter_name = &"param"
    automation.min_domain = 0.0
    automation.max_domain = 1.0
    automation.crossfade_mode = SfxAutomation.CrossfadeMode.EQUAL_POWER
    var first_track := _make_clip(0.0)
    first_track.fade_in_curve = _make_constant_curve(1.0)
    first_track.fade_out_curve = _make_linear_curve(0.0, 1.0, 1.0, 0.0)
    var second_track := _make_clip(0.0)
    second_track.fade_in_curve = _make_linear_curve(0.0, 1.0, 0.0, 1.0)
    second_track.fade_out_curve = _make_constant_curve(1.0)
    automation.clips = [first_track, second_track]
    event.automations = [automation]

    runtime.play(event, 0.0, {&"param": 0.5})

    assert_eq(runtime._active_voices.size(), 2, "Both overlapping automation clips should be active")
    assert_almost_eq(_player_linear_gain(0), sqrt(0.5), 0.01, "Equal-power midpoint should keep each voice at sqrt(0.5)")
    assert_almost_eq(_player_linear_gain(1), sqrt(0.5), 0.01, "Equal-power midpoint should mirror the matching voice gain")
    assert_almost_eq(_sum_player_power([0, 1]), 1.0, 0.02, "Equal-power overlap should preserve total power")
    assert_gt(_player_linear_gain(0), 0.5, "Equal-power should differ from linear normalization at midpoint")


func test_automation_crossfade_normalization_is_scoped_per_event_instance_and_automation() -> void:
    var event_a := SfxEvent.new()
    event_a.name = &"scope_a"
    var automation_a := SfxAutomation.new()
    automation_a.parameter_name = &"param"
    automation_a.min_domain = 0.0
    automation_a.max_domain = 1.0
    automation_a.crossfade_mode = SfxAutomation.CrossfadeMode.LINEAR
    var a_first := _make_clip(0.0)
    a_first.fade_in_curve = _make_constant_curve(1.0)
    a_first.fade_out_curve = _make_linear_curve(0.0, 1.0, 1.0, 0.0)
    var a_second := _make_clip(0.0)
    a_second.fade_in_curve = _make_linear_curve(0.0, 1.0, 0.0, 1.0)
    a_second.fade_out_curve = _make_constant_curve(1.0)
    automation_a.clips = [a_first, a_second]
    event_a.automations = [automation_a]

    var event_b := SfxEvent.new()
    event_b.name = &"scope_b"
    var automation_b := SfxAutomation.new()
    automation_b.parameter_name = &"param"
    automation_b.min_domain = 0.0
    automation_b.max_domain = 1.0
    automation_b.crossfade_mode = SfxAutomation.CrossfadeMode.LINEAR
    var b_track := _make_clip(0.0)
    b_track.fade_in_curve = _make_constant_curve(1.0)
    b_track.fade_out_curve = _make_constant_curve(1.0)
    automation_b.clips = [b_track]
    event_b.automations = [automation_b]

    runtime.play(event_a, 0.0, {&"param": 0.5})
    runtime.play(event_b, 0.0, {&"param": 0.5})

    assert_eq(runtime._active_voices.size(), 3, "The control event should add one independent automation voice")
    assert_almost_eq(_sum_player_linear_gain([0, 1]), 1.0, 0.01, "Normalization should only apply within the overlapping event instance")
    assert_almost_eq(_player_linear_gain(2), 1.0, 0.01, "An independent event instance should keep its own full gain")


func _play_single_clip_with_track(event_name: StringName, configure_track: Callable) -> void:
    var event := SfxEvent.new()
    event.name = event_name
    var clip := _make_clip(0.0)
    var mixer_track := SfxTrack.new()
    configure_track.call(mixer_track)
    clip.track = mixer_track
    event.clips = [clip]
    event.tracks = [mixer_track]
    runtime.play(event)


func test_track_mute_silences_voice() -> void:
    _play_single_clip_with_track(&"muted", func(track: SfxTrack): track.mute = true)

    assert_eq(runtime._active_voices.size(), 1, "Muted track should still allocate a voice")
    assert_almost_eq(_player_linear_gain(0), 0.0, 0.0001, "Muted track should silence its clip")


func test_track_volume_db_applies_linear_gain() -> void:
    _play_single_clip_with_track(&"volume", func(track: SfxTrack): track.volume_db = linear_to_db(0.5))

    assert_almost_eq(_player_linear_gain(0), 0.5, 0.01, "Track volume_db should apply as a linear multiplier on the voice gain")


func test_clip_without_track_falls_back_to_event_master_track() -> void:
    var event := SfxEvent.new()
    event.name = &"master_fallback"
    var clip := _make_clip(0.0)
    event.clips = [clip]
    event.master_track.mute = true

    runtime.play(event)

    assert_eq(runtime._active_voices.size(), 1, "Clip with no assigned track should still allocate a voice")
    assert_almost_eq(_player_linear_gain(0), 0.0, 0.0001, "Clip with no assigned track should be silenced by a muted event.master_track")


func test_track_solo_silences_other_tracks_within_event() -> void:
    var event := SfxEvent.new()
    event.name = &"solo_scope"
    var soloed_clip := _make_clip(0.0)
    var soloed_track := SfxTrack.new()
    soloed_track.solo = true
    soloed_clip.track = soloed_track

    var other_clip := _make_clip(0.0)
    var other_track := SfxTrack.new()
    other_clip.track = other_track

    var ungrouped_clip := _make_clip(0.0)

    event.clips = [soloed_clip, other_clip, ungrouped_clip]
    event.tracks = [soloed_track, other_track]

    runtime.play(event)

    assert_eq(runtime._active_voices.size(), 3)
    for voice in runtime._active_voices:
        var gain := db_to_linear(voice.player.volume_db)
        if voice.clip == soloed_clip:
            assert_almost_eq(gain, 1.0, 0.01, "Soloed track's clip should remain audible")
        else:
            assert_almost_eq(gain, 0.0, 0.0001, "Non-soloed clips should be silenced while a track is soloed")


func test_track_solo_does_not_affect_other_events() -> void:
    var soloing_event := SfxEvent.new()
    soloing_event.name = &"solo_event"
    var soloed_clip := _make_clip(0.0)
    var soloed_track := SfxTrack.new()
    soloed_track.solo = true
    soloed_clip.track = soloed_track
    soloing_event.clips = [soloed_clip]
    soloing_event.tracks = [soloed_track]

    var other_event := SfxEvent.new()
    other_event.name = &"other_event"
    other_event.clips = [_make_clip(0.0)]

    runtime.play(soloing_event)
    runtime.play(other_event)

    for voice in runtime._active_voices:
        assert_almost_eq(db_to_linear(voice.player.volume_db), 1.0, 0.01, "Solo in one event should not silence voices belonging to a different event")


func _make_clip(offset: float, duration_seconds := 0.5) -> SfxClip:
    var clip := SfxClip.new()
    clip.stream = _make_test_wav(duration_seconds)
    clip.offset = offset
    return clip


func _make_automation(name: StringName, min_domain: float, max_domain: float, offset: float) -> SfxAutomation:
    var automation := SfxAutomation.new()
    automation.parameter_name = name
    automation.min_domain = min_domain
    automation.max_domain = max_domain
    automation.clips = [_make_clip(offset)]
    return automation


func _make_test_wav(duration_seconds := 0.5, loop := false) -> AudioStreamWAV:
    var stream := AudioStreamWAV.new()
    stream.format = AudioStreamWAV.FORMAT_8_BITS
    stream.mix_rate = 44100
    stream.stereo = false
    stream.loop_mode = AudioStreamWAV.LOOP_FORWARD if loop else AudioStreamWAV.LOOP_DISABLED
    var sample_count := int(round(44100.0 * duration_seconds))
    var audio_data := PackedByteArray()
    audio_data.resize(sample_count)
    for index in range(sample_count):
        audio_data[index] = 128
    stream.data = audio_data
    return stream


func _make_linear_curve(x0: float, x1: float, y0: float, y1: float) -> Curve:
    var curve := Curve.new()
    curve.min_domain = minf(x0, x1)
    curve.max_domain = maxf(x0, x1)
    curve.min_value = minf(y0, y1)
    curve.max_value = maxf(y0, y1)
    curve.add_point(Vector2(x0, y0))
    curve.add_point(Vector2(x1, y1))
    return curve


func _make_constant_curve(value: float) -> Curve:
    var curve := Curve.new()
    curve.min_domain = 0.0
    curve.max_domain = 1.0
    curve.min_value = value
    curve.max_value = value
    curve.add_point(Vector2(0.0, value))
    curve.add_point(Vector2(1.0, value))
    return curve


func _player_linear_gain(index: int) -> float:
    return db_to_linear(runtime._players[index].volume_db)


func _sum_player_linear_gain(indices: Array[int]) -> float:
    var total := 0.0
    for index in indices:
        total += _player_linear_gain(index)
    return total


func _sum_player_power(indices: Array[int]) -> float:
    var total := 0.0
    for index in indices:
        var gain := _player_linear_gain(index)
        total += gain * gain
    return total
