#pragma once

// The main-thread half of a player, shared by SfxPlayer and SfxPlayer3D (composed: one extends Node,
// the other Node3D). It owns the pool of AudioStreamPlayer(3D) nodes and is the only code that touches
// them: flush() copies what the runtime decided into the nodes. In game GndSfxServer ticks the runtime
// on a worker thread; in the editor the owning node's _process does it (tick_preview).

#include "sfx_playback_runtime.hpp"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>

namespace godot {

class SfxPlayerCore {
public:
    // What the owning node adds: its voice nodes
    struct Host {
        virtual Node *make_voice() = 0;
        virtual void configure_voice(Node *p_voice) = 0;
        virtual ~Host() {}
    };

    static constexpr const char *NONE_OPTION = "<none>";

    Node *owner = nullptr;
    Host *host = nullptr;
    Ref<SfxPlaybackRuntime> runtime;
    LocalVector<Node *> nodes; // indexed like the runtime's slots
    LocalVector<Ref<Resource>> watched; // editor: what the preview follows

    // The exported values both players share
    Ref<SfxBank> bank;
    int max_tracks = 4;
    int max_polyphony = 1;
    StringName bus = "Master";
    bool playback_enabled = false;
    StringName playback_effect, playback_automation;
    double playback_automation_value = 0.0;

    // GndSfxServer's bookkeeping, main thread only except tick_delta/next_wake/alive (the worker's)
    bool live = false; // in the server's list
    bool awake = false; // the API changed something: tick at the next post
    bool ticked = false; // ticked by the last post: flush it
    bool can_process = true;
    // Silent, its triggers off: forced (the `cut` property) or beyond gnd_sfx/hard_cut_distance (SfxPlayer3D)
    bool cut = false, forced_cut = false, distance_cut = false;
    bool alive = false;
    double pending_delta = 0.0, tick_delta = 0.0, next_wake = 0.0;

    SfxPlayerCore(Node *p_owner, Host *p_host);
    ~SfxPlayerCore();

    void tick(); // worker thread
    void tick_preview(double p_delta); // editor
    void flush(double p_now);
    void wait_for_tick();
    void request_tick();

    // Node lifecycle
    void enter_tree();
    void ready();
    void exit_tree();

    // Setters of the shared exports
    void set_bank(const Ref<SfxBank> &p_bank);
    void set_max_tracks(int p_value);
    void set_max_polyphony(int p_value);
    void set_bus(const StringName &p_value);
    void set_playback_enabled(bool p_value);
    void set_playback_effect(const StringName &p_value);
    void set_playback_automation(const StringName &p_value);
    void set_playback_automation_value(double p_value);
    void apply_player_config();
    void set_cut(bool p_forced, bool p_distance);

    // Player API
    void sync_values(bool p_rebuild = false);
    void play(const StringName &p_event_name, const Variant &p_offset_or_parameters, const Dictionary &p_parameters);
    void seek(const StringName &p_event_name, double p_offset);
    void modulate(const StringName &p_event_name, const Dictionary &p_parameters);
    void set_parameters(const Dictionary &p_parameters);
    void set_parameter(const StringName &p_name, double p_value);
    void set_parameter_values(const PackedFloat64Array &p_values);
    double get_parameter(const StringName &p_name);
    void stop(const Variant &p_event_name_or_immediate, bool p_immediate);
    bool is_playing(const StringName &p_event_name);
    Dictionary get_event_visualization_state(const StringName &p_event_name);
    void play_automation(const StringName &p_event_name, const StringName &p_automation, double p_value, bool p_restart);
    void stop_automation(const StringName &p_event_name, const StringName &p_automation, bool p_immediate);
    void clear();

    // Signals of the voices and of the resources (bound on the owner as _sfx_*)
    void voice_finished(int p_index);
    void source_changed();

    // Inspector: playback_* enum hints and the bank's parameters as "parameters/<name>"
    void validate_property(PropertyInfo &p_property) const;
    void get_property_list(List<PropertyInfo> *p_list) const;
    bool set(const StringName &p_name, const Variant &p_value);
    bool get(const StringName &p_name, Variant &r_ret);

private:
    bool preview_enabled = false;
    StringName preview_effect, preview_automation;
    double preview_value = 0.0;

