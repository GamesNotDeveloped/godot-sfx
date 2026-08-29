extends RefCounted
class_name SfxPlaybackRuntime

enum AdsrStage { IDLE, ATTACK, DECAY, SUSTAIN, RELEASE, STOPPED }
enum PlaybackStatus { STOPPED, PLAYING, RELEASING }


class AdsrEnvelope:
    var stage: AdsrStage = AdsrStage.IDLE
    var elapsed := 0.0
    var release_start_gain := 0.0

    func enter(enabled: bool, attack: float, decay: float) -> void:
        elapsed = 0.0
        if not enabled:
            stage = AdsrStage.SUSTAIN
        elif attack > 0.0:
            stage = AdsrStage.ATTACK
        elif decay > 0.0:
            stage = AdsrStage.DECAY
        else:
            stage = AdsrStage.SUSTAIN

    func advance(delta: float, enabled: bool, attack: float, decay: float, release: float) -> void:
        if not enabled:
            stage = AdsrStage.SUSTAIN
            elapsed = 0.0
            return
        elapsed += delta
        match stage:
            AdsrStage.ATTACK:
                if attack <= 0.0 or elapsed >= attack:
                    stage = AdsrStage.DECAY
                    elapsed = 0.0
            AdsrStage.DECAY:
                if decay <= 0.0 or elapsed >= decay:
                    stage = AdsrStage.SUSTAIN
                    elapsed = 0.0
            AdsrStage.RELEASE:
                if release <= 0.0 or elapsed >= release:
                    stage = AdsrStage.STOPPED
                    elapsed = 0.0

    func gain(enabled: bool, attack: float, decay: float, sustain: float, release: float) -> float:
        if not enabled:
            return 1.0
        match stage:
            AdsrStage.ATTACK:
                return 1.0 if attack <= 0.0 else clampf(elapsed / attack, 0.0, 1.0)
            AdsrStage.DECAY:
                var sustain_gain := clampf(sustain, 0.0, 1.0)
                return sustain_gain if decay <= 0.0 else lerpf(1.0, sustain_gain, clampf(elapsed / decay, 0.0, 1.0))
            AdsrStage.RELEASE:
                return 0.0 if release <= 0.0 else lerpf(release_start_gain, 0.0, clampf(elapsed / release, 0.0, 1.0))
            AdsrStage.STOPPED:
                return 0.0
            _:
                return clampf(sustain, 0.0, 1.0)

    func begin_release(current_gain: float, release: float) -> bool:
        if stage == AdsrStage.RELEASE or stage == AdsrStage.STOPPED:
            return true
        release_start_gain = current_gain
        stage = AdsrStage.RELEASE
        elapsed = 0.0
        return release > 0.0


class EventInstance:
    var event: SfxEvent
    var event_name: StringName = &""
    var playback_time := 0.0
    var release_time := 0.0
    var parameters: Dictionary = {}
    var status: PlaybackStatus = PlaybackStatus.STOPPED
    var adsr := AdsrEnvelope.new()
    var triggered_event_clips: Array[SfxClip] = []
    var triggered_sustain_clips: Array[SfxClip] = []
    var triggered_automation_clips := {}


class ActiveVoice:
    var player
    var event_instance: EventInstance
    var clip: SfxClip
    var stream: AudioStream
    var stream_start_position := 0.0
    var stream_end_position := 0.0
    var automation: SfxAutomation
    var automation_name: StringName = &""
    var generator_playback: SfxGeneratorPlayback
    var generator_state
    var generator_stream_playback: AudioStreamGeneratorPlayback
    var stopping := false
    var finish_on_end := false
    var finish_elapsed := 0.0
    var finish_duration := 0.0
    var stop_elapsed := 0.0
    var stop_fade_duration := 0.0
    var player_token := 0
    var creation_order := 0
    var track_adsr := AdsrEnvelope.new()
    var automation_current_gain := 1.0
    var automation_release_gain := 1.0


signal finished
signal process_requirement_changed(required: bool)

var _players: Array = []
var _active_voices: Array[ActiveVoice] = []
var _instances: Dictionary = {}
var _player_tokens := {}
var _voice_creation_counter := 0


func set_players(players: Array) -> void:
    _players = players
    _notify_process_requirement_changed()


func clear() -> void:
    var had_activity := not _active_voices.is_empty() or not _instances.is_empty()
    for voice in _active_voices:
        _cleanup_voice(voice)
    for player in _players:
        _reset_player(player, true)
    _active_voices.clear()
    _instances.clear()
    _notify_process_requirement_changed()
    if had_activity:
        finished.emit()


func handle_player_finished(player) -> void:
    if not is_instance_valid(player):
        return
    if player.playing:
        return
    var token := int(_player_tokens.get(player, 0))
    var index := _find_active_voice_index(player, token)
    if not index == -1:
        _release_voice(index)


func update(delta: float) -> void:
    var active_instances: Array[EventInstance] = []
    for raw_instances in _instances.values():
        for raw_instance in raw_instances:
            var instance := raw_instance as EventInstance
            if instance:
                active_instances.append(instance)

    for instance in active_instances:
        _update_instance(instance, delta)

    for index in range(_active_voices.size() - 1, -1, -1):
        _update_voice(index, delta)

    _collect_finished_instances()
    _notify_process_requirement_changed()


func play(event: SfxEvent, offset := 0.0, parameters: Dictionary = {}) -> void:
    if not event:
        return

    var event_name := event.name
    if not event.polyphony_enabled:
        for instance in _get_instances_for_event(event_name):
            _stop_event_instance(instance, true)

    var instance := EventInstance.new()
    instance.event = event
    instance.event_name = event_name
    instance.playback_time = maxf(offset, 0.0)
    instance.parameters = parameters.duplicate(true)
    instance.status = PlaybackStatus.PLAYING
    _enter_attack(instance)
    _register_instance(instance)

    _refresh_event_clips(instance, -1.0, instance.playback_time)
    _refresh_automation_clips(instance)
    _notify_process_requirement_changed()


