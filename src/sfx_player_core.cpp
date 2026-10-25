#include "sfx_player_core.hpp"

#include "gnd_sfx_server.hpp"

#include <godot_cpp/classes/audio_stream_player.hpp>
#include <godot_cpp/classes/audio_stream_player3d.hpp>
#include <godot_cpp/classes/engine.hpp>

using namespace godot;

using Slot = SfxPlaybackRuntime::Slot;

static bool editor() {
    return Engine::get_singleton()->is_editor_hint();
}

SfxPlayerCore::SfxPlayerCore(Node *p_owner, Host *p_host) :
        owner(p_owner), host(p_host) {
    runtime.instantiate();
    runtime->set_triggers_enabled(!editor());
    runtime->set_slot_capacity(max_tracks);
}

SfxPlayerCore::~SfxPlayerCore() {
    if (live && GndSfxServer::get_singleton()) {
        GndSfxServer::get_singleton()->remove(this);
    }
}

void SfxPlayerCore::tick() {
    runtime->update(tick_delta);
    next_wake = runtime->get_next_wake();
    alive = runtime->requires_process();
}

void SfxPlayerCore::tick_preview(double p_delta) {
    runtime->update(p_delta);
    flush(runtime->get_clock());
    owner->set_process(runtime->requires_process());
}

// Any tick, not only this player's: the resources (a clip's drain_stream) are shared between players
void SfxPlayerCore::wait_for_tick() {
    if (GndSfxServer *server = GndSfxServer::get_singleton()) {
        server->wait_for_tick();
    }
}

// There is work for the next tick: in game the server visits this core again, in the editor the
// owning node's _process does the ticking
void SfxPlayerCore::request_tick() {
    if (editor()) {
        owner->set_process(true);
    } else if (GndSfxServer *server = GndSfxServer::get(owner)) {
        server->activate(this);
    }
}

// One voice node; P is AudioStreamPlayer or AudioStreamPlayer3D
template <class P> static void apply_slot(P *p_node, Slot &p_slot, double p_now, SfxPlayerCore::Host *p_host) {
    constexpr bool SPATIAL = std::is_same_v<P, AudioStreamPlayer3D>;
    if (p_slot.dirty & SfxPlaybackRuntime::DIRTY_STREAM) {
        p_node->set_stream(p_slot.stream);
    }
    if (p_slot.dirty & SfxPlaybackRuntime::DIRTY_GAIN) {
        p_node->set_volume_db(p_slot.volume_db);
        if constexpr (SPATIAL) {
            // AudioStreamPlayer3D clamps attenuation + volume_db to max_db, and next to the listener
            // the attenuation reaches about +100 dB: a gain through volume_db alone is clamped away.
            // Shifting max_db by the same gain makes it act after the clamp
            p_node->set_max_db(p_slot.base_max_db + p_slot.volume_db);
        }
    }
    if (p_slot.dirty & SfxPlaybackRuntime::DIRTY_PITCH) {
        p_node->set_pitch_scale(p_slot.pitch_scale);
    }
    if constexpr (SPATIAL) {
        if (p_slot.dirty & SfxPlaybackRuntime::DIRTY_SPATIAL) {
            if (p_slot.spatial_override) {
                p_node->set_position(p_slot.spatial_position);
                p_node->set_attenuation_model(AudioStreamPlayer3D::AttenuationModel(p_slot.spatial_attenuation_model));
                p_node->set_unit_size(p_slot.spatial_unit_size);
                p_node->set_panning_strength(p_slot.spatial_panning_strength);
                if (p_slot.spatial_max_distance >= 0.0) {
                    p_node->set_max_distance(p_slot.spatial_max_distance);
                }
            } else {
                p_node->set_position(Vector3());
                p_host->configure_voice(p_node);
            }
        }
    }
    if (p_slot.play_serial > p_slot.applied_play_serial) {
        p_slot.applied_play_serial = p_slot.play_serial;
        p_node->play(p_slot.start_position);
        // the voice's clock starts now, when the node does
        p_slot.anchor_position = p_slot.start_position;
        p_slot.anchor_clock = p_now;
        if (p_slot.wants_generator) {
            p_slot.generator_stream_playback = p_node->get_stream_playback();
        }
    } else if (p_slot.transport == SfxPlaybackRuntime::TRANSPORT_STOP && p_node->is_playing()) {
        p_node->stop();
    }
    p_slot.dirty = 0;
}