    Ref<SfxEvent> find_event(const StringName &p_name) const;
    void sanitize_playback_selection();
    void notify_playback_property_list_changed();
    void watch_sources(bool p_watch);
    void sync_editor_playback();
};

// Binds the API the two players share; T forwards it to its SfxPlayerCore `core`
#define SFX_PLAYER_FORWARDS                                                                                                   \
public:                                                                                                                       \
    void set_bank(const Ref<SfxBank> &p_value) { core.set_bank(p_value); }                                                   \
    Ref<SfxBank> get_bank() const { return core.bank; }                                                                      \
    void set_max_tracks(int p_value) { core.set_max_tracks(p_value); }                                                       \
    int get_max_tracks() const { return core.max_tracks; }                                                                   \
    void set_max_polyphony(int p_value) { core.set_max_polyphony(p_value); }                                                 \
    int get_max_polyphony() const { return core.max_polyphony; }                                                             \
    void set_bus(const StringName &p_value) { core.set_bus(p_value); }                                                       \
    StringName get_bus() const { return core.bus; }                                                                          \
    void set_playback_enabled(bool p_value) { core.set_playback_enabled(p_value); }                                          \
    bool get_playback_enabled() const { return core.playback_enabled; }                                                      \
    void set_playback_effect(const StringName &p_value) { core.set_playback_effect(p_value); }                               \
    StringName get_playback_effect() const { return core.playback_effect; }                                                 \
    void set_playback_automation(const StringName &p_value) { core.set_playback_automation(p_value); }                       \
    StringName get_playback_automation() const { return core.playback_automation; }                                         \
    void set_playback_automation_value(double p_value) { core.set_playback_automation_value(p_value); }                     \
    double get_playback_automation_value() const { return core.playback_automation_value; }                                 \
    void sync_values(bool p_rebuild) { core.sync_values(p_rebuild); }                                                        \
    void seek(const StringName &p_event, double p_offset) { core.seek(p_event, p_offset); }                                  \
    void modulate(const StringName &p_event, const Dictionary &p_parameters) { core.modulate(p_event, p_parameters); }       \
    void set_parameters(const Dictionary &p_parameters) { core.set_parameters(p_parameters); }                               \
    void set_parameter(const StringName &p_name, double p_value) { core.set_parameter(p_name, p_value); }                    \
    void set_parameter_values(const PackedFloat64Array &p_values) { core.set_parameter_values(p_values); }                  \
    double get_parameter(const StringName &p_name) { return core.get_parameter(p_name); }                                    \
    void stop(const Variant &p_event, bool p_immediate) { core.stop(p_event, p_immediate); }                                 \
    bool is_playing(const StringName &p_event) { return core.is_playing(p_event); }                                          \
    Dictionary get_event_visualization_state(const StringName &p_event) { return core.get_event_visualization_state(p_event); } \
    void play_automation(const StringName &p_event, const StringName &p_automation, double p_value, bool p_restart) {        \
        core.play_automation(p_event, p_automation, p_value, p_restart);                                                     \
    }                                                                                                                         \
    void stop_automation(const StringName &p_event, const StringName &p_automation, bool p_immediate) {                      \
        core.stop_automation(p_event, p_automation, p_immediate);                                                            \
    }                                                                                                                         \
    void set_cut(bool p_value) { core.set_cut(p_value, core.distance_cut); }                                                \
    bool get_cut() const { return core.forced_cut; }                                                                         \
    void _sfx_voice_finished(int p_index) { core.voice_finished(p_index); }                                                  \
    void _sfx_source_changed() { core.source_changed(); }                                                                    \
    void _validate_property(PropertyInfo &p_property) const { core.validate_property(p_property); }                          \
    void _get_property_list(List<PropertyInfo> *p_list) const { core.get_property_list(p_list); }                            \
    bool _set(const StringName &p_name, const Variant &p_value) { return core.set(p_name, p_value); }                        \
    bool _get(const StringName &p_name, Variant &r_ret) const { return const_cast<SfxPlayerCore &>(core).get(p_name, r_ret); } \
    void _process(double p_delta) override { core.tick_preview(p_delta); }                                                   \
    SfxPlayerCore *get_core() { return &core; }

template <class T> void sfx_bind_player_api() {
    ClassDB::add_signal(T::get_class_static(), MethodInfo("finished"));
    ClassDB::bind_method(D_METHOD("sync_values", "rebuild"), &T::sync_values, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("play", "event_name", "offset_or_parameters", "parameters"), &T::play, DEFVAL(Variant()), DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("seek", "event_name", "offset"), &T::seek);
    ClassDB::bind_method(D_METHOD("modulate", "event_name", "parameters"), &T::modulate);
    ClassDB::bind_method(D_METHOD("set_parameters", "parameters"), &T::set_parameters);
    ClassDB::bind_method(D_METHOD("set_parameter", "name", "value"), &T::set_parameter);
    ClassDB::bind_method(D_METHOD("set_parameter_values", "values"), &T::set_parameter_values);
    ClassDB::bind_method(D_METHOD("get_parameter", "name"), &T::get_parameter);
    ClassDB::bind_method(D_METHOD("stop", "event_name_or_immediate", "immediate"), &T::stop, DEFVAL(Variant()), DEFVAL(false));
    ClassDB::bind_method(D_METHOD("is_playing", "event_name"), &T::is_playing);
    ClassDB::bind_method(D_METHOD("get_event_visualization_state", "event_name"), &T::get_event_visualization_state);
    ClassDB::bind_method(D_METHOD("play_automation", "event_name", "automation_name", "value", "restart"), &T::play_automation, DEFVAL(0.0), DEFVAL(false));
    ClassDB::bind_method(D_METHOD("stop_automation", "event_name", "automation_name", "immediate"), &T::stop_automation, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("_sfx_voice_finished", "index"), &T::_sfx_voice_finished);
    ClassDB::bind_method(D_METHOD("_sfx_source_changed"), &T::_sfx_source_changed);
    ClassDB::bind_method(D_METHOD("set_bank", "value"), &T::set_bank);
    ClassDB::bind_method(D_METHOD("get_bank"), &T::get_bank);
    ClassDB::bind_method(D_METHOD("set_max_tracks", "value"), &T::set_max_tracks);
    ClassDB::bind_method(D_METHOD("get_max_tracks"), &T::get_max_tracks);
    ClassDB::bind_method(D_METHOD("set_max_polyphony", "value"), &T::set_max_polyphony);
    ClassDB::bind_method(D_METHOD("get_max_polyphony"), &T::get_max_polyphony);
    ClassDB::bind_method(D_METHOD("set_cut", "value"), &T::set_cut);
    ClassDB::bind_method(D_METHOD("get_cut"), &T::get_cut);
    ClassDB::bind_method(D_METHOD("set_bus", "value"), &T::set_bus);
    ClassDB::bind_method(D_METHOD("get_bus"), &T::get_bus);
    ClassDB::add_property(T::get_class_static(), PropertyInfo(Variant::OBJECT, "bank", PROPERTY_HINT_RESOURCE_TYPE, "SfxBank"), "set_bank", "get_bank");
    ClassDB::add_property(T::get_class_static(), PropertyInfo(Variant::INT, "max_tracks", PROPERTY_HINT_RANGE, "1,32,1,or_greater"), "set_max_tracks", "get_max_tracks");
    ClassDB::add_property(T::get_class_static(), PropertyInfo(Variant::INT, "max_polyphony", PROPERTY_HINT_RANGE, "1,32,1,or_greater"), "set_max_polyphony", "get_max_polyphony");
    ClassDB::add_property(T::get_class_static(), PropertyInfo(Variant::STRING_NAME, "bus", PROPERTY_HINT_ENUM_SUGGESTION, ""), "set_bus", "get_bus");
    ClassDB::add_property(T::get_class_static(), PropertyInfo(Variant::BOOL, "cut", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR), "set_cut", "get_cut");
}

// The editor preview, last in the inspector
template <class T> void sfx_bind_player_playback() {
    ClassDB::bind_method(D_METHOD("set_playback_enabled", "value"), &T::set_playback_enabled);
    ClassDB::bind_method(D_METHOD("get_playback_enabled"), &T::get_playback_enabled);
    ClassDB::bind_method(D_METHOD("set_playback_effect", "value"), &T::set_playback_effect);
    ClassDB::bind_method(D_METHOD("get_playback_effect"), &T::get_playback_effect);
    ClassDB::bind_method(D_METHOD("set_playback_automation", "value"), &T::set_playback_automation);
    ClassDB::bind_method(D_METHOD("get_playback_automation"), &T::get_playback_automation);
    ClassDB::bind_method(D_METHOD("set_playback_automation_value", "value"), &T::set_playback_automation_value);
    ClassDB::bind_method(D_METHOD("get_playback_automation_value"), &T::get_playback_automation_value);
    ClassDB::add_property_group(T::get_class_static(), "Playback", "playback_");
    ClassDB::add_property(T::get_class_static(), PropertyInfo(Variant::BOOL, "playback_enabled"), "set_playback_enabled", "get_playback_enabled");
    ClassDB::add_property(T::get_class_static(), PropertyInfo(Variant::STRING_NAME, "playback_effect"), "set_playback_effect", "get_playback_effect");
    ClassDB::add_property(T::get_class_static(), PropertyInfo(Variant::STRING_NAME, "playback_automation"), "set_playback_automation", "get_playback_automation");
    ClassDB::add_property(T::get_class_static(), PropertyInfo(Variant::FLOAT, "playback_automation_value"), "set_playback_automation_value", "get_playback_automation_value");
}

} // namespace godot