func seek(event_name: StringName, offset: float) -> void:
    var instance := _get_latest_instance(event_name)
    if not instance:
        return

    var rebuilt_parameters: Dictionary = instance.parameters.duplicate(true)
    var adsr := instance.adsr
    var release_time: float = instance.release_time
    var was_releasing: bool = instance.status == PlaybackStatus.RELEASING

    _stop_event_instance(instance, true)

    var rebuilt_instance := EventInstance.new()
    rebuilt_instance.event = instance.event
    rebuilt_instance.event_name = event_name
    rebuilt_instance.playback_time = maxf(offset, 0.0)
    rebuilt_instance.release_time = release_time
    rebuilt_instance.parameters = rebuilt_parameters
    rebuilt_instance.status = PlaybackStatus.RELEASING if was_releasing else PlaybackStatus.PLAYING
    rebuilt_instance.adsr = adsr
    rebuilt_instance.triggered_sustain_clips = instance.triggered_sustain_clips.duplicate()
    _register_instance(rebuilt_instance)

    _refresh_event_clips(rebuilt_instance, -1.0, rebuilt_instance.playback_time)
    if was_releasing:
        _refresh_sustain_clips(rebuilt_instance, -1.0, rebuilt_instance.release_time)
    _refresh_automation_clips(rebuilt_instance)
    _notify_process_requirement_changed()


func modulate(event_name: StringName, parameters: Dictionary) -> void:
    var instance := _get_latest_instance(event_name)
    if not instance:
        return

    for key in parameters.keys():
        instance.parameters[key] = parameters[key]

    _refresh_automation_clips(instance)
    for voice in _active_voices:
        if voice.event_instance == instance and voice.automation:
            _apply_voice_state(voice)
    _notify_process_requirement_changed()


func set_parameters(parameters: Dictionary) -> void:
    for event_name in parameters.keys():
        var event_parameters = parameters[event_name]
        if event_parameters is Dictionary:
            modulate(StringName(event_name), event_parameters)


func stop(event_name_or_immediate = null, immediate: bool = false) -> void:
    if event_name_or_immediate is bool:
        stop_all(event_name_or_immediate)
    elif event_name_or_immediate:
        stop_event(StringName(event_name_or_immediate), immediate)
    else:
        stop_all(immediate)


func stop_all(immediate: bool = false) -> void:
    var instances_to_stop: Array[EventInstance] = []
    for raw_instances in _instances.values():
        for raw_instance in raw_instances:
            var instance := raw_instance as EventInstance
            if instance:
                instances_to_stop.append(instance)
    for instance in instances_to_stop:
        _stop_event_instance(instance, immediate)

    _collect_finished_instances()
    _notify_process_requirement_changed()


func stop_event(event_name: StringName, immediate: bool = false) -> void:
    var instance := _get_latest_stoppable_instance(event_name)
    if instance:
        _stop_event_instance(instance, immediate)

    _collect_finished_instances()
    _notify_process_requirement_changed()


func play_automation(event: SfxEvent, automation_name: StringName, value: float = 0.0, restart: bool = false) -> void:
    if not event:
        return

    if restart or not is_playing(event.name):
        play(event, 0.0, {automation_name: value})
        return

    modulate(event.name, {automation_name: value})


func stop_automation(event: SfxEvent, _automation_name: StringName, immediate: bool = false) -> void:
    if not event:
        return
    stop_event(event.name, immediate)


func is_playing(event_name: StringName) -> bool:
    return not _get_instances_for_event(event_name).is_empty()


func get_event_visualization_state(event_name: StringName) -> Dictionary:
    var instance := _get_latest_instance(event_name)
    if not instance:
        return {
            "event_name": event_name,
            "playing": false,
            "event_time": 0.0,
            "parameters": {},
            "clips": {},
            "automation_clips": {},
        }

    var clip_states := {}
    for clip in instance.event.clips:
        if not clip:
            continue

        var voice := _find_latest_voice(instance, clip)
        clip_states[clip] = _build_visual_clip_state(clip, voice, true, instance)

    var automation_clip_states := {}
    for automation in instance.event.automations:
        if not automation or not automation.parameter_name:
            continue
        var automation_states := {}
        for clip in automation.clips:
            if not clip:
                continue
            var automation_voice := _find_latest_voice(instance, clip, automation.parameter_name)
            automation_states[clip] = _build_visual_clip_state(clip, automation_voice, false)
        automation_clip_states[automation.parameter_name] = automation_states

    return {
        "event_name": event_name,
        "playing": not instance.status == PlaybackStatus.STOPPED,
        "event_time": instance.playback_time,
        "parameters": instance.parameters.duplicate(true),
        "clips": clip_states,
        "automation_clips": automation_clip_states,
    }


func requires_process() -> bool:
    return not _active_voices.is_empty() or not _instances.is_empty()


func _update_instance(instance: EventInstance, delta: float) -> void:
    if not instance:
        return

    var previous_time := instance.playback_time
    var previous_release_time := instance.release_time
    if instance.status == PlaybackStatus.PLAYING:
        instance.playback_time += delta
        _refresh_event_clips(instance, previous_time, instance.playback_time)
    elif instance.status == PlaybackStatus.RELEASING:
        instance.playback_time += delta
        instance.release_time += delta
        _refresh_sustain_clips(instance, previous_release_time, instance.release_time)

    _update_adsr(instance, delta)


