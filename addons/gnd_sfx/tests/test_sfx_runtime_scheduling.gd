extends GutTest

## What the C++ port fixed and how the runtime sleeps between the moments it has work to do

var runtime: SfxPlaybackRuntime


func before_each() -> void:
    runtime = SfxPlaybackRuntime.new()
    runtime.set_slot_capacity(4)


func _gain(slot := 0) -> float:
    return db_to_linear(runtime.get_debug_slots()[slot].volume_db)


func _drain_event(name: StringName) -> SfxEvent:
    var event := SfxTestFixtures.make_event(name)
    var automation := SfxTestFixtures.make_automation(&"rpm", 0.0, 1000.0, 500.0)
    var clip: SfxClip = automation.clips[0]
    clip.stream = SfxTestFixtures.make_wav(0.5, true)
    clip.length = 100.0
    clip.cut = false
    event.automations = [automation]
    return event


func test_drained_loop_plays_its_tail_at_its_pitch() -> void:
    var event := _drain_event(&"slow_drain")
    event.pitch_variation = 0.5
    runtime.play(event, 0.0, {"rpm": 550.0})
    runtime.update(0.2)
    runtime.modulate(event.name, {"rpm": 650.0})
    runtime.update(0.0)
    runtime.update(0.5)
    assert_eq(runtime.get_debug_voices().size(), 1, "0.4 s of tail at half speed lasts 0.8 s, not 0.4 s")
    runtime.update(0.35)
    assert_eq(runtime.get_debug_voices().size(), 0, "The tail ends when its stream does")


func test_looping_automation_voice_is_not_copied_per_start() -> void:
    var event := _drain_event(&"no_copies")
    var clip: SfxClip = event.automations[0].clips[0]
    runtime.play(event, 0.0, {"rpm": 550.0})
    assert_eq(runtime.get_debug_voices()[0].stream, clip.stream, "A voice plays the clip's own stream")
    runtime.modulate(event.name, {"rpm": 650.0})
    runtime.update(0.0)
    var drained: AudioStream = runtime.get_debug_voices()[0].stream
    runtime.modulate(event.name, {"rpm": 550.0})
    runtime.update(0.0)
    runtime.modulate(event.name, {"rpm": 650.0})
    runtime.update(0.0)
    assert_eq(runtime.get_debug_voices()[0].stream, drained, "Every drain reuses the one stream made without the loop")


func test_looping_timeline_clip_does_not_fade_at_each_lap() -> void:
    var clip := SfxTestFixtures.make_clip(0.0, 1.0, true)
    clip.fade_out_curve = SfxTestFixtures.make_linear_curve(0.0, 0.5, 1.0, 0.0)
    var event := SfxTestFixtures.make_event(&"loop_fade", [clip])
    runtime.play(event)
    runtime.update(0.8)
    assert_almost_eq(_gain(), 1.0, 0.01, "A loop has no end to fade towards")
    runtime.stop(event.name, false)
    runtime.update(0.25)
    assert_almost_eq(_gain(), 0.5, 0.05, "Its stop still fades it out")


func test_time_pitch_curve_may_raise_the_pitch() -> void:
    var clip := SfxTestFixtures.make_clip(0.0, 2.0)
    clip.pitch_curve = SfxTestFixtures.make_linear_curve(0.0, 1.0, 1.0, 2.0)
    runtime.play(SfxTestFixtures.make_event(&"rising", [clip]))
    runtime.update(0.5)
    assert_almost_eq(runtime.get_debug_slots()[0].pitch_scale, 1.5, 0.01, "A pitch curve is not clamped to 1")


func test_steady_loop_sleeps() -> void:
    runtime.play(SfxTestFixtures.make_event(&"held", [SfxTestFixtures.make_clip(0.0, 1.0, true)]))
    runtime.update(0.1)
    assert_true(is_inf(runtime.get_next_wake()), "A held loop needs no tick")
    assert_true(runtime.requires_process(), "It still plays")


func test_pending_clip_wakes_the_runtime_at_its_offset() -> void:
    runtime.play(SfxTestFixtures.make_event(&"later", [SfxTestFixtures.make_clip(2.0)]))
    assert_almost_eq(runtime.get_next_wake(), runtime.get_clock() + 2.0, 0.0001, "The next tick is due when the clip is")


func test_fade_in_ticks_every_frame_and_fade_out_is_scheduled() -> void:
    var clip := SfxTestFixtures.make_clip(0.0, 1.0)
    clip.fade_in_curve = SfxTestFixtures.make_linear_curve(0.0, 0.2, 0.0, 1.0)
    clip.fade_out_curve = SfxTestFixtures.make_linear_curve(0.0, 0.3, 1.0, 0.0)
    runtime.play(SfxTestFixtures.make_event(&"faded", [clip]))
    assert_eq(runtime.get_next_wake(), runtime.get_clock(), "A fade in progress is ticked every frame")
    runtime.update(0.3)
    assert_almost_eq(runtime.get_next_wake(), runtime.get_clock() + 0.4, 0.0001, "The fade-out is due 0.3 s before the end")


func test_finished_runtime_needs_nothing() -> void:
    runtime.play(SfxTestFixtures.make_event(&"shot", [SfxTestFixtures.make_clip(0.0)]))
    runtime.handle_slot_finished(0)
    runtime.update(0.0)
    assert_false(runtime.requires_process(), "Nothing is left to tick")


func test_player_plays_through_the_server_and_reports_finished() -> void:
    var bank := SfxBank.new()
    bank.events = [SfxTestFixtures.make_event(&"loop", [SfxTestFixtures.make_clip(0.0, 1.0, true)])]
    var player := SfxPlayer.new()
    player.bank = bank
    add_child_autoqfree(player)
    watch_signals(player)
    player.play(&"loop")
    await _wait_frames(3)
    var node: AudioStreamPlayer = player.get_child(0)
    assert_true(node.playing, "The worker's tick reached the node")
    player.stop(&"loop", true)
    await _wait_frames(3)
    assert_false(node.playing, "The stop reached the node")
    assert_signal_emitted(player, "finished")


func _wait_frames(count: int) -> void:
    for _index in range(count):
        await get_tree().process_frame
