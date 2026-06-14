extends RefCounted
class_name WaveformPreviewCache

const ENVELOPE_BUCKET_COUNT := 256
const MAX_SAMPLES_PER_BUCKET := 256

static var _preview_cache := {}


static func clear_cache() -> void:
    _preview_cache.clear()


static func get_clip_preview(clip: SfxClip) -> Dictionary:
    if not clip:
        return _build_empty_preview()
    return await _get_stream_preview(clip.stream)


static func get_clip_name(clip: SfxClip) -> String:
    if not clip or not clip.stream:
        return "Generator"
    var stream := clip.stream
    if stream.has_method("_get_stream_name"):
        var stream_name: String = stream._get_stream_name()
        if stream_name:
            return stream_name
    var source_path := _resolve_stream_source_path(stream)
    if not source_path.is_empty():
        return source_path.get_file().get_basename()
    return stream.get_class()


static func _get_stream_preview(stream: AudioStream) -> Dictionary:
    var cache_key := _build_stream_cache_key(stream)
    if not cache_key.is_empty() and _preview_cache.has(cache_key):
        return _preview_cache[cache_key]

    var preview: Dictionary = await _build_preview_for_stream(stream)
    if not cache_key.is_empty():
        _preview_cache[cache_key] = preview
    return preview


static func _build_preview_for_stream(stream: AudioStream) -> Dictionary:
    if not stream:
        return _build_empty_preview()
    if stream is AudioStreamGenerator:
        return _build_empty_preview("GEN")
    if stream is AudioStreamRandomizer:
        return await _build_randomizer_preview(stream as AudioStreamRandomizer)
    if stream is AudioStreamWAV:
        return await _build_wav_preview(stream as AudioStreamWAV)
    if stream is AudioStreamOggVorbis:
        return await _build_ogg_preview(stream as AudioStreamOggVorbis)
    return await _build_generic_playback_preview(stream)


static func _build_stream_cache_key(stream: AudioStream) -> String:
    if not stream:
        return ""
    if stream is AudioStreamRandomizer:
        var child_keys := PackedStringArray()
        var randomizer := stream as AudioStreamRandomizer
        for index in range(randomizer.streams_count):
            child_keys.append(_build_stream_cache_key(randomizer.get_stream(index)))
        return "rand://%s/%s/%s" % [
            stream.get_instance_id(),
            randomizer.playback_mode,
            "|".join(child_keys),
        ]
    if not stream.resource_path.is_empty():
        return "path://%s" % stream.resource_path
    if stream is AudioStreamWAV:
        var wav := stream as AudioStreamWAV
        return "wav://%s/%s/%s/%s/%s" % [
            stream.get_instance_id(),
            wav.format,
            wav.mix_rate,
            wav.stereo,
            wav.data.size(),
        ]
    if stream is AudioStreamOggVorbis:
        var ogg := stream as AudioStreamOggVorbis
        var packet_sequence: OggPacketSequence = ogg.packet_sequence
        var packet_count := 0
        if packet_sequence:
            packet_count = packet_sequence.packet_data.size()
        return "ogg://%s/%s/%s" % [
            stream.get_instance_id(),
            maxf(stream.get_length(), 0.0),
            packet_count,
        ]
    return "%s://%s" % [stream.get_class(), stream.get_instance_id()]