func _refresh_event_clips(instance: EventInstance, previous_time: float, current_time: float) -> void:
    for clip in instance.event.clips:
        if not clip:
            continue
        if not clip.trigger_mode == SfxClip.TriggerMode.TRIGGER_TIMELINE:
            continue
        if instance.triggered_event_clips.has(clip):
            continue
        if current_time < clip.offset:
            continue
        if previous_time >= 0.0 and previous_time > current_time:
            continue
        if _start_voice(instance, clip):
            instance.triggered_event_clips.append(clip)


func _refresh_sustain_clips(instance: EventInstance, previous_time: float, current_time: float) -> void:
    for clip in instance.event.clips:
        if not clip:
            continue
        if not clip.trigger_mode == SfxClip.TriggerMode.TRIGGER_SUSTAIN:
            continue
        if instance.triggered_sustain_clips.has(clip):
            continue
        if current_time < clip.offset:
            continue
        if previous_time >= 0.0 and previous_time > current_time:
            continue
        if _start_voice(instance, clip):
            instance.triggered_sustain_clips.append(clip)


func _refresh_automation_clips(instance: EventInstance) -> void:
    for automation in instance.event.automations:
        if not automation:
            continue

        var automation_name := automation.parameter_name
        if not automation_name:
            continue

        var current_value := float(instance.parameters.get(automation_name, automation.min_domain))

        if not instance.triggered_automation_clips.has(automation_name):
            instance.triggered_automation_clips[automation_name] = []

        var triggered_clips: Array = instance.triggered_automation_clips[automation_name]
        for clip in automation.clips:
            if not clip:
                continue
            if not clip.trigger_mode == SfxClip.TriggerMode.TRIGGER_TIMELINE:
                continue
            var voice := _find_voice(instance, clip, automation_name)
            var active_now := _automation_clip_contains_value(automation, clip, current_value)
            var triggered := triggered_clips.has(clip)
            if active_now:
                if not voice or _automation_voice_is_releasing(voice):
                    if _start_voice(instance, clip, automation) and not triggered:
                        triggered_clips.append(clip)
                elif not triggered:
                    triggered_clips.append(clip)
                continue

            if triggered:
                triggered_clips.erase(clip)
            if voice and not _automation_voice_is_releasing(voice):
                if clip.cut:
                    _stop_automation_voice(voice)
                else:
                    _finish_automation_voice_on_end(voice)


func _automation_clip_contains_value(automation: SfxAutomation, clip: SfxClip, value: float) -> bool:
    if not automation or not clip:
        return false
    var ascending: bool = automation.max_domain >= automation.min_domain
    var start := clip.offset
    var end: float = automation.max_domain if ascending else automation.min_domain
    if clip.length > 0.0:
        end = clip.offset + clip.length if ascending else clip.offset - clip.length
    if ascending:
        return value >= start and value <= end
    return value <= start and value >= end


func _update_adsr(instance: EventInstance, delta: float) -> void:
    var event := instance.event
    instance.adsr.advance(delta, event.adsr_enabled, event.attack, event.decay, event.release)
    if instance.adsr.stage == AdsrStage.STOPPED:
        _stop_event_instance(instance, true)


func _enter_attack(instance: EventInstance) -> void:
    var event := instance.event
    instance.adsr.enter(event.adsr_enabled, event.attack, event.decay)


func _current_adsr_gain(instance: EventInstance) -> float:
    var event := instance.event
    return instance.adsr.gain(event.adsr_enabled, event.attack, event.decay, event.sustain, event.release)


func _resolve_mixer_track(voice: ActiveVoice) -> SfxTrack:
    if voice.clip.track:
        return voice.clip.track
    return voice.event_instance.event.master_track


func _enter_track_attack(voice: ActiveVoice) -> void:
    var mixer_track := _resolve_mixer_track(voice)
    if not mixer_track:
        voice.track_adsr.enter(false, 0.0, 0.0)
        return
    voice.track_adsr.enter(mixer_track.adsr_enabled, mixer_track.attack, mixer_track.decay)


func _update_track_adsr(voice: ActiveVoice, delta: float) -> void:
    var mixer_track := _resolve_mixer_track(voice)
    if not mixer_track:
        voice.track_adsr.advance(delta, false, 0.0, 0.0, 0.0)
        return
    voice.track_adsr.advance(delta, mixer_track.adsr_enabled, mixer_track.attack, mixer_track.decay, mixer_track.release)


func _current_track_adsr_gain(voice: ActiveVoice) -> float:
    var mixer_track := _resolve_mixer_track(voice)
    if not mixer_track:
        return 1.0
    return voice.track_adsr.gain(mixer_track.adsr_enabled, mixer_track.attack, mixer_track.decay, mixer_track.sustain, mixer_track.release)


func _begin_track_release(voice: ActiveVoice) -> bool:
    var mixer_track := _resolve_mixer_track(voice)
    if not voice or not mixer_track or not mixer_track.adsr_enabled:
        return false
    return voice.track_adsr.begin_release(_current_track_adsr_gain(voice), mixer_track.release)


func _event_has_solo(event: SfxEvent) -> bool:
    if not event:
        return false
    if event.master_track and event.master_track.solo:
        return true
    for mixer_track in event.tracks:
        if mixer_track and mixer_track.solo:
            return true
    return false


func _resolve_track_mixer_gain(voice: ActiveVoice) -> float:
    var mixer_track := _resolve_mixer_track(voice)
    var mixer_gain := 1.0
    if mixer_track:
        mixer_gain = db_to_linear(mixer_track.volume_db)
        if mixer_track.mute:
            mixer_gain = 0.0
    if voice.event_instance and _event_has_solo(voice.event_instance.event) and not (mixer_track and mixer_track.solo):
        mixer_gain = 0.0
    return mixer_gain


func _find_active_voice_index(player, token: int = -1) -> int:
    for index in range(_active_voices.size()):
        var voice := _active_voices[index]
        if voice.player == player and (token == -1 or voice.player_token == token):
            return index
    return -1


