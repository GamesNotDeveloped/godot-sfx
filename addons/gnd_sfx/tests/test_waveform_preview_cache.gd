extends GutTest


func before_each() -> void:
    WaveformPreviewCache.clear_cache()


func test_runtime_wav_streams_with_different_data_produce_different_previews() -> void:
    var quiet_clip := SfxClip.new()
    quiet_clip.stream = _make_runtime_wav(_make_constant_pcm_8bit(44100, 128))

    var loud_clip := SfxClip.new()
    loud_clip.stream = _make_runtime_wav(_make_square_pcm_8bit(44100, 24))

    var quiet_preview: Dictionary = await WaveformPreviewCache.get_clip_preview(quiet_clip)
    var loud_preview: Dictionary = await WaveformPreviewCache.get_clip_preview(loud_clip)
    var quiet_mins: PackedFloat32Array = quiet_preview.get("mins", PackedFloat32Array())
    var loud_mins: PackedFloat32Array = loud_preview.get("mins", PackedFloat32Array())
    var quiet_maxs: PackedFloat32Array = quiet_preview.get("maxs", PackedFloat32Array())
    var loud_maxs: PackedFloat32Array = loud_preview.get("maxs", PackedFloat32Array())

    assert_eq(quiet_preview.get("kind"), "file")
    assert_eq(loud_preview.get("kind"), "file")
    assert_false(quiet_mins.is_empty(), "Quiet runtime WAV should still produce envelope data")
    assert_false(loud_mins.is_empty(), "Loud runtime WAV should still produce envelope data")
    assert_ne(quiet_maxs[32], loud_maxs[32], "Distinct runtime WAV buffers should not collapse into the same preview")
    assert_ne(quiet_mins[32], loud_mins[32], "Distinct runtime WAV buffers should keep distinct min envelopes")


func test_generator_stream_returns_explicit_empty_preview() -> void:
    var clip := SfxClip.new()
    clip.stream = AudioStreamGenerator.new()

    var preview: Dictionary = await WaveformPreviewCache.get_clip_preview(clip)
    var mins: PackedFloat32Array = preview.get("mins", PackedFloat32Array())
    var maxs: PackedFloat32Array = preview.get("maxs", PackedFloat32Array())

    assert_eq(preview.get("kind"), "empty")
    assert_eq(preview.get("label"), "GEN")
    assert_true(mins.is_empty())
    assert_true(maxs.is_empty())


func _make_runtime_wav(audio_data: PackedByteArray) -> AudioStreamWAV:
    var stream := AudioStreamWAV.new()
    stream.format = AudioStreamWAV.FORMAT_8_BITS
    stream.mix_rate = 44100
    stream.stereo = false
    stream.data = audio_data
    return stream


func _make_constant_pcm_8bit(sample_count: int, value: int) -> PackedByteArray:
    var audio_data := PackedByteArray()
    audio_data.resize(sample_count)
    for index in range(sample_count):
        audio_data[index] = value
    return audio_data


func _make_square_pcm_8bit(sample_count: int, period: int) -> PackedByteArray:
    var audio_data := PackedByteArray()
    audio_data.resize(sample_count)
    for index in range(sample_count):
        audio_data[index] = 255 if int(index / max(period, 1)) % 2 == 0 else 0
    return audio_data
