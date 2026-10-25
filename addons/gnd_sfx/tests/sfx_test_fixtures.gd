class_name SfxTestFixtures
extends RefCounted

## Resources the runtime tests build their events from


static func make_clip(offset: float, duration_seconds := 0.5, loop := false) -> SfxClip:
    var clip := SfxClip.new()
    clip.stream = make_wav(duration_seconds, loop)
    clip.offset = offset
    return clip


static func make_automation(name: StringName, min_domain: float, max_domain: float, offset: float) -> SfxAutomation:
    var automation := SfxAutomation.new()
    automation.parameter_name = name
    automation.min_domain = min_domain
    automation.max_domain = max_domain
    automation.clips = [make_clip(offset)]
    return automation


static func make_event(name: StringName, clips: Array[SfxClip] = []) -> SfxEvent:
    var event := SfxEvent.new()
    event.name = name
    event.clips = clips
    return event


static func make_wav(duration_seconds := 0.5, loop := false) -> AudioStreamWAV:
    var stream := AudioStreamWAV.new()
    stream.format = AudioStreamWAV.FORMAT_8_BITS
    stream.mix_rate = 44100
    stream.loop_mode = AudioStreamWAV.LOOP_FORWARD if loop else AudioStreamWAV.LOOP_DISABLED
    var sample_count := int(round(44100.0 * duration_seconds))
    var audio_data := PackedByteArray()
    audio_data.resize(sample_count)
    audio_data.fill(128)
    stream.data = audio_data
    stream.loop_end = sample_count if loop else 0
    return stream


static func make_linear_curve(x0: float, x1: float, y0: float, y1: float) -> Curve:
    var curve := Curve.new()
    curve.min_domain = minf(x0, x1)
    curve.max_domain = maxf(x0, x1)
    curve.min_value = minf(y0, y1)
    curve.max_value = maxf(y0, y1)
    curve.add_point(Vector2(x0, y0))
    curve.add_point(Vector2(x1, y1))
    return curve


static func make_constant_curve(value: float) -> Curve:
    return make_linear_curve(0.0, 1.0, value, value)