func _find_voice(instance: EventInstance, clip: SfxClip, automation_name: StringName = &"") -> ActiveVoice:
    for voice in _active_voices:
        if voice.event_instance == instance and voice.clip == clip and voice.automation_name == automation_name:
            return voice
    return null


func _find_latest_voice(instance: EventInstance, clip: SfxClip, automation_name: StringName = &"") -> ActiveVoice:
    var latest_voice: ActiveVoice = null
    for voice in _active_voices:
        if not voice.event_instance == instance or not voice.clip == clip or not voice.automation_name == automation_name:
            continue
        if not latest_voice or voice.creation_order > latest_voice.creation_order:
            latest_voice = voice
    return latest_voice


func _get_instances_for_event(event_name: StringName) -> Array[EventInstance]:
    if not _instances.has(event_name):
        return []
    var instances: Array[EventInstance] = []
    for raw_instance in _instances[event_name]:
        var instance := raw_instance as EventInstance
        if instance:
            instances.append(instance)
    return instances


func _get_latest_instance(event_name: StringName) -> EventInstance:
    var instances: Array[EventInstance] = _get_instances_for_event(event_name)
    if instances.is_empty():
        return null
    return instances[instances.size() - 1]


func _get_latest_stoppable_instance(event_name: StringName) -> EventInstance:
    var instances: Array[EventInstance] = _get_instances_for_event(event_name)
    for index in range(instances.size() - 1, -1, -1):
        var instance: EventInstance = instances[index]
        if instance and instance.status == PlaybackStatus.PLAYING:
            return instance
    for index in range(instances.size() - 1, -1, -1):
        var instance: EventInstance = instances[index]
        if instance:
            return instance
    return null


func _register_instance(instance: EventInstance) -> void:
    if not instance:
        return
    if not _instances.has(instance.event_name):
        _instances[instance.event_name] = []
    var instances: Array = _instances[instance.event_name]
    instances.append(instance)
    _instances[instance.event_name] = instances


func _remove_instance(instance: EventInstance) -> void:
    if not instance:
        return
    if not _instances.has(instance.event_name):
        return
    var instances: Array = _instances[instance.event_name]
    var index := instances.find(instance)
    if not index == -1:
        instances.remove_at(index)
    if instances.is_empty():
        _instances.erase(instance.event_name)
    else:
        _instances[instance.event_name] = instances


func _has_instance(instance: EventInstance) -> bool:
    if not instance:
        return false
    return _get_instances_for_event(instance.event_name).has(instance)


func _get_available_player():
    for player in _players:
        if _find_active_voice_index(player) == -1:
            return player
    return null


func _find_voice_to_steal() -> ActiveVoice:
    var oldest_releasing: ActiveVoice = null
    var oldest_global: ActiveVoice = null
    for voice in _active_voices:
        if not voice:
            continue
        if not oldest_global or voice.creation_order < oldest_global.creation_order:
            oldest_global = voice
        if voice.event_instance and voice.event_instance.status == PlaybackStatus.RELEASING:
            if not oldest_releasing or voice.creation_order < oldest_releasing.creation_order:
                oldest_releasing = voice
    return oldest_releasing if oldest_releasing else oldest_global


func _acquire_player_for_new_voice():
    var player = _get_available_player()
    if player:
        return player

    var victim := _find_voice_to_steal()
    if not victim or not is_instance_valid(victim.player):
        return null

    var stolen_player = victim.player
    _stop_voice(_active_voices.find(victim))
    return stolen_player


func _get_curve_duration(curve: Curve) -> float:
    if not curve:
        return 0.0
    return maxf(curve.max_domain - curve.min_domain, 0.0)


func _sample_time_bound_curve(curve: Curve, elapsed: float, from_end: bool) -> float:
    if not curve:
        return 1.0

    var duration := _get_curve_duration(curve)
    if duration <= 0.0:
        return clampf(curve.sample(curve.max_domain), 0.0, 1.0)

    var clamped_elapsed := clampf(elapsed, 0.0, duration)
    var sample_position := curve.min_domain + (duration - clamped_elapsed if from_end else clamped_elapsed)
    return clampf(curve.sample(sample_position), 0.0, 1.0)


func _sample_curve_gain(curve: Curve, elapsed: float) -> float:
    return _sample_time_bound_curve(curve, elapsed, false)


func _sample_time_fade_out_curve(curve: Curve, remaining: float) -> float:
    return _sample_time_bound_curve(curve, remaining, true)


func _sample_automation_curve(curve: Curve, value: float, offset: float = 0.0) -> float:
    if not curve:
        return 1.0

    return curve.sample(clampf(value - offset, curve.min_domain, curve.max_domain))


func _sample_automation_fade_out_curve(curve: Curve, clip: SfxClip, value: float) -> float:
    if not curve:
        return 1.0

    if clip.length > 0.0:
        var fade_end := clip.offset + clip.length
        return _sample_time_bound_curve(curve, maxf(fade_end - value, 0.0), true)

    var local_value := clampf(value - clip.offset, curve.min_domain, curve.max_domain)
    var sample_position := curve.min_domain + (curve.max_domain - local_value)
    return curve.sample(sample_position)


func _is_generator_voice(voice: ActiveVoice) -> bool:
    return voice.generator_playback and voice.generator_stream_playback


func _set_player_gain(player, gain: float) -> void:
    player.volume_db = linear_to_db(maxf(gain, 0.0001))


func _build_generator_context(voice: ActiveVoice, delta: float) -> Dictionary:
    var playback_position := 0.0
    if is_instance_valid(voice.player):
        playback_position = voice.player.get_playback_position()

    var automation_value = null
    if voice.automation:
        automation_value = voice.event_instance.parameters.get(voice.automation_name, voice.automation.min_domain)

    return {
        "delta": delta,
        "playback_position": playback_position,
        "event_name": voice.event_instance.event_name,
        "clip": voice.clip,
        "player": voice.player,
        "stream_playback": voice.generator_stream_playback,
        "event_time": voice.event_instance.playback_time,
        "parameters": voice.event_instance.parameters,
        "automation_name": voice.automation_name,
        "automation_value": automation_value,
    }