static func _build_randomizer_preview(stream: AudioStreamRandomizer) -> Dictionary:
    if not stream or stream.streams_count <= 0:
        return _build_empty_preview("RAND")

    var previews: Array[Dictionary] = []
    for index in range(stream.streams_count):
        var child_stream: AudioStream = stream.get_stream(index)
        if not child_stream:
            continue
        var preview: Dictionary = await _get_stream_preview(child_stream)
        var preview_mins: PackedFloat32Array = preview.get("mins", PackedFloat32Array())
        var preview_maxs: PackedFloat32Array = preview.get("maxs", PackedFloat32Array())
        if preview_mins.is_empty() or preview_maxs.is_empty():
            continue
        previews.append(preview)

    if previews.is_empty():
        return _build_empty_preview("RAND")
    if previews.size() == 1:
        return previews[0]

    var mins := PackedFloat32Array()
    var maxs := PackedFloat32Array()
    mins.resize(ENVELOPE_BUCKET_COUNT)
    maxs.resize(ENVELOPE_BUCKET_COUNT)
    var duration := 0.0
    for bucket in range(ENVELOPE_BUCKET_COUNT):
        var min_sum := 0.0
        var max_sum := 0.0
        for preview in previews:
            var preview_mins: PackedFloat32Array = preview.get("mins", PackedFloat32Array())
            var preview_maxs: PackedFloat32Array = preview.get("maxs", PackedFloat32Array())
            min_sum += sample_envelope_array(preview_mins, float(bucket) / maxf(ENVELOPE_BUCKET_COUNT - 1, 1.0))
            max_sum += sample_envelope_array(preview_maxs, float(bucket) / maxf(ENVELOPE_BUCKET_COUNT - 1, 1.0))
            duration = maxf(duration, float(preview.get("duration", 0.0)))
        mins[bucket] = min_sum / float(previews.size())
        maxs[bucket] = max_sum / float(previews.size())

    return {
        "kind": "file",
        "synthetic": false,
        "duration": duration,
        "mins": mins,
        "maxs": maxs,
        "source_path": _resolve_stream_source_path(stream),
    }


static func _build_wav_preview(stream: AudioStreamWAV) -> Dictionary:
    if not stream:
        return _build_empty_preview("NO PREVIEW")
    var duration := maxf(stream.get_length(), 0.0)
    var total_frames := int(round(duration * maxf(stream.mix_rate, 1.0)))
    if total_frames <= 0:
        var channel_count := 2 if stream.stereo else 1
        var bytes_per_channel := 0
        match stream.format:
            AudioStreamWAV.FORMAT_8_BITS:
                bytes_per_channel = 1
            AudioStreamWAV.FORMAT_16_BITS:
                bytes_per_channel = 2
            _:
                bytes_per_channel = 0
        if bytes_per_channel > 0:
            var frame_stride := channel_count * bytes_per_channel
            if frame_stride > 0:
                total_frames = stream.data.size() / frame_stride
                duration = float(total_frames) / maxf(stream.mix_rate, 1.0)
    return await _build_playback_preview(stream, total_frames, duration, _resolve_stream_source_path(stream))


static func _build_ogg_preview(stream: AudioStreamOggVorbis) -> Dictionary:
    if not stream:
        return _build_empty_preview("NO PREVIEW")
    var duration := maxf(stream.get_length(), 0.0)
    var total_frames := _resolve_ogg_total_frames(stream, duration)
    return await _build_playback_preview(stream, total_frames, duration, _resolve_stream_source_path(stream))


static func _build_generic_playback_preview(stream: AudioStream) -> Dictionary:
    if not stream:
        return _build_empty_preview("NO PREVIEW")
    var playback := stream.instantiate_playback()
    if not playback:
        return _build_empty_preview("NO PREVIEW")
    var duration := maxf(stream.get_length(), 0.0)
    if duration <= 0.0:
        return _build_empty_preview("NO PREVIEW")
    var total_frames := int(round(duration * 44100.0))
    return await _build_playback_preview_from_instance(playback, total_frames, duration, _resolve_stream_source_path(stream))


static func _build_playback_preview(stream: AudioStream, total_frames: int, duration: float, source_path: String) -> Dictionary:
    var playback = stream.instantiate_playback()
    if not playback or duration <= 0.0 or total_frames <= 0:
        return _build_empty_preview("NO PREVIEW")
    return await _build_playback_preview_from_instance(playback, total_frames, duration, source_path)