// Copies what the last tick decided into the audio nodes. Main thread only
void SfxPlayerCore::flush(double p_now) {
    LocalVector<Slot> &slots = runtime->get_slots();
    for (uint32_t i = 0; i < slots.size(); i++) {
        Slot &slot = slots[i];
        if (!slot.dirty && slot.play_serial == slot.applied_play_serial) {
            continue;
        }
        Node *node = i < nodes.size() ? nodes[i] : nullptr;
        if (!node) {
            // a slot that only ever asked to stop never had a node to stop
            if (slot.play_serial == slot.applied_play_serial) {
                slot.dirty = 0;
                continue;
            }
            node = host->make_voice();
            host->configure_voice(node);
            while (nodes.size() <= i) {
                nodes.push_back(nullptr);
            }
            nodes[i] = node;
            owner->add_child(node);
            node->connect("finished", Callable(owner, "_sfx_voice_finished").bind(i));
            if (AudioStreamPlayer3D *spatial = Object::cast_to<AudioStreamPlayer3D>(node)) {
                slot.base_max_db = spatial->get_max_db();
            }
        }
        if (AudioStreamPlayer3D *spatial = Object::cast_to<AudioStreamPlayer3D>(node)) {
            apply_slot(spatial, slot, p_now, host);
        } else {
            apply_slot(Object::cast_to<AudioStreamPlayer>(node), slot, p_now, host);
        }
    }
    if (runtime->consume_finished()) {
        owner->emit_signal("finished");
    }
}

// A node reached the end of its stream on its own. Godot emits `finished` for a node the runtime
// stopped too, hence the playing check (the slot may already play its next voice)
void SfxPlayerCore::voice_finished(int p_index) {
    if (p_index >= int(nodes.size()) || !nodes[p_index] || bool(nodes[p_index]->call("is_playing"))) {
        return;
    }
    wait_for_tick();
    if (p_index < int(runtime->get_slots().size())) {
        runtime->handle_slot_finished(p_index);
        request_tick();
    }
}

void SfxPlayerCore::enter_tree() {
    preview_enabled = false;
    preview_effect = preview_automation = StringName();
    preview_value = 0.0;
    if (editor()) {
        playback_enabled = false;
        notify_playback_property_list_changed();
    }
}

void SfxPlayerCore::ready() {
    owner->set_process(editor());
    watch_sources(true);
    sync_values(true);
    if (!editor() && runtime->requires_process()) {
        request_tick(); // a bank with triggers or derived parameters has work before any play()
    }
}

void SfxPlayerCore::exit_tree() {
    watch_sources(false);
    if (live && GndSfxServer::get_singleton()) {
        GndSfxServer::get_singleton()->remove(this);
    }
}

void SfxPlayerCore::set_bank(const Ref<SfxBank> &p_bank) {
    wait_for_tick();
    watch_sources(false);
    bank = p_bank;
    runtime->set_bank(bank);
    watch_sources(owner->is_inside_tree());
    sanitize_playback_selection();
    notify_playback_property_list_changed();
    owner->notify_property_list_changed();
    if (owner->is_inside_tree() && !editor()) {
        request_tick();
    }
}

void SfxPlayerCore::set_max_tracks(int p_value) {
    max_tracks = p_value;
    sync_values(true);
}

void SfxPlayerCore::set_max_polyphony(int p_value) {
    max_polyphony = p_value;
    apply_player_config();
}

void SfxPlayerCore::set_bus(const StringName &p_value) {
    bus = p_value;
    apply_player_config();
}

void SfxPlayerCore::set_playback_enabled(bool p_value) {
    playback_enabled = p_value;
    sync_values();
}

void SfxPlayerCore::set_playback_effect(const StringName &p_value) {
    playback_effect = p_value == StringName(NONE_OPTION) ? StringName() : p_value;
    sanitize_playback_selection();
    notify_playback_property_list_changed();
    sync_values();
}

void SfxPlayerCore::set_playback_automation(const StringName &p_value) {
    playback_automation = p_value == StringName(NONE_OPTION) ? StringName() : p_value;
    sync_values();
}

void SfxPlayerCore::set_playback_automation_value(double p_value) {
    playback_automation_value = p_value;
    sync_values();
}

void SfxPlayerCore::apply_player_config() {
    for (Node *node : nodes) {
        if (node) {
            host->configure_voice(node);
        }
    }
}

// A cut player stops everything at once and starts nothing; when it comes back its open gates
// start their events again (past their opening, SfxParameterTrigger.resume_offset)
void SfxPlayerCore::set_cut(bool p_forced, bool p_distance) {
    forced_cut = p_forced;
    distance_cut = p_distance;
    if (cut == (p_forced || p_distance)) {
        return;
    }
    wait_for_tick();
    cut = p_forced || p_distance;
    runtime->set_triggers_enabled(!cut);
    if (cut) {
        runtime->clear();
    }
    request_tick();
}