func _pump_generator_voice(voice: ActiveVoice, delta: float) -> void:
    if not _is_generator_voice(voice):
        return
    voice.generator_playback.update(voice.generator_state, _build_generator_context(voice, delta))


func _build_clip_stream(clip: SfxClip, automation: SfxAutomation = null) -> AudioStream:
    if not clip or not clip.stream:
        return null

    if clip.stream is AudioStreamGenerator:
        if not clip.generator_playback:
            push_error("AudioStreamGenerator clip requires generator_playback")
            return null
        var stream_copy = clip.stream.duplicate(true)
        return stream_copy as AudioStream if stream_copy else clip.stream

    if automation and not clip.cut and SfxStreamLoopSupport.is_looping(clip.stream):
        var stream_copy = clip.stream.duplicate(true)
        return stream_copy as AudioStream if stream_copy else clip.stream

    return clip.stream


func _resolve_voice_start_position(instance: EventInstance, clip: SfxClip, automation: SfxAutomation = null) -> float:
    var start_position := maxf(clip.stream_offset, 0.0)
    if not automation:
        if clip.trigger_mode == SfxClip.TriggerMode.TRIGGER_SUSTAIN:
            return start_position
        start_position += maxf(instance.playback_time - clip.offset, 0.0)
    return start_position


func _resolve_phase_locked_automation_start_position(instance: EventInstance, clip: SfxClip, automation: SfxAutomation, stream: AudioStream) -> float:
    var start_position := maxf(clip.stream_offset, 0.0)
    if not instance or not automation or not stream:
        return start_position
    if not automation.phase_locked or automation.phase_period <= 0.0:
        return start_position

    var stream_length := maxf(stream.get_length(), 0.0)
    var available_length := maxf(stream_length - start_position, 0.0)
    if available_length <= 0.0:
        return start_position

    var phase := fposmod(instance.playback_time + clip.phase_offset, automation.phase_period)
    if phase > available_length:
        phase = fposmod(phase, available_length)
    return start_position + phase


func _resolve_local_clip_time(voice: ActiveVoice, playback_position: float) -> float:
    return maxf(playback_position - voice.stream_start_position, 0.0)


func _resolve_remaining_clip_time(voice: ActiveVoice, playback_position: float) -> float:
    if not voice.stream:
        return 0.0
    var end_position := voice.stream_end_position
    if end_position <= 0.0:
        end_position = maxf(voice.stream.get_length(), 0.0)
    if end_position <= 0.0:
        return 0.0
    return maxf(end_position - playback_position, 0.0)


func _resolve_voice_end_position(clip: SfxClip, stream: AudioStream) -> float:
    if not stream:
        return 0.0

    var stream_length := maxf(stream.get_length(), 0.0)
    if stream_length <= 0.0:
        return 0.0

    var end_position := stream_length
    if clip.length > 0.0:
        end_position = minf(maxf(clip.stream_offset, 0.0) + clip.length, stream_length)
    return end_position


func _resolve_visual_clip_span(clip: SfxClip, stream: AudioStream, use_clip_length := true) -> float:
    if not clip:
        return 0.35
    if use_clip_length and clip.length > 0.0:
        return clip.length
    if stream:
        var stream_length := maxf(stream.get_length(), 0.0)
        if stream_length > 0.0:
            return maxf(stream_length - maxf(clip.stream_offset, 0.0), 0.0)
    if clip.stream:
        var clip_stream_length := maxf(clip.stream.get_length(), 0.0)
        if clip_stream_length > 0.0:
            return maxf(clip_stream_length - maxf(clip.stream_offset, 0.0), 0.0)
    return 0.35


func _wrap_or_clamp_position(position: float, span: float, stream: AudioStream) -> float:
    if span <= 0.0:
        return position
    if SfxStreamLoopSupport.is_looping(stream):
        return fposmod(position, span)
    return clampf(position, 0.0, span)


func _resolve_visual_clip_position(voice: ActiveVoice, playback_position: float, visible_span: float) -> float:
    if not voice or not voice.clip:
        return 0.0
    var position := maxf(playback_position - maxf(voice.clip.stream_offset, 0.0), 0.0)
    return _wrap_or_clamp_position(position, visible_span, voice.stream)


func _build_visual_clip_state(clip: SfxClip, voice: ActiveVoice, use_clip_length := true, instance: EventInstance = null) -> Dictionary:
    if not clip or not voice or not is_instance_valid(voice.player):
        return {
            "active": false,
            "visible_span": _resolve_visual_clip_span(clip, null, use_clip_length),
            "position": 0.0,
            "loops": false,
        }

    var visible_span: float = _resolve_visual_clip_span(clip, voice.stream, use_clip_length)
    var position: float
    if instance and clip.trigger_mode == SfxClip.TriggerMode.TRIGGER_TIMELINE:
        position = _wrap_or_clamp_position(maxf(instance.playback_time - maxf(clip.offset, 0.0), 0.0), visible_span, voice.stream)
    else:
        position = _resolve_visual_clip_position(voice, voice.player.get_playback_position(), visible_span)
    return {
        "active": true,
        "visible_span": visible_span,
        "position": position,
        "loops": SfxStreamLoopSupport.is_looping(voice.stream),
    }


func _resolve_tail_start_position(playback_position: float, end_position: float, was_looping: bool) -> float:
    if end_position <= 0.0:
        return 0.0
    if was_looping:
        return fposmod(playback_position, end_position)
    if playback_position >= end_position:
        return 0.0
    return clampf(playback_position, 0.0, end_position)


