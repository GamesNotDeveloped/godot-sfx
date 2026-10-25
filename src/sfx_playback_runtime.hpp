#pragma once

// The playback engine behind SfxPlayer/SfxPlayer3D, one per player. It touches no node: it writes
// Slots (what each audio node should do), which SfxPlayerCore copies into the nodes on the main
// thread. update() runs on a worker thread (GndSfxServer) or, in the editor, in the node's own
// _process. Nothing below update() may reach the scene tree or emit a signal.
//
// It is ticked only while something changes: a voice in a steady state (a held loop, a one-shot
// between its fades) needs no update, and next_wake says when the next one is due. The position
// of a voice is not read back from its node - it follows from the clock and the pitch (Slot).
//
// Vocabulary: an Instance is one playing of an SfxEvent (play() makes one); a Voice is one Slot
// playing one SfxClip for one Instance; automation voices follow a parameter instead of the clock.

#include "sfx_resources.hpp"

#include <godot_cpp/classes/expression.hpp>
#include <godot_cpp/classes/ref_counted.hpp>

#include <memory>
#include <vector>

namespace godot {

class SfxPlaybackRuntime : public RefCounted {
    GDCLASS(SfxPlaybackRuntime, RefCounted);

public:
    enum AdsrStage { ADSR_IDLE, ADSR_ATTACK, ADSR_DECAY, ADSR_SUSTAIN, ADSR_RELEASE, ADSR_STOPPED };
    enum Status { STATUS_STOPPED, STATUS_PLAYING, STATUS_RELEASING };
    enum Transport { TRANSPORT_IDLE, TRANSPORT_PLAY, TRANSPORT_STOP };
    // What SfxPlayerCore still has to copy into a node
    enum Dirty { DIRTY_STREAM = 1, DIRTY_TRANSPORT = 2, DIRTY_GAIN = 4, DIRTY_PITCH = 8, DIRTY_SPATIAL = 16 };

    struct Adsr {
        AdsrStage stage = ADSR_IDLE;
        double elapsed = 0.0, release_start_gain = 0.0;
        void enter(bool p_enabled, double p_attack, double p_decay);
        void advance(double p_delta, bool p_enabled, double p_attack, double p_decay, double p_release);
        double gain(bool p_enabled, double p_attack, double p_decay, double p_sustain, double p_release) const;
        bool begin_release(double p_gain, double p_release);
        bool moving() const { return stage == ADSR_ATTACK || stage == ADSR_DECAY || stage == ADSR_RELEASE; }
    };

    // One audio node as the runtime sees it. Written by the runtime, applied by SfxPlayerCore
    struct Slot {
        Ref<AudioStream> stream;
        double start_position = 0.0;
        Transport transport = TRANSPORT_IDLE;
        // Raised by every play request, so a restart of a playing voice is not "nothing changed"
        uint32_t play_serial = 0, applied_play_serial = 0;
        double volume_db = 0.0, pitch_scale = 1.0;
        bool wants_generator = false;
        bool spatial_override = false;
        Vector3 spatial_position;
        int spatial_attenuation_model = 0;
        double spatial_unit_size = 1.0, spatial_max_distance = -1.0, spatial_panning_strength = 1.0;
        uint32_t dirty = 0;
        // Seeded by a play request, cleared by the node's `finished` (handle_slot_finished)
        bool playing = false;
        Ref<AudioStreamGeneratorPlayback> generator_stream_playback; // handed back by SfxPlayerCore
        double base_max_db = 3.0; // max_db of an AudioStreamPlayer3D before the gain shifted it
        // Claim counter: a voice stolen from can tell the slot is no longer its own
        uint32_t token = 0;
        // The clock: `anchor_position` at runtime time `anchor_clock`, moving at pitch_scale
        double anchor_position = 0.0, anchor_clock = 0.0;
        bool looping = false;
        double loop_begin = 0.0, loop_end = 0.0;