void SfxPlayerCore::sync_values(bool p_rebuild) {
    wait_for_tick();
    if (p_rebuild) {
        runtime->clear();
        for (Node *node : nodes) {
            if (node) {
                owner->remove_child(node);
                node->queue_free();
            }
        }
        nodes.clear();
        runtime->release_slots();
    }
    runtime->set_slot_capacity(max_tracks);
    apply_player_config();
    sync_editor_playback();
}

Ref<SfxEvent> SfxPlayerCore::find_event(const StringName &p_name) const {
    return bank.is_valid() && !p_name.is_empty() ? bank->get_event(p_name) : Ref<SfxEvent>();
}

void SfxPlayerCore::play(const StringName &p_event_name, const Variant &p_offset_or_parameters, const Dictionary &p_parameters) {
    wait_for_tick();
    Ref<SfxEvent> event = find_event(p_event_name);
    if (event.is_null() || cut) {
        return;
    }
    bool dictionary = p_offset_or_parameters.get_type() == Variant::DICTIONARY;
    double offset = !dictionary && p_offset_or_parameters.booleanize() ? double(p_offset_or_parameters) : 0.0;
    runtime->play(event, offset, dictionary ? Dictionary(p_offset_or_parameters) : p_parameters);
    request_tick();
}

void SfxPlayerCore::seek(const StringName &p_event_name, double p_offset) {
    wait_for_tick();
    runtime->seek(p_event_name, p_offset);
    request_tick();
}

void SfxPlayerCore::modulate(const StringName &p_event_name, const Dictionary &p_parameters) {
    wait_for_tick();
    runtime->modulate(p_event_name, p_parameters);
    request_tick();
}

void SfxPlayerCore::set_parameters(const Dictionary &p_parameters) {
    wait_for_tick();
    runtime->set_parameters(p_parameters);
    request_tick();
}

void SfxPlayerCore::set_parameter(const StringName &p_name, double p_value) {
    wait_for_tick();
    if (!runtime->set_parameter(p_name, p_value)) {
        WARN_PRINT_ONCE(vformat("%s: the bank declares no parameter %s", owner->get_name(), p_name));
        return;
    }
    request_tick();
}

void SfxPlayerCore::set_parameter_values(const PackedFloat64Array &p_values) {
    wait_for_tick();
    runtime->set_parameter_values(p_values);
    request_tick();
}

double SfxPlayerCore::get_parameter(const StringName &p_name) {
    wait_for_tick();
    return runtime->get_parameter(p_name);
}

void SfxPlayerCore::stop(const Variant &p_event_name_or_immediate, bool p_immediate) {
    wait_for_tick();
    runtime->stop(p_event_name_or_immediate, p_immediate);
    request_tick();
}

bool SfxPlayerCore::is_playing(const StringName &p_event_name) {
    wait_for_tick();
    return runtime->is_playing(p_event_name);
}

Dictionary SfxPlayerCore::get_event_visualization_state(const StringName &p_event_name) {
    wait_for_tick();
    return runtime->get_event_visualization_state(p_event_name);
}

void SfxPlayerCore::play_automation(const StringName &p_event_name, const StringName &p_automation, double p_value, bool p_restart) {
    wait_for_tick();
    Ref<SfxEvent> event = find_event(p_event_name);
    if (event.is_valid()) {
        runtime->play_automation(event, p_automation, p_value, p_restart);
        request_tick();
    }
}

void SfxPlayerCore::stop_automation(const StringName &p_event_name, const StringName &p_automation, bool p_immediate) {
    wait_for_tick();
    Ref<SfxEvent> event = find_event(p_event_name);
    if (event.is_valid()) {
        runtime->stop_automation(event, p_automation, p_immediate);
        request_tick();
    }
}

void SfxPlayerCore::clear() {
    wait_for_tick();
    runtime->clear();
    request_tick();
}

// --- Inspector ---------------------------------------------------------------------------------

static const char *PARAMETERS_PREFIX = "parameters/";

void SfxPlayerCore::validate_property(PropertyInfo &p_property) const {
    if (p_property.name != StringName("playback_effect") && p_property.name != StringName("playback_automation")) {
        return;
    }
    PackedStringArray options;
    options.push_back(NONE_OPTION);
    if (p_property.name == StringName("playback_effect")) {
        for (const Ref<SfxEvent> &event : bank.is_valid() ? bank->events.items : LocalVector<Ref<SfxEvent>>()) {
            if (event.is_valid() && !event->name.is_empty()) {
                options.push_back(event->name);
            }
        }
    } else if (Ref<SfxEvent> event = find_event(playback_effect); event.is_valid()) {
        for (const Ref<SfxAutomation> &automation : event->automations.items) {
            if (automation.is_valid() && !automation->parameter_name.is_empty()) {
                options.push_back(automation->parameter_name);
            }
        }
        for (const Ref<SfxParameterModulation> &modulation : event->parameter_modulations.items) {
            if (modulation.is_valid() && !modulation->parameter_name.is_empty() && !options.has(modulation->parameter_name)) {
                options.push_back(modulation->parameter_name);
            }
        }
    }
    p_property.hint = PROPERTY_HINT_ENUM;
    p_property.hint_string = String(",").join(options);
}