func _reuse_existing_voice_if_present(instance: EventInstance, clip: SfxClip, automation: SfxAutomation, automation_name: StringName) -> bool:
    if automation:
        var existing_voice := _find_voice(instance, clip, automation_name)
        if not existing_voice:
            return false
        if _automation_voice_is_releasing(existing_voice):
            _restart_automation_voice(existing_voice)
        else:
            _apply_voice_state(existing_voice)
        return true

    var time_voice := _find_voice(instance, clip)
    return true if time_voice else false


func _acquire_voice_player_and_stream(clip: SfxClip, automation: SfxAutomation) -> Dictionary:
    var player = _acquire_player_for_new_voice()
    if not player:
        return {}
    var stream := _build_clip_stream(clip, automation)
    if not stream:
        return {}
    return {"player": player, "stream": stream}


func _resolve_voice_positions(instance: EventInstance, clip: SfxClip, automation: SfxAutomation, stream: AudioStream) -> Dictionary:
    var start_position := _resolve_voice_start_position(instance, clip, automation)
    if automation:
        start_position = _resolve_phase_locked_automation_start_position(instance, clip, automation, stream)
    var stream_length := maxf(stream.get_length(), 0.0)
    if stream_length > 0.0:
        start_position = clampf(start_position, 0.0, stream_length)
    var end_position := _resolve_voice_end_position(clip, stream)
    if end_position > 0.0:
        start_position = minf(start_position, end_position)
    return {"start": start_position, "end": end_position}


func _setup_generator_voice(voice: ActiveVoice, player, clip: SfxClip) -> bool:
    voice.generator_playback = clip.generator_playback
    voice.generator_stream_playback = player.get_stream_playback() as AudioStreamGeneratorPlayback
    if not voice.generator_stream_playback:
        push_error("Failed to get AudioStreamGeneratorPlayback for generator clip")
        _reset_player(player, true)
        return false
    voice.generator_state = voice.generator_playback.create_state(voice.generator_stream_playback, clip)
    return true


func _start_voice(instance: EventInstance, clip: SfxClip, automation: SfxAutomation = null) -> bool:
    var automation_name := automation.parameter_name if automation else &""
    if _reuse_existing_voice_if_present(instance, clip, automation, automation_name):
        return true

    var acquired := _acquire_voice_player_and_stream(clip, automation)
    if acquired.is_empty():
        return false
    var player = acquired["player"]
    var stream: AudioStream = acquired["stream"]

    var positions := _resolve_voice_positions(instance, clip, automation, stream)
    var start_position: float = positions["start"]
    var end_position: float = positions["end"]

    player.stream = stream
    player.pitch_scale = 1.0
    var player_token := int(_player_tokens.get(player, 0)) + 1
    _player_tokens[player] = player_token
    player.play(start_position)

    var voice := ActiveVoice.new()
    voice.player = player
    voice.event_instance = instance
    voice.clip = clip
    voice.stream = stream
    voice.stream_start_position = start_position
    voice.stream_end_position = end_position
    voice.automation = automation
    voice.automation_name = automation_name
    voice.player_token = player_token
    voice.creation_order = _voice_creation_counter
    _voice_creation_counter += 1
    _enter_track_attack(voice)

    if stream is AudioStreamGenerator and not _setup_generator_voice(voice, player, clip):
        return false

    _active_voices.append(voice)
    _apply_voice_state(voice)
    _pump_generator_voice(voice, 0.0)
    return true


func _resolve_automation_raw_gain(voice: ActiveVoice) -> float:
    if not voice or not voice.automation or not voice.event_instance:
        return 1.0

    var automation_value = float(voice.event_instance.parameters.get(voice.automation_name, voice.automation.min_domain))
    var fade_in := clampf(_sample_automation_curve(voice.clip.fade_in_curve, automation_value, voice.clip.offset), 0.0, 1.0)
    var fade_out := clampf(_sample_automation_fade_out_curve(voice.clip.fade_out_curve, voice.clip, automation_value), 0.0, 1.0)

    if voice.automation.crossfade_mode == SfxAutomation.CrossfadeMode.EQUAL_POWER:
        return sqrt(fade_in) * sqrt(fade_out)
    return fade_in * fade_out


func _automation_crossfade_candidates(voice: ActiveVoice) -> Array[ActiveVoice]:
    var candidates: Array[ActiveVoice] = []
    for candidate in _active_voices:
        if not candidate or not candidate.automation:
            continue
        if _automation_voice_is_releasing(candidate):
            continue
        if not candidate.event_instance == voice.event_instance:
            continue
        if not candidate.automation_name == voice.automation_name:
            continue
        candidates.append(candidate)
    return candidates


func _resolve_automation_clip_gain(voice: ActiveVoice) -> float:
    var raw_gain := _resolve_automation_raw_gain(voice)
    if not voice or not voice.automation or not voice.event_instance:
        return raw_gain

    var equal_power := voice.automation.crossfade_mode == SfxAutomation.CrossfadeMode.EQUAL_POWER
    var gain_sum := 0.0
    for candidate in _automation_crossfade_candidates(voice):
        var candidate_gain := _resolve_automation_raw_gain(candidate)
        gain_sum += candidate_gain * candidate_gain if equal_power else candidate_gain

    if gain_sum <= 1.0:
        return raw_gain
    return raw_gain / sqrt(gain_sum) if equal_power else raw_gain / gain_sum