static func _build_playback_preview_from_instance(playback: AudioStreamPlayback, total_frames: int, duration: float, source_path: String) -> Dictionary:
    if not playback or duration <= 0.0 or total_frames <= 0:
        return _build_empty_preview("NO PREVIEW")
    var mins := PackedFloat32Array()
    var maxs := PackedFloat32Array()
    mins.resize(ENVELOPE_BUCKET_COUNT)
    maxs.resize(ENVELOPE_BUCKET_COUNT)
    for bucket in range(ENVELOPE_BUCKET_COUNT):
        mins[bucket] = 1.0
        maxs[bucket] = -1.0

    playback.start(0.0)
    var decoded_frames := 0
    var last_yield_ms := Time.get_ticks_msec()
    while decoded_frames < total_frames:
        var chunk_size := mini(2048, total_frames - decoded_frames)
        var mixed: PackedVector2Array = playback.mix_audio(1.0, chunk_size)
        if mixed.is_empty():
            break
        for sample_vector in mixed:
            var amplitude := clampf((sample_vector.x + sample_vector.y) * 0.5, -1.0, 1.0)
            var bucket := mini(
                int((float(decoded_frames) / maxf(total_frames - 1, 1.0)) * float(ENVELOPE_BUCKET_COUNT - 1)),
                ENVELOPE_BUCKET_COUNT - 1
            )
            mins[bucket] = minf(mins[bucket], amplitude)
            maxs[bucket] = maxf(maxs[bucket], amplitude)
            decoded_frames += 1
            if decoded_frames >= total_frames:
                break
        if mixed.size() < chunk_size:
            break
        if Time.get_ticks_msec() - last_yield_ms >= 8:
            await (Engine.get_main_loop() as SceneTree).process_frame
            last_yield_ms = Time.get_ticks_msec()

    _finalize_envelope_arrays(mins, maxs)
    return {
        "kind": "file",
        "synthetic": false,
        "duration": duration,
        "mins": mins,
        "maxs": maxs,
        "source_path": source_path,
    }


static func _resolve_ogg_total_frames(stream: AudioStreamOggVorbis, duration: float) -> int:
    if not stream:
        return 0
    var packet_sequence: OggPacketSequence = stream.packet_sequence
    if packet_sequence:
        var granule_positions: PackedInt64Array = packet_sequence.get_packet_granule_positions()
        for index in range(granule_positions.size() - 1, -1, -1):
            var granule := int(granule_positions[index])
            if granule > 0:
                return granule
    return int(round(duration * 44100.0))


static func _finalize_envelope_arrays(mins: PackedFloat32Array, maxs: PackedFloat32Array) -> void:
    for bucket in range(ENVELOPE_BUCKET_COUNT):
        if mins[bucket] > maxs[bucket]:
            mins[bucket] = 0.0
            maxs[bucket] = 0.0


static func _build_empty_preview(label := "") -> Dictionary:
    return {
        "kind": "empty",
        "synthetic": false,
        "duration": 0.0,
        "mins": PackedFloat32Array(),
        "maxs": PackedFloat32Array(),
        "source_path": "",
        "label": label,
    }


static func _resolve_stream_source_path(stream: AudioStream) -> String:
    if not stream:
        return ""
    if stream.resource_path.is_empty():
        return ""
    return stream.resource_path


static func sample_envelope_array(values: PackedFloat32Array, ratio: float) -> float:
    if values.is_empty():
        return 0.0
    if values.size() == 1:
        return values[0]
    var clamped_ratio := clampf(ratio, 0.0, 1.0)
    var scaled_index := clamped_ratio * float(values.size() - 1)
    var from_index := clampi(int(floor(scaled_index)), 0, values.size() - 1)
    var to_index := mini(from_index + 1, values.size() - 1)
    if from_index == to_index:
        return values[from_index]
    return lerpf(values[from_index], values[to_index], scaled_index - float(from_index))
