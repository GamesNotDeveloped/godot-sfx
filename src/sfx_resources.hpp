#pragma once

// The data of a sound bank. Plain values with public fields: the playback runtime reads them
// directly on a worker thread, the setters (main thread, editor/inspector) only store and emit
// `changed`. Arrays of resources keep a C++ mirror (RefList) so a tick never converts Variants.

#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_generator_playback.hpp>
#include <godot_cpp/classes/curve.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/gdvirtual.gen.inc>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/templates/local_vector.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

// A resource array as the inspector sees it plus the same refs for C++. Assign, never mutate in place
template <class T> struct RefList {
    TypedArray<T> array;
    LocalVector<Ref<T>> items;
    void set(const TypedArray<T> &p_array) {
        array = p_array;
        items.clear();
        for (int64_t i = 0; i < p_array.size(); i++) {
            items.push_back(p_array[i]);
        }
    }
};

#define SFX_VALUE(m_type, m_name, m_default)                                                       \
public:                                                                                            \
    m_type m_name = m_default;                                                                     \
    void set_##m_name(m_type p_value) {                                                            \
        m_name = p_value;                                                                          \
        emit_changed();                                                                            \
    }                                                                                              \
    m_type get_##m_name() const { return m_name; }

#define SFX_LIST(m_type, m_name)                                                                   \
public:                                                                                            \
    RefList<m_type> m_name;                                                                        \
    void set_##m_name(const TypedArray<m_type> &p_value) {                                         \
        m_name.set(p_value);                                                                       \
        emit_changed();                                                                            \
    }                                                                                              \
    TypedArray<m_type> get_##m_name() const { return m_name.array; }

// Mixer channel of clips: mute/solo/volume and an ADSR of its own
class SfxTrack : public Resource {
    GDCLASS(SfxTrack, Resource);
    SFX_VALUE(StringName, track_name, StringName())
    SFX_VALUE(double, volume_db, 0.0)
    SFX_VALUE(bool, mute, false)
    SFX_VALUE(bool, solo, false)
    SFX_VALUE(bool, adsr_enabled, false)
    SFX_VALUE(double, attack, 0.0)
    SFX_VALUE(double, decay, 0.0)
    SFX_VALUE(double, sustain, 1.0)
    SFX_VALUE(double, release, 0.0)

protected:
    static void _bind_methods();
};

class SfxClip : public Resource {
    GDCLASS(SfxClip, Resource);

public:
    enum TriggerMode { TRIGGER_TIMELINE, TRIGGER_SUSTAIN };
    // an SfxGeneratorPlayback (declared after this class, which it takes as an argument)
    SFX_VALUE(Ref<Resource>, generator_playback, Ref<Resource>())
    SFX_VALUE(double, offset, 0.0)
    SFX_VALUE(double, length, 0.0)
    SFX_VALUE(double, stream_offset, 0.0)
    SFX_VALUE(double, phase_offset, 0.0)
    SFX_VALUE(Ref<Curve>, fade_in_curve, Ref<Curve>())
    SFX_VALUE(Ref<Curve>, fade_out_curve, Ref<Curve>())
    SFX_VALUE(Ref<Curve>, pitch_curve, Ref<Curve>())
    SFX_VALUE(TriggerMode, trigger_mode, TRIGGER_TIMELINE)
    SFX_VALUE(bool, bookend, false)
    SFX_VALUE(bool, cut, true)
    SFX_VALUE(Ref<SfxTrack>, track, Ref<SfxTrack>())

public:
    Ref<AudioStream> stream;
    // The stream without its loop, for a voice that plays out the lap it is in (an automation
    // clip with cut off). Made once by prepare(), on the main thread - never on a worker
    Ref<AudioStream> drain_stream;
    void set_stream(const Ref<AudioStream> &p_stream);
    Ref<AudioStream> get_stream() const { return stream; }
    void prepare();

protected:
    static void _bind_methods();
};

class SfxAutomation : public Resource {
    GDCLASS(SfxAutomation, Resource);

public:
    enum CrossfadeMode { LINEAR, EQUAL_POWER };
    SFX_VALUE(CrossfadeMode, crossfade_mode, LINEAR)
    SFX_VALUE(StringName, parameter_name, StringName())
    SFX_LIST(SfxClip, clips)
    SFX_VALUE(double, min_domain, 0.0)
    SFX_VALUE(double, max_domain, 1.0)
    SFX_VALUE(Ref<Curve>, pitch_curve, Ref<Curve>())
    SFX_VALUE(bool, phase_locked, false)
    SFX_VALUE(double, phase_period, 0.0)
    SFX_VALUE(bool, latch_on_start, false)

protected:
    static void _bind_methods();
};

class SfxParameterModulation : public Resource {
    GDCLASS(SfxParameterModulation, Resource);

public:
    enum Target { GAIN, PITCH, UNIT_SIZE };
    SFX_VALUE(StringName, parameter_name, StringName())
    SFX_VALUE(Target, target, GAIN)
    SFX_VALUE(double, min_domain, 0.0)
    SFX_VALUE(double, max_domain, 1.0)
    SFX_VALUE(double, default_value, 0.0)
    SFX_VALUE(Ref<Curve>, curve, Ref<Curve>())

protected:
    static void _bind_methods();
};

class SfxSpatialConfig : public Resource {
    GDCLASS(SfxSpatialConfig, Resource);
    SFX_VALUE(Vector3, position, Vector3())
    SFX_VALUE(int, attenuation_model, 0)
    SFX_VALUE(double, unit_size, 10.0)
    SFX_VALUE(double, max_distance, -1.0)
    SFX_VALUE(double, panning_strength, 1.0)

protected:
    static void _bind_methods();
};