func _apply_voice_state(voice: ActiveVoice) -> void:
    if not voice or not is_instance_valid(voice.player):
        return

    var clip_gain := 1.0
    var pitch := 1.0
    if voice.automation:
        var automation_value = float(voice.event_instance.parameters.get(voice.automation_name, voice.automation.min_domain))
        if _automation_voice_is_releasing(voice):
            clip_gain = voice.automation_release_gain
        else:
            clip_gain = _resolve_automation_clip_gain(voice)
            voice.automation_current_gain = clip_gain
            voice.automation_release_gain = clip_gain
        pitch = _sample_automation_curve(voice.clip.pitch_curve, automation_value, voice.clip.offset)
        pitch *= _sample_automation_curve(voice.automation.pitch_curve, automation_value)
    else:
        var playback_position := 0.0
        if voice.player.playing:
            playback_position = voice.player.get_playback_position()
        var local_clip_time := _resolve_local_clip_time(voice, playback_position)
        var remaining_clip_time := _resolve_remaining_clip_time(voice, playback_position)
        clip_gain = clampf(_sample_curve_gain(voice.clip.fade_in_curve, local_clip_time), 0.0, 1.0)
        if voice.stopping:
            var stop_remaining := maxf(voice.stop_fade_duration - voice.stop_elapsed, 0.0)
            clip_gain *= clampf(_sample_time_fade_out_curve(voice.clip.fade_out_curve, stop_remaining), 0.0, 1.0)
        else:
            clip_gain *= clampf(_sample_time_fade_out_curve(voice.clip.fade_out_curve, remaining_clip_time), 0.0, 1.0)
        pitch = _sample_curve_gain(voice.clip.pitch_curve, local_clip_time)

    var mixer_gain := _resolve_track_mixer_gain(voice)
    _set_player_gain(voice.player, clampf(_current_adsr_gain(voice.event_instance), 0.0, 1.0) * clampf(_current_track_adsr_gain(voice), 0.0, 1.0) * clip_gain * mixer_gain)
    voice.player.pitch_scale = maxf(pitch, 0.01)


func _cleanup_voice(voice: ActiveVoice) -> void:
    if voice and voice.generator_playback:
        voice.generator_playback.cleanup(voice.generator_state)


func _voice_owns_player(voice: ActiveVoice) -> bool:
    if not voice or not is_instance_valid(voice.player):
        return false
    return int(_player_tokens.get(voice.player, 0)) == voice.player_token


func _release_voice(index: int) -> void:
    if index == -1:
        return

    var voice := _active_voices[index]
    _cleanup_voice(voice)
    if _voice_owns_player(voice):
        voice.player.volume_db = 0.0
        voice.player.pitch_scale = 1.0
    _active_voices.remove_at(index)

    if _active_voices.is_empty() and _instances.is_empty():
        finished.emit()


func _stop_voice(index: int) -> void:
    if index == -1:
        return

    var voice := _active_voices[index]
    var owns_player := _voice_owns_player(voice)
    _release_voice(index)
    if owns_player:
        _reset_player(voice.player, true)


func _reset_player(player, clear_stream := false) -> void:
    if not is_instance_valid(player):
        return
    player.stop()
    player.pitch_scale = 1.0
    player.volume_db = 0.0
    if clear_stream:
        player.stream = null


func _update_voice(index: int, delta: float) -> bool:
    if index < 0 or index >= _active_voices.size():
        return false

    var voice := _active_voices[index]
    if not voice.event_instance or not _has_instance(voice.event_instance):
        _stop_voice(index)
        return false

    if not is_instance_valid(voice.player) or (not voice.finish_on_end and not voice.player.playing):
        _release_voice(index)
        return false

    if voice.stopping:
        voice.stop_elapsed += delta
        if voice.stop_fade_duration <= 0.0 or voice.stop_elapsed >= voice.stop_fade_duration:
            _stop_voice(index)
            return false

    if voice.finish_on_end:
        voice.finish_elapsed += delta
        if voice.finish_duration <= 0.0 or voice.finish_elapsed >= voice.finish_duration:
            _stop_voice(index)
            return false

    _update_track_adsr(voice, delta)
    if voice.track_adsr.stage == AdsrStage.STOPPED:
        _stop_voice(index)
        return false

    if not voice.automation and voice.stream_end_position > 0.0 and voice.player.get_playback_position() >= voice.stream_end_position:
        _stop_voice(index)
        return false

    _apply_voice_state(voice)
    _pump_generator_voice(voice, delta)
    return true


func _stop_event_instance(instance: EventInstance, immediate: bool) -> void:
    if not instance:
        return

    if immediate:
        _stop_instance_voices(instance)
        _remove_instance(instance)
        if _active_voices.is_empty() and _instances.is_empty():
            finished.emit()
        return

    if instance.status == PlaybackStatus.RELEASING:
        return

    instance.status = PlaybackStatus.RELEASING
    instance.release_time = 0.0
    instance.adsr.release_start_gain = _current_adsr_gain(instance)
    if instance.event.adsr_enabled and instance.event.release > 0.0:
        instance.adsr.stage = AdsrStage.RELEASE
    else:
        instance.adsr.stage = AdsrStage.SUSTAIN
        _begin_instance_voice_stop(instance)
    instance.adsr.elapsed = 0.0
    _refresh_sustain_clips(instance, -1.0, instance.release_time)


func _collect_finished_instances() -> void:
    var finished_instances: Array[EventInstance] = []
    for raw_instances in _instances.values():
        for raw_instance in raw_instances:
            var instance := raw_instance as EventInstance
            if not instance:
                continue

            if instance.status == PlaybackStatus.RELEASING and instance.adsr.stage == AdsrStage.STOPPED:
                finished_instances.append(instance)
                continue

            if instance.status == PlaybackStatus.PLAYING:
                if not _instance_has_pending_play_activity(instance):
                    finished_instances.append(instance)
                continue

            if instance.status == PlaybackStatus.RELEASING and not _instance_has_pending_release_activity(instance):
                finished_instances.append(instance)
                continue

    for instance in finished_instances:
        _remove_instance(instance)

    if _active_voices.is_empty() and _instances.is_empty():
        finished.emit()


