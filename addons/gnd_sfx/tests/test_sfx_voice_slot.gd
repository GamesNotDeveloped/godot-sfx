extends GutTest

## The contract SfxPlaybackRuntime (worker thread) and SfxPlayerCore (main
## thread) meet on: what a slot asks for, and what it still owes the node.

var slot: SfxVoiceSlot


func before_each() -> void:
    slot = SfxVoiceSlot.new()


func test_new_slot_owes_the_node_nothing() -> void:
    assert_eq(slot.dirty, 0, "A fresh slot has nothing to flush")
    assert_eq(slot.play_serial, slot.applied_play_serial, "A fresh slot asks for no playback")
    assert_false(slot.playing)


func test_play_asks_for_the_stream_and_the_transport() -> void:
    var stream := AudioStreamWAV.new()
    slot.play_stream(stream, 0.25)

    assert_eq(slot.stream, stream)
    assert_true(slot.dirty & SfxVoiceSlot.Dirty.STREAM > 0, "The new stream has to reach the node")
    assert_true(slot.dirty & SfxVoiceSlot.Dirty.TRANSPORT > 0, "The play request has to reach the node")
    assert_eq(slot.transport, SfxVoiceSlot.Transport.PLAY)
    assert_gt(slot.play_serial, slot.applied_play_serial, "An unapplied play is still owed")


## The tick that starts a voice reads the slot back straight away, before the
## main thread has applied anything - so a play seeds what the node will report.
func test_play_seeds_the_observed_state() -> void:
    slot.play_stream(AudioStreamWAV.new(), 0.25)

    assert_true(slot.playing, "A voice just started counts as playing")
    assert_almost_eq(slot.playback_position, 0.25, 0.0001, "It plays from where it was asked to")


func test_restarting_a_playing_slot_is_not_lost() -> void:
    slot.play_stream(AudioStreamWAV.new(), 0.0)
    slot.applied_play_serial = slot.play_serial
    slot.dirty = 0

    slot.replay(1.0)

    assert_gt(slot.play_serial, slot.applied_play_serial, "A restart of a playing slot is owed too")
    assert_almost_eq(slot.start_position, 1.0, 0.0001)


func test_unchanged_gain_and_pitch_flush_nothing() -> void:
    slot.apply_gain(-6.0)
    slot.apply_pitch(1.5)
    slot.dirty = 0

    slot.apply_gain(-6.0)
    slot.apply_pitch(1.5)

    assert_eq(slot.dirty, 0, "Writing the same value again owes the node nothing")


func test_changed_gain_and_pitch_are_flushed_once() -> void:
    slot.apply_gain(-6.0)
    slot.apply_pitch(1.5)

    assert_true(slot.dirty & SfxVoiceSlot.Dirty.GAIN > 0)
    assert_true(slot.dirty & SfxVoiceSlot.Dirty.PITCH > 0)
    assert_almost_eq(slot.volume_db, -6.0, 0.0001)
    assert_almost_eq(slot.pitch_scale, 1.5, 0.0001)


func test_stop_takes_the_playback_state_down() -> void:
    slot.play_stream(AudioStreamWAV.new(), 0.0)
    slot.dirty = 0

    slot.stop_playback()

    assert_eq(slot.transport, SfxVoiceSlot.Transport.STOP)
    assert_false(slot.playing)
    assert_true(slot.dirty & SfxVoiceSlot.Dirty.TRANSPORT > 0)


func test_claim_hands_out_a_new_token_each_time() -> void:
    var first := slot.claim()
    var second := slot.claim()

    assert_ne(first, second, "A stolen slot must not look like the voice that had it")
    assert_eq(slot.token, second)


func test_spatial_override_is_flushed_and_taken_back() -> void:
    var config := SfxSpatialConfig.new()
    config.unit_size = 4.0
    config.panning_strength = 0.5

    slot.apply_spatial(config, 8.0)
    assert_true(slot.spatial_override)
    assert_almost_eq(slot.spatial_unit_size, 8.0, 0.0001, "The modulated unit size wins over the declared one")
    assert_true(slot.dirty & SfxVoiceSlot.Dirty.SPATIAL > 0)

    slot.dirty = 0
    slot.apply_spatial(config, 8.0)
    assert_eq(slot.dirty, 0, "The same spatial state owes the node nothing")

    slot.clear_spatial()
    assert_false(slot.spatial_override, "Without an override the node keeps its player's own values")
    assert_true(slot.dirty & SfxVoiceSlot.Dirty.SPATIAL > 0)


func test_reset_drops_the_stream_it_was_holding() -> void:
    slot.play_stream(AudioStreamWAV.new(), 0.0)
    slot.apply_gain(-12.0)
    slot.dirty = 0

    slot.reset(true)

    assert_null(slot.stream, "A reset slot stops holding the stream for the node")
    assert_eq(slot.transport, SfxVoiceSlot.Transport.STOP)
    assert_almost_eq(slot.volume_db, 0.0, 0.0001)
    assert_almost_eq(slot.pitch_scale, 1.0, 0.0001)
    assert_true(slot.dirty & SfxVoiceSlot.Dirty.STREAM > 0)