// Starts or stops its event from a parameter of the player (see SfxEvent.triggers)
class SfxParameterTrigger : public Resource {
    GDCLASS(SfxParameterTrigger, Resource);

public:
    enum Mode { GATE, CROSS, STEP, EVERY };
    enum Direction { BOTH, UP, DOWN };
    SFX_VALUE(StringName, parameter, StringName())
    SFX_VALUE(Mode, mode, GATE)
    SFX_VALUE(double, on_threshold, 0.0)
    SFX_VALUE(double, off_threshold, 0.0)
    SFX_VALUE(double, step, 1.0)
    SFX_VALUE(Direction, direction, BOTH)
    SFX_VALUE(double, min_interval, 0.0)
    SFX_VALUE(double, resume_offset, 0.0)
    // A fire is skipped while the event still plays (MaSzyna's exclusive sounds)
    SFX_VALUE(bool, exclusive, false)

protected:
    static void _bind_methods();
};

class SfxEvent : public Resource {
    GDCLASS(SfxEvent, Resource);
    SFX_LIST(SfxClip, clips)
    SFX_LIST(SfxTrack, tracks)
    SFX_VALUE(Ref<SfxTrack>, master_track, Ref<SfxTrack>())
    SFX_VALUE(bool, polyphony_enabled, true)
    SFX_VALUE(bool, adsr_enabled, false)
    SFX_VALUE(double, attack, 0.0)
    SFX_VALUE(double, decay, 0.0)
    SFX_VALUE(double, sustain, 1.0)
    SFX_VALUE(double, release, 0.0)
    SFX_VALUE(StringName, name, StringName())
    SFX_LIST(SfxAutomation, automations)
    SFX_LIST(SfxParameterModulation, parameter_modulations)
    SFX_LIST(SfxParameterTrigger, triggers)
    SFX_VALUE(Ref<SfxSpatialConfig>, spatial_config, Ref<SfxSpatialConfig>())
    SFX_VALUE(double, start_fraction, 0.0)
    SFX_VALUE(double, pitch_variation, 1.0)

public:
    // Makes what a worker must not make (SfxClip::prepare) for every clip of the event
    void prepare();

protected:
    static void _bind_methods();
};

// A parameter of the player, declared by the bank: every event of the bank reads it
class SfxParameter : public Resource {
    GDCLASS(SfxParameter, Resource);
    SFX_VALUE(StringName, name, StringName())
    SFX_VALUE(double, min_value, 0.0)
    SFX_VALUE(double, max_value, 1.0)
    SFX_VALUE(double, default_value, 0.0)

protected:
    static void _bind_methods();
};

// A parameter computed from others: an Expression of `inputs` (plus `previous`, its own last value,
// and `delta`, the seconds since), then a filter over time
class SfxDerivedParameter : public Resource {
    GDCLASS(SfxDerivedParameter, Resource);

public:
    enum Filter { NONE, SMOOTH, DERIVATIVE };
    SFX_VALUE(StringName, name, StringName())
    SFX_VALUE(String, expression, String())
    SFX_VALUE(PackedStringArray, inputs, PackedStringArray())
    SFX_VALUE(Filter, filter, NONE)
    SFX_VALUE(double, time_constant, 0.1)

protected:
    static void _bind_methods();
};

class SfxBank : public Resource {
    GDCLASS(SfxBank, Resource);
    SFX_LIST(SfxParameter, parameters)
    SFX_LIST(SfxDerivedParameter, derived_parameters)

public:
    RefList<SfxEvent> events;
    HashMap<StringName, Ref<SfxEvent>> event_cache;
    void set_events(const TypedArray<SfxEvent> &p_events);
    TypedArray<SfxEvent> get_events() const { return events.array; }
    Ref<SfxEvent> get_event(const StringName &p_name) const;

protected:
    static void _bind_methods();
};

// Base of a synthesized clip (an AudioStreamGenerator stream). One resource may serve many voices
// at once, so per-voice state lives in what _create_state returns. _update runs on a worker thread
class SfxGeneratorPlayback : public Resource {
    GDCLASS(SfxGeneratorPlayback, Resource);

public:
    GDVIRTUAL2R(Variant, _create_state, Ref<AudioStreamGeneratorPlayback>, Ref<SfxClip>)
    GDVIRTUAL2(_update, Variant, Dictionary)
    GDVIRTUAL1(_cleanup, Variant)

protected:
    static void _bind_methods();
};

// Loop handling of the stream types that have one (WAV, Ogg Vorbis, MP3)
class SfxStreamLoopSupport : public Object {
    GDCLASS(SfxStreamLoopSupport, Object);

public:
    static bool is_looping(const Ref<AudioStream> &p_stream);
    static void set_looping(const Ref<AudioStream> &p_stream, bool p_enabled);
    static bool supports_persisted_loop_offset(const Ref<AudioStream> &p_stream);
    static bool set_persisted_loop_offset(const Ref<AudioStream> &p_stream, double p_offset);
    // Where a looping stream wraps, in seconds: x the loop start, y its end
    static Vector2 get_loop_region(const Ref<AudioStream> &p_stream);

protected:
    static void _bind_methods();
};

} // namespace godot

VARIANT_ENUM_CAST(SfxClip::TriggerMode);
VARIANT_ENUM_CAST(SfxAutomation::CrossfadeMode);
VARIANT_ENUM_CAST(SfxParameterModulation::Target);
VARIANT_ENUM_CAST(SfxParameterTrigger::Mode);
VARIANT_ENUM_CAST(SfxParameterTrigger::Direction);
VARIANT_ENUM_CAST(SfxDerivedParameter::Filter);