void SfxPlayerCore::get_property_list(List<PropertyInfo> *p_list) const {
    if (bank.is_null()) {
        return;
    }
    for (const Ref<SfxParameter> &parameter : bank->parameters.items) {
        if (parameter.is_valid() && !parameter->name.is_empty()) {
            p_list->push_back(PropertyInfo(Variant::FLOAT, String(PARAMETERS_PREFIX) + parameter->name, PROPERTY_HINT_RANGE,
                    vformat("%f,%f,0.001,or_less,or_greater", parameter->min_value, parameter->max_value), PROPERTY_USAGE_EDITOR));
        }
    }
}

bool SfxPlayerCore::set(const StringName &p_name, const Variant &p_value) {
    String name = p_name;
    if (!name.begins_with(PARAMETERS_PREFIX)) {
        return false;
    }
    set_parameter(name.substr(strlen(PARAMETERS_PREFIX)), p_value);
    return true;
}

bool SfxPlayerCore::get(const StringName &p_name, Variant &r_ret) {
    String name = p_name;
    if (!name.begins_with(PARAMETERS_PREFIX) || !runtime->has_parameter(name.substr(strlen(PARAMETERS_PREFIX)))) {
        return false;
    }
    r_ret = get_parameter(name.substr(strlen(PARAMETERS_PREFIX)));
    return true;
}

// --- Editor preview ----------------------------------------------------------------------------

void SfxPlayerCore::sanitize_playback_selection() {
    Ref<SfxEvent> event = find_event(playback_effect);
    if (!playback_effect.is_empty() && event.is_null()) {
        playback_effect = playback_automation = StringName();
        return;
    }
    if (playback_automation.is_empty() || event.is_null()) {
        return;
    }
    for (const Ref<SfxAutomation> &automation : event->automations.items) {
        if (automation.is_valid() && automation->parameter_name == playback_automation) {
            return;
        }
    }
    for (const Ref<SfxParameterModulation> &modulation : event->parameter_modulations.items) {
        if (modulation.is_valid() && modulation->parameter_name == playback_automation) {
            return;
        }
    }
    playback_automation = StringName();
}

void SfxPlayerCore::notify_playback_property_list_changed() {
    if (editor()) {
        owner->notify_property_list_changed();
    }
}

// The editor preview follows edits of the bank's events and automations
void SfxPlayerCore::watch_sources(bool p_watch) {
    Callable changed(owner, "_sfx_source_changed");
    for (const Ref<Resource> &resource : watched) {
        if (resource.is_valid() && resource->is_connected("changed", changed)) {
            resource->disconnect("changed", changed);
        }
    }
    watched.clear();
    if (!p_watch || !editor() || bank.is_null()) {
        return;
    }
    for (const Ref<SfxEvent> &event : bank->events.items) {
        if (event.is_null()) {
            continue;
        }
        watched.push_back(event);
        for (const Ref<SfxAutomation> &automation : event->automations.items) {
            if (automation.is_valid()) {
                watched.push_back(automation);
            }
        }
    }
    for (const Ref<Resource> &resource : watched) {
        if (!resource->is_connected("changed", changed)) {
            resource->connect("changed", changed);
        }
    }
}

void SfxPlayerCore::source_changed() {
    sanitize_playback_selection();
    sync_values();
}

void SfxPlayerCore::sync_editor_playback() {
    if (!editor() || !owner->is_inside_tree()) {
        return;
    }
    bool config_changed = playback_enabled != preview_enabled || playback_effect != preview_effect || playback_automation != preview_automation;
    bool value_changed = !Math::is_equal_approx(playback_automation_value, preview_value);
    if (!config_changed && !value_changed) {
        return;
    }
    bool was_playing = preview_enabled && !preview_effect.is_empty();
    StringName was_effect = preview_effect;
    preview_enabled = playback_enabled;
    preview_effect = playback_effect;
    preview_automation = playback_automation;
    preview_value = playback_automation_value;
    if (!playback_enabled || playback_effect.is_empty()) {
        if (was_playing) {
            stop(was_effect, false);
        } else {
            runtime->clear();
        }
        return;
    }
    Dictionary parameters;
    if (!playback_automation.is_empty()) {
        parameters[playback_automation] = playback_automation_value;
    }
    if (config_changed) {
        runtime->clear();
        play(playback_effect, 0.0, parameters);
    } else if (!playback_automation.is_empty()) {
        modulate(playback_effect, parameters);
    }
}