        double position(double p_now) const;
        void anchor(double p_now) {
            anchor_position = position(p_now);
            anchor_clock = p_now;
        }
        void swap_stream(const Ref<AudioStream> &p_stream);
        void replay(double p_position, double p_now);
        void stop_playback();
        void apply_gain(double p_volume_db);
        void apply_pitch(double p_pitch_scale, double p_now);
        void apply_spatial(const Ref<SfxSpatialConfig> &p_config, double p_unit_size);
        void clear_spatial();
        void reset(bool p_clear_stream, double p_now);
    };

private:
    struct Instance {
        uint64_t id = 0;
        Ref<SfxEvent> event;
        StringName name;
        double playback_time = 0.0, release_time = 0.0;
        HashMap<StringName, double> params;
        Dictionary params_dictionary; // what a generator and the visualisation see, rebuilt on change
        bool params_dictionary_stale = true;
        Status status = STATUS_PLAYING;
        Adsr adsr;
        LocalVector<Ref<SfxClip>> triggered_event_clips, triggered_sustain_clips;
        HashMap<StringName, LocalVector<Ref<SfxClip>>> triggered_automation_clips;
        // A parameter moved and the automation clips have not been looked at yet
        bool automation_refresh_pending = false;
        // The first look at the automations is done: latch_on_start ones are not looked at again
        bool automations_started = false;
    };

    struct Voice {
        int slot = -1;
        uint32_t slot_token = 0;
        Instance *instance = nullptr;
        Ref<SfxClip> clip;
        Ref<AudioStream> stream;
        double stream_start = 0.0, stream_end = 0.0;
        // stream_end cuts the stream short (clip.length): the runtime stops it, not the stream
        bool truncated = false;
        Ref<SfxAutomation> automation;
        StringName automation_name;
        Ref<SfxGeneratorPlayback> generator;
        Variant generator_state;
        Ref<AudioStreamGeneratorPlayback> generator_stream_playback;
        Dictionary generator_context;
        bool stopping = false, finish_on_end = false;
        double stop_elapsed = 0.0, stop_fade = 0.0;
        uint64_t creation_order = 0;
        Adsr track_adsr;
        double automation_current_gain = 1.0, automation_release_gain = 1.0;
    };

    struct Derived {
        int index = -1;
        Ref<SfxDerivedParameter> resource;
        Ref<Expression> expression;
        LocalVector<int> inputs;
        Array arguments;
        double previous_input = 0.0;
        bool has_previous = false, settled = true;
    };

    struct Trigger {
        Ref<SfxEvent> event;
        Ref<SfxParameterTrigger> resource;
        int index = -1;
        double previous = 0.0, accumulated = 0.0, last_fire = -INFINITY;
        // open: a GATE that started its event; resume: one the player cut, to start again at resume_offset
        bool has_previous = false, open = false, resume = false;
    };

    LocalVector<Slot> slots;
    int slot_capacity = 0;
    std::vector<std::unique_ptr<Voice>> voices;
    std::vector<std::unique_ptr<Instance>> instances;
    uint64_t voice_counter = 0, instance_counter = 0;
    double clock = 0.0;
    // Raised once the last voice and instance are gone; SfxPlayerCore emits `finished` for it
    bool finished_pending = false;

    // Parameters of the player: the bank's SfxParameters, then its SfxDerivedParameters
    HashMap<StringName, int> parameter_index;
    LocalVector<double> parameter_values;
    int raw_parameter_count = 0;
    LocalVector<Derived> derived;
    LocalVector<Trigger> triggers;
    // What changed since the last tick, by parameter: only what reads it is evaluated again
    LocalVector<uint8_t> parameter_dirty;
    bool parameters_changed = false;
    bool triggers_enabled = true;

    double param(const Instance *p_instance, const StringName &p_name, double p_fallback) const;
    Instance *latest_instance(const StringName &p_name, bool p_playing_first = false) const;
    void mark_parameter(int p_index);
    void update_parameters(double p_delta);
    void fire_triggers();
    void update_instance(Instance *p_instance, double p_delta);
    void refresh_event_clips(Instance *p_instance, double p_previous, double p_current, bool p_sustain);
    void refresh_automation_clips(Instance *p_instance);
    Instance *start_instance(const Ref<SfxEvent> &p_event, double p_offset, const Dictionary &p_parameters = Dictionary());
    void remove_instance(Instance *p_instance);
    void stop_event_instance(Instance *p_instance, bool p_immediate);
    void collect_finished_instances();
    bool has_pending_play_activity(const Instance *p_instance) const;
    bool has_voices(const Instance *p_instance) const;

