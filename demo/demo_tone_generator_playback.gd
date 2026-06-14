extends SfxGeneratorPlayback
class_name DemoToneGeneratorPlayback

const BASE_GAIN := 0.18


func create_state(playback: AudioStreamGeneratorPlayback, track):
    return {
        "playback": playback,
        "phase": 0.0,
        "mix_rate": _resolve_mix_rate(track),
    }


func update(state, context: Dictionary) -> void:
    if not state:
        return

    var playback: AudioStreamGeneratorPlayback = state.get("playback")
    if not playback:
        return

    var phase := float(state.get("phase", 0.0))
    var mix_rate := maxf(float(state.get("mix_rate", 44100.0)), 1.0)
    var available_frames := playback.get_frames_available()
    var frequency := _resolve_frequency(context)
    var amplitude := _resolve_amplitude(context)

    for _frame_index in range(available_frames):
        var sample := sin(phase) * amplitude
        playback.push_frame(Vector2(sample, sample))
        phase += TAU * frequency / mix_rate
        if phase > TAU:
            phase = fmod(phase, TAU)

    state["phase"] = phase


func cleanup(_state) -> void:
    pass


func _resolve_mix_rate(track) -> float:
    if track and track.stream is AudioStreamGenerator:
        return maxf(track.stream.mix_rate, 1.0)
    return 44100.0


func _resolve_frequency(context: Dictionary) -> float:
    var automation_name := String(context.get("automation_name", ""))
    var parameters: Dictionary = context.get("parameters", {})
    if automation_name and parameters.has(automation_name):
        var automation_value := float(parameters[automation_name])
        return clampf(220.0 + automation_value * 2.0, 110.0, 1200.0)
    return 220.0 + sin(float(context.get("event_time", 0.0)) * 1.5) * 35.0


func _resolve_amplitude(context: Dictionary) -> float:
    var automation_name := String(context.get("automation_name", ""))
    var parameters: Dictionary = context.get("parameters", {})
    if automation_name and parameters.has(automation_name):
        var automation_value := float(parameters[automation_name])
        return clampf(BASE_GAIN + automation_value / 6000.0, 0.05, 0.28)
    return BASE_GAIN
