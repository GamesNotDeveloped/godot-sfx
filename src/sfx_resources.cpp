#include "sfx_resources.hpp"

#include <godot_cpp/classes/audio_stream_mp3.hpp>
#include <godot_cpp/classes/audio_stream_ogg_vorbis.hpp>
#include <godot_cpp/classes/audio_stream_wav.hpp>

using namespace godot;

#define SFX_BIND(m_class, m_name, ...)                                                             \
    ClassDB::bind_method(D_METHOD("set_" #m_name, "value"), &m_class::set_##m_name);               \
    ClassDB::bind_method(D_METHOD("get_" #m_name), &m_class::get_##m_name);                        \
    ADD_PROPERTY(PropertyInfo(__VA_ARGS__), "set_" #m_name, "get_" #m_name)
#define SFX_BIND_FLOAT(m_class, m_name, m_range)                                                   \
    SFX_BIND(m_class, m_name, Variant::FLOAT, #m_name, PROPERTY_HINT_RANGE, m_range)
#define SFX_BIND_RES(m_class, m_name, m_type)                                                      \
    SFX_BIND(m_class, m_name, Variant::OBJECT, #m_name, PROPERTY_HINT_RESOURCE_TYPE, m_type)
#define SFX_BIND_LIST(m_class, m_name, m_type)                                                     \
    SFX_BIND(m_class, m_name, Variant::ARRAY, #m_name, PROPERTY_HINT_ARRAY_TYPE, m_type)
#define SFX_BIND_PLAIN(m_class, m_name, m_variant) SFX_BIND(m_class, m_name, m_variant, #m_name)

static const char *ADSR_RANGE = "0,30,0.01";
static const char *UNIT_RANGE = "0,1,0.01";
static const char *ANY_RANGE = "-1000000,1000000,0.001,or_less,or_greater";
static const char *ATTENUATION_HINT = "Inverse Distance,Inverse Square Distance,Logarithmic,Disabled";

void SfxGeneratorPlayback::_bind_methods() {
    GDVIRTUAL_BIND(_create_state, "playback", "clip");
    GDVIRTUAL_BIND(_update, "state", "context");
    GDVIRTUAL_BIND(_cleanup, "state");
}

void SfxTrack::_bind_methods() {
    SFX_BIND_PLAIN(SfxTrack, track_name, Variant::STRING_NAME);
    SFX_BIND_FLOAT(SfxTrack, volume_db, "-80,24,0.01,suffix:dB");
    SFX_BIND_PLAIN(SfxTrack, mute, Variant::BOOL);
    SFX_BIND_PLAIN(SfxTrack, solo, Variant::BOOL);
    SFX_BIND_PLAIN(SfxTrack, adsr_enabled, Variant::BOOL);
    SFX_BIND_FLOAT(SfxTrack, attack, ADSR_RANGE);
    SFX_BIND_FLOAT(SfxTrack, decay, ADSR_RANGE);
    SFX_BIND_FLOAT(SfxTrack, sustain, UNIT_RANGE);
    SFX_BIND_FLOAT(SfxTrack, release, ADSR_RANGE);
}

void SfxClip::set_stream(const Ref<AudioStream> &p_stream) {
    stream = p_stream;
    drain_stream.unref();
    emit_changed();
}

void SfxClip::prepare() {
    if (drain_stream.is_null() && SfxStreamLoopSupport::is_looping(stream)) {
        drain_stream = stream->duplicate();
        SfxStreamLoopSupport::set_looping(drain_stream, false);
    }
}

void SfxClip::_bind_methods() {
    BIND_ENUM_CONSTANT(TRIGGER_TIMELINE);
    BIND_ENUM_CONSTANT(TRIGGER_SUSTAIN);
    SFX_BIND_RES(SfxClip, stream, "AudioStream");
    SFX_BIND_RES(SfxClip, generator_playback, "SfxGeneratorPlayback");
    SFX_BIND_FLOAT(SfxClip, offset, ANY_RANGE);
    SFX_BIND_FLOAT(SfxClip, length, ANY_RANGE);
    SFX_BIND_FLOAT(SfxClip, stream_offset, ANY_RANGE);
    SFX_BIND_FLOAT(SfxClip, phase_offset, ANY_RANGE);
    SFX_BIND_RES(SfxClip, fade_in_curve, "Curve");
    SFX_BIND_RES(SfxClip, fade_out_curve, "Curve");
    SFX_BIND_RES(SfxClip, pitch_curve, "Curve");
    SFX_BIND(SfxClip, trigger_mode, Variant::INT, "trigger_mode", PROPERTY_HINT_ENUM, "Timeline,Sustain");
    SFX_BIND_PLAIN(SfxClip, bookend, Variant::BOOL);
    SFX_BIND_PLAIN(SfxClip, cut, Variant::BOOL);
    SFX_BIND_RES(SfxClip, track, "SfxTrack");
}

void SfxAutomation::_bind_methods() {
    BIND_ENUM_CONSTANT(LINEAR);
    BIND_ENUM_CONSTANT(EQUAL_POWER);
    SFX_BIND(SfxAutomation, crossfade_mode, Variant::INT, "crossfade_mode", PROPERTY_HINT_ENUM, "Linear,Equal Power");
    SFX_BIND_PLAIN(SfxAutomation, parameter_name, Variant::STRING_NAME);
    SFX_BIND_LIST(SfxAutomation, clips, "SfxClip");
    SFX_BIND_FLOAT(SfxAutomation, min_domain, ANY_RANGE);
    SFX_BIND_FLOAT(SfxAutomation, max_domain, ANY_RANGE);
    SFX_BIND_RES(SfxAutomation, pitch_curve, "Curve");
    SFX_BIND_PLAIN(SfxAutomation, phase_locked, Variant::BOOL);
    SFX_BIND_FLOAT(SfxAutomation, phase_period, ANY_RANGE);
    SFX_BIND_PLAIN(SfxAutomation, latch_on_start, Variant::BOOL);
}

void SfxParameterModulation::_bind_methods() {
    BIND_ENUM_CONSTANT(GAIN);
    BIND_ENUM_CONSTANT(PITCH);
    BIND_ENUM_CONSTANT(UNIT_SIZE);
    SFX_BIND_PLAIN(SfxParameterModulation, parameter_name, Variant::STRING_NAME);
    SFX_BIND(SfxParameterModulation, target, Variant::INT, "target", PROPERTY_HINT_ENUM, "Gain,Pitch,Unit Size");
    SFX_BIND_FLOAT(SfxParameterModulation, min_domain, ANY_RANGE);
    SFX_BIND_FLOAT(SfxParameterModulation, max_domain, ANY_RANGE);
    SFX_BIND_FLOAT(SfxParameterModulation, default_value, ANY_RANGE);
    SFX_BIND_RES(SfxParameterModulation, curve, "Curve");
}

void SfxSpatialConfig::_bind_methods() {
    SFX_BIND_PLAIN(SfxSpatialConfig, position, Variant::VECTOR3);
    SFX_BIND(SfxSpatialConfig, attenuation_model, Variant::INT, "attenuation_model", PROPERTY_HINT_ENUM, ATTENUATION_HINT);
    SFX_BIND_FLOAT(SfxSpatialConfig, unit_size, "0.01,100,0.01,or_greater");
    SFX_BIND_FLOAT(SfxSpatialConfig, max_distance, "-1,4096,0.01,or_greater");
    SFX_BIND_FLOAT(SfxSpatialConfig, panning_strength, "0,3,0.01");
}

void SfxParameterTrigger::_bind_methods() {
    BIND_ENUM_CONSTANT(GATE);
    BIND_ENUM_CONSTANT(CROSS);
    BIND_ENUM_CONSTANT(STEP);
    BIND_ENUM_CONSTANT(EVERY);
    BIND_ENUM_CONSTANT(BOTH);
    BIND_ENUM_CONSTANT(UP);
    BIND_ENUM_CONSTANT(DOWN);
    SFX_BIND_PLAIN(SfxParameterTrigger, parameter, Variant::STRING_NAME);
    SFX_BIND(SfxParameterTrigger, mode, Variant::INT, "mode", PROPERTY_HINT_ENUM, "Gate,Cross,Step,Every");
    SFX_BIND_FLOAT(SfxParameterTrigger, on_threshold, ANY_RANGE);
    SFX_BIND_FLOAT(SfxParameterTrigger, off_threshold, ANY_RANGE);
    SFX_BIND_FLOAT(SfxParameterTrigger, step, "0.000001,1000000,0.000001,or_greater");
    SFX_BIND(SfxParameterTrigger, direction, Variant::INT, "direction", PROPERTY_HINT_ENUM, "Both,Up,Down");
    SFX_BIND_FLOAT(SfxParameterTrigger, min_interval, "0,60,0.001,or_greater,suffix:s");
    SFX_BIND_FLOAT(SfxParameterTrigger, resume_offset, "0,600,0.001,or_greater,suffix:s");
    SFX_BIND_PLAIN(SfxParameterTrigger, exclusive, Variant::BOOL);
}

SfxEvent::SfxEvent() {
    master_track.instantiate();
    master_track->track_name = "Master";
}

void SfxEvent::prepare() {
    for (const Ref<SfxClip> &clip : clips.items) {
        if (clip.is_valid()) {
            clip->prepare();
        }
    }
    for (const Ref<SfxAutomation> &automation : automations.items) {
        if (automation.is_null()) {
            continue;
        }
        for (const Ref<SfxClip> &clip : automation->clips.items) {
            if (clip.is_valid()) {
                clip->prepare();
            }
        }
    }
}

void SfxEvent::_bind_methods() {
    SFX_BIND_LIST(SfxEvent, clips, "SfxClip");
    SFX_BIND_LIST(SfxEvent, tracks, "SfxTrack");
    // made by the editor for a new event; without one a clip with no track plays at unity
    SFX_BIND(SfxEvent, master_track, Variant::OBJECT, "master_track", PROPERTY_HINT_RESOURCE_TYPE, "SfxTrack",
            PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_EDITOR_INSTANTIATE_OBJECT);
    SFX_BIND_PLAIN(SfxEvent, polyphony_enabled, Variant::BOOL);
    SFX_BIND_PLAIN(SfxEvent, adsr_enabled, Variant::BOOL);
    SFX_BIND_FLOAT(SfxEvent, attack, ADSR_RANGE);
    SFX_BIND_FLOAT(SfxEvent, decay, ADSR_RANGE);
    SFX_BIND_FLOAT(SfxEvent, sustain, UNIT_RANGE);
    SFX_BIND_FLOAT(SfxEvent, release, ADSR_RANGE);
    SFX_BIND_PLAIN(SfxEvent, name, Variant::STRING_NAME);
    SFX_BIND_LIST(SfxEvent, automations, "SfxAutomation");
    SFX_BIND_LIST(SfxEvent, parameter_modulations, "SfxParameterModulation");
    SFX_BIND_LIST(SfxEvent, triggers, "SfxParameterTrigger");
    SFX_BIND_RES(SfxEvent, spatial_config, "SfxSpatialConfig");
    SFX_BIND_FLOAT(SfxEvent, start_fraction, "0,1,0.001");
    SFX_BIND_FLOAT(SfxEvent, pitch_variation, "0.5,2,0.001");
}

void SfxParameter::_bind_methods() {
    SFX_BIND_PLAIN(SfxParameter, name, Variant::STRING_NAME);
    SFX_BIND_FLOAT(SfxParameter, min_value, ANY_RANGE);
    SFX_BIND_FLOAT(SfxParameter, max_value, ANY_RANGE);
    SFX_BIND_FLOAT(SfxParameter, default_value, ANY_RANGE);
}

void SfxDerivedParameter::_bind_methods() {
    BIND_ENUM_CONSTANT(NONE);
    BIND_ENUM_CONSTANT(SMOOTH);
    BIND_ENUM_CONSTANT(DERIVATIVE);
    SFX_BIND_PLAIN(SfxDerivedParameter, name, Variant::STRING_NAME);
    SFX_BIND(SfxDerivedParameter, expression, Variant::STRING, "expression", PROPERTY_HINT_EXPRESSION, "");
    SFX_BIND_PLAIN(SfxDerivedParameter, inputs, Variant::PACKED_STRING_ARRAY);
    SFX_BIND(SfxDerivedParameter, filter, Variant::INT, "filter", PROPERTY_HINT_ENUM, "None,Smooth,Derivative");
    SFX_BIND_FLOAT(SfxDerivedParameter, time_constant, "0.001,60,0.001,or_greater,suffix:s");
}

void SfxBank::set_events(const TypedArray<SfxEvent> &p_events) {
    events.set(p_events);
    event_cache.clear();
    for (const Ref<SfxEvent> &event : events.items) {
        if (event.is_valid() && !event->name.is_empty()) {
            event_cache[event->name] = event;
        }
    }
    emit_changed();
}

Ref<SfxEvent> SfxBank::get_event(const StringName &p_name) const {
    const Ref<SfxEvent> *event = event_cache.getptr(p_name);
    return event ? *event : Ref<SfxEvent>();
}

void SfxBank::_bind_methods() {
    SFX_BIND_LIST(SfxBank, events, "SfxEvent");
    SFX_BIND_LIST(SfxBank, parameters, "SfxParameter");
    SFX_BIND_LIST(SfxBank, derived_parameters, "SfxDerivedParameter");
    ClassDB::bind_method(D_METHOD("get_event", "event_name"), &SfxBank::get_event);
}

bool SfxStreamLoopSupport::is_looping(const Ref<AudioStream> &p_stream) {
    if (AudioStreamWAV *wav = Object::cast_to<AudioStreamWAV>(p_stream.ptr())) {
        return wav->get_loop_mode() != AudioStreamWAV::LOOP_DISABLED;
    }
    if (AudioStreamOggVorbis *ogg = Object::cast_to<AudioStreamOggVorbis>(p_stream.ptr())) {
        return ogg->has_loop();
    }
    if (AudioStreamMP3 *mp3 = Object::cast_to<AudioStreamMP3>(p_stream.ptr())) {
        return mp3->has_loop();
    }
    return p_stream.is_valid() && bool(p_stream->get("loop"));
}

void SfxStreamLoopSupport::set_looping(const Ref<AudioStream> &p_stream, bool p_enabled) {
    if (AudioStreamWAV *wav = Object::cast_to<AudioStreamWAV>(p_stream.ptr())) {
        wav->set_loop_mode(p_enabled ? AudioStreamWAV::LOOP_FORWARD : AudioStreamWAV::LOOP_DISABLED);
    } else if (p_stream.is_valid()) {
        p_stream->set("loop", p_enabled);
    }
}

bool SfxStreamLoopSupport::supports_persisted_loop_offset(const Ref<AudioStream> &p_stream) {
    return Object::cast_to<AudioStreamOggVorbis>(p_stream.ptr()) || Object::cast_to<AudioStreamMP3>(p_stream.ptr());
}

bool SfxStreamLoopSupport::set_persisted_loop_offset(const Ref<AudioStream> &p_stream, double p_offset) {
    if (!supports_persisted_loop_offset(p_stream)) {
        return false;
    }
    p_stream->set("loop_offset", p_offset);
    return true;
}

Vector2 SfxStreamLoopSupport::get_loop_region(const Ref<AudioStream> &p_stream) {
    double length = p_stream.is_valid() ? p_stream->get_length() : 0.0;
    if (AudioStreamWAV *wav = Object::cast_to<AudioStreamWAV>(p_stream.ptr())) {
        double rate = MAX(wav->get_mix_rate(), 1);
        double end = wav->get_loop_end() > 0 ? MIN(wav->get_loop_end() / rate, length) : length;
        return Vector2(MIN(wav->get_loop_begin() / rate, end), end);
    }
    if (supports_persisted_loop_offset(p_stream)) {
        return Vector2(MIN(double(p_stream->get("loop_offset")), length), length);
    }
    return Vector2(0, length);
}

void SfxStreamLoopSupport::_bind_methods() {
    ClassDB::bind_static_method("SfxStreamLoopSupport", D_METHOD("is_looping", "stream"), &SfxStreamLoopSupport::is_looping);
    ClassDB::bind_static_method("SfxStreamLoopSupport", D_METHOD("set_looping", "stream", "enabled"), &SfxStreamLoopSupport::set_looping);
    ClassDB::bind_static_method("SfxStreamLoopSupport", D_METHOD("supports_persisted_loop_offset", "stream"),
            &SfxStreamLoopSupport::supports_persisted_loop_offset);
    ClassDB::bind_static_method("SfxStreamLoopSupport", D_METHOD("set_persisted_loop_offset", "stream", "offset"),
            &SfxStreamLoopSupport::set_persisted_loop_offset);
    ClassDB::bind_static_method("SfxStreamLoopSupport", D_METHOD("get_loop_region", "stream"), &SfxStreamLoopSupport::get_loop_region);
}