    int find_voice_index(const Voice *p_voice) const;
    int find_slot_voice(int p_slot, int64_t p_token = -1) const;
    Voice *find_voice(const Instance *p_instance, const Ref<SfxClip> &p_clip, const StringName &p_automation = StringName()) const;
    int acquire_slot();
    bool start_voice(Instance *p_instance, const Ref<SfxClip> &p_clip, const Ref<SfxAutomation> &p_automation = Ref<SfxAutomation>());
    double voice_start_position(const Instance *p_instance, const Ref<SfxClip> &p_clip, const Ref<SfxAutomation> &p_automation, const Ref<AudioStream> &p_stream) const;
    void update_voice(int p_index, double p_delta);
    void apply_voice_state(Voice *p_voice);
    double automation_raw_gain(const Voice *p_voice) const;
    double automation_clip_gain(const Voice *p_voice) const;
    double mixer_gain(const Voice *p_voice) const;
    Ref<SfxTrack> mixer_track(const Voice *p_voice) const;
    bool begin_track_release(Voice *p_voice);
    bool begin_voice_stop(Voice *p_voice);
    bool begin_automation_voice_stop(Voice *p_voice);
    void stop_automation_voice(Voice *p_voice);
    void finish_automation_voice_on_end(Voice *p_voice);
    void restart_automation_voice(Voice *p_voice);
    bool automation_voice_releasing(const Voice *p_voice) const;
    void pump_generator(Voice *p_voice, double p_delta);
    void release_voice(int p_index);
    void stop_voice(int p_index);
    Dictionary visual_clip_state(const Ref<SfxClip> &p_clip, const Voice *p_voice, bool p_use_clip_length, const Instance *p_instance) const;

protected:
    static void _bind_methods();

public:
    ~SfxPlaybackRuntime();

    // C++ side (SfxPlayerCore)
    LocalVector<Slot> &get_slots() { return slots; }
    double get_clock() const { return clock; }
    // Runtime time of the next update that has work to do: clock for "every frame", INF for never
    double get_next_wake() const;
    void play(const Ref<SfxEvent> &p_event, double p_offset, const Dictionary &p_parameters);
    // Off while the player is cut (out of earshot): no trigger starts anything then
    void set_triggers_enabled(bool p_enabled);
    static double tail_start_position(double p_position, double p_end, bool p_was_looping);
    static double sample_time_curve(const Ref<Curve> &p_curve, double p_elapsed, bool p_from_end);
    static double sample_automation_curve(const Ref<Curve> &p_curve, double p_value, double p_offset);
    static double sample_automation_fade_out(const Ref<Curve> &p_curve, const Ref<SfxClip> &p_clip, double p_value);

    // Scripting side - the player API forwards here
    void set_slot_capacity(int p_capacity);
    void release_slots() { slots.clear(); }
    void set_bank(const Ref<SfxBank> &p_bank);
    bool set_parameter(const StringName &p_name, double p_value);
    void set_parameter_values(const PackedFloat64Array &p_values);
    double get_parameter(const StringName &p_name) const;
    bool has_parameter(const StringName &p_name) const { return parameter_index.has(p_name); }
    void play_event(const Ref<SfxEvent> &p_event, double p_offset = 0.0, const Dictionary &p_parameters = Dictionary()) { play(p_event, p_offset, p_parameters); }
    void seek(const StringName &p_event_name, double p_offset);
    void modulate(const StringName &p_event_name, const Dictionary &p_parameters);
    void set_parameters(const Dictionary &p_parameters);
    void stop(const Variant &p_event_name_or_immediate = Variant(), bool p_immediate = false);
    void stop_all(bool p_immediate = false);
    void stop_event(const StringName &p_event_name, bool p_immediate = false);
    void play_automation(const Ref<SfxEvent> &p_event, const StringName &p_automation, double p_value = 0.0, bool p_restart = false);
    void stop_automation(const Ref<SfxEvent> &p_event, const StringName &p_automation, bool p_immediate = false);
    bool is_playing(const StringName &p_event_name) const;
    Dictionary get_event_visualization_state(const StringName &p_event_name) const;
    void update(double p_delta);
    void clear();
    bool requires_process() const;
    bool consume_finished();
    void handle_slot_finished(int p_slot);
    // For tests and tools: what the runtime holds, as dictionaries
    Array get_debug_voices() const;
    Array get_debug_slots() const;
    PackedInt64Array get_instance_ids(const StringName &p_event_name) const;
};

} // namespace godot

VARIANT_ENUM_CAST(SfxPlaybackRuntime::AdsrStage);