func _notify_process_requirement_changed() -> void:
    process_requirement_changed.emit(requires_process())


func _voices_for_instance(instance: EventInstance) -> Array[ActiveVoice]:
    var voices: Array[ActiveVoice] = []
    for voice in _active_voices:
        if voice.event_instance == instance:
            voices.append(voice)
    return voices


func _instance_has_pending_release_activity(instance: EventInstance) -> bool:
    return instance and not _voices_for_instance(instance).is_empty()


func _instance_has_pending_play_activity(instance: EventInstance) -> bool:
    if not instance:
        return false

    if not _voices_for_instance(instance).is_empty():
        return true

    for clip in instance.event.clips:
        if not clip:
            continue
        if clip.trigger_mode == SfxClip.TriggerMode.TRIGGER_SUSTAIN:
            if not instance.triggered_sustain_clips.has(clip):
                return true
            continue
        if clip.trigger_mode == SfxClip.TriggerMode.TRIGGER_TIMELINE:
            if instance.triggered_event_clips.has(clip):
                continue
            if clip.offset >= instance.playback_time:
                return true

    for automation in instance.event.automations:
        if not automation:
            continue
        var automation_name := automation.parameter_name
        if not automation_name:
            continue
        var triggered_clips: Array = instance.triggered_automation_clips.get(automation_name, [])
        for clip in automation.clips:
            if not clip:
                continue
            if not clip.trigger_mode == SfxClip.TriggerMode.TRIGGER_TIMELINE:
                continue
            if not triggered_clips.has(clip):
                return true

    return false


func _stop_instance_voices(instance: EventInstance) -> void:
    for voice in _voices_for_instance(instance):
        _stop_voice(_active_voices.find(voice))


func _begin_instance_voice_stop(instance: EventInstance) -> void:
    for voice in _voices_for_instance(instance):
        if not _begin_voice_stop(voice):
            _stop_voice(_active_voices.find(voice))


func _begin_voice_stop(voice: ActiveVoice) -> bool:
    if not voice:
        return false
    if voice.automation:
        return _begin_automation_voice_stop(voice)
    if _begin_track_release(voice):
        _apply_voice_state(voice)
        return true
    var fade_duration := _get_curve_duration(voice.clip.fade_out_curve)
    if fade_duration <= 0.0:
        return false
    voice.stopping = true
    voice.stop_elapsed = 0.0
    voice.stop_fade_duration = fade_duration
    _apply_voice_state(voice)
    return true


func _automation_voice_is_releasing(voice: ActiveVoice) -> bool:
    if not voice:
        return false
    return voice.stopping or voice.finish_on_end or voice.track_adsr.stage == AdsrStage.RELEASE or voice.track_adsr.stage == AdsrStage.STOPPED


func _begin_automation_voice_stop(voice: ActiveVoice) -> bool:
    if not voice:
        return false
    voice.automation_release_gain = voice.automation_current_gain
    if _begin_track_release(voice):
        _apply_voice_state(voice)
        return true
    return false


func _stop_automation_voice(voice: ActiveVoice) -> void:
    if not voice:
        return
    if _begin_automation_voice_stop(voice):
        return
    _stop_voice(_find_active_voice_index(voice.player))


func _finish_automation_voice_on_end(voice: ActiveVoice) -> void:
    if not voice or not is_instance_valid(voice.player):
        return
    var playback_position: float = voice.player.get_playback_position()
    var was_looping := SfxStreamLoopSupport.is_looping(voice.stream)
    if was_looping and voice.stream == voice.clip.stream:
        var stream := voice.stream.duplicate(true) as AudioStream if voice.stream else null
        if stream:
            voice.stream = stream
            voice.player.stream = stream
    voice.automation_release_gain = voice.automation_current_gain
    voice.finish_on_end = true
    voice.finish_elapsed = 0.0
    voice.stream_end_position = maxf(voice.stream.get_length(), 0.0) if voice.stream else 0.0
    SfxStreamLoopSupport.set_looping(voice.stream, false)
    if voice.stream_end_position > 0.0:
        playback_position = _resolve_tail_start_position(playback_position, voice.stream_end_position, was_looping)
        voice.finish_duration = maxf(voice.stream_end_position - playback_position, 0.0)
        voice.player.play(playback_position)
    _apply_voice_state(voice)


func _restart_automation_voice(voice: ActiveVoice) -> void:
    if not voice or not voice.event_instance or not voice.clip or not voice.automation:
        return
    if not is_instance_valid(voice.player):
        return

    var stream := voice.stream
    if voice.finish_on_end:
        stream = _build_clip_stream(voice.clip, voice.automation)
        if not stream:
            return
        voice.stream = stream
        voice.player.stream = stream

    var start_position := _resolve_voice_start_position(voice.event_instance, voice.clip, voice.automation)
    if voice.automation:
        start_position = _resolve_phase_locked_automation_start_position(voice.event_instance, voice.clip, voice.automation, stream)
    var stream_length := maxf(stream.get_length(), 0.0) if stream else 0.0
    if stream_length > 0.0:
        start_position = clampf(start_position, 0.0, stream_length)
    var end_position := _resolve_voice_end_position(voice.clip, stream)
    if end_position > 0.0:
        start_position = minf(start_position, end_position)

    voice.stream_start_position = start_position
    voice.stream_end_position = end_position
    voice.stopping = false
    voice.finish_on_end = false
    voice.finish_elapsed = 0.0
    voice.finish_duration = 0.0
    voice.stop_elapsed = 0.0
    voice.stop_fade_duration = 0.0
    voice.automation_current_gain = 1.0
    voice.automation_release_gain = 1.0
    voice.player.play(start_position)
    _enter_track_attack(voice)
    _apply_voice_state(voice)
