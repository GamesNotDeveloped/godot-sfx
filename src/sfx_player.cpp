#include "sfx_player.hpp"

#include "gnd_sfx_server.hpp"

#include <godot_cpp/classes/audio_stream_player.hpp>
#include <godot_cpp/classes/audio_stream_player3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/viewport.hpp>

using namespace godot;

static void notify_core(SfxPlayerCore &p_core, int p_what) {
    switch (p_what) {
        case Node::NOTIFICATION_ENTER_TREE:
            p_core.enter_tree();
            break;
        case Node::NOTIFICATION_READY:
            p_core.ready();
            break;
        case Node::NOTIFICATION_EXIT_TREE:
            p_core.exit_tree();
            break;
    }
}

// --- SfxPlayer ---------------------------------------------------------------------------------

Node *SfxPlayer::make_voice() {
    return memnew(AudioStreamPlayer);
}

void SfxPlayer::configure_voice(Node *p_voice) {
    AudioStreamPlayer *voice = Object::cast_to<AudioStreamPlayer>(p_voice);
    voice->set_max_polyphony(core.max_polyphony);
    voice->set_bus(core.bus);
}

void SfxPlayer::play(const StringName &p_event, const Variant &p_offset_or_parameters, const Dictionary &p_parameters) {
    core.play(p_event, p_offset_or_parameters, p_parameters);
}

void SfxPlayer::_notification(int p_what) {
    notify_core(core, p_what);
}

void SfxPlayer::_bind_methods() {
    sfx_bind_player_api<SfxPlayer>();
    sfx_bind_player_playback<SfxPlayer>();
}

// --- SfxPlayer3D -------------------------------------------------------------------------------

Node *SfxPlayer3D::make_voice() {
    return memnew(AudioStreamPlayer3D);
}

void SfxPlayer3D::configure_voice(Node *p_voice) {
    AudioStreamPlayer3D *voice = Object::cast_to<AudioStreamPlayer3D>(p_voice);
    voice->set_max_polyphony(core.max_polyphony);
    voice->set_max_distance(max_distance);
    voice->set_panning_strength(panning_strength);
    voice->set_attenuation_model(AudioStreamPlayer3D::AttenuationModel(attenuation_model));
    voice->set_unit_size(unit_size);
    voice->set_bus(core.bus);
}

void SfxPlayer3D::play(const StringName &p_event, const Variant &p_offset_or_parameters, const Dictionary &p_parameters) {
    hard_cut_check();
    core.play(p_event, p_offset_or_parameters, p_parameters);
}

void SfxPlayer3D::hard_cut_check(Camera3D *p_camera) {
    if (!hard_cut_enabled) {
        return;
    }
    if (!p_camera && is_inside_tree()) {
        p_camera = get_viewport()->get_camera_3d();
    }
    GndSfxServer *server = GndSfxServer::get_singleton();
    double limit = server ? server->get_hard_cut_distance()
                          : double(ProjectSettings::get_singleton()->get_setting(GndSfxServer::HARD_CUT_DISTANCE_SETTING, 1000.0));
    core.set_cut(core.forced_cut, p_camera && get_global_position().distance_to(p_camera->get_global_position()) > limit);
}

void SfxPlayer3D::set_attenuation_model(int p_value) {
    attenuation_model = p_value;
    core.apply_player_config();
}

void SfxPlayer3D::set_unit_size(double p_value) {
    unit_size = p_value;
    core.apply_player_config();
}

void SfxPlayer3D::set_max_distance(int p_value) {
    max_distance = p_value;
    core.apply_player_config();
}

void SfxPlayer3D::set_panning_strength(double p_value) {
    panning_strength = p_value;
    core.apply_player_config();
}

void SfxPlayer3D::_notification(int p_what) {
    notify_core(core, p_what);
    if (p_what == NOTIFICATION_READY && !Engine::get_singleton()->is_editor_hint()) {
        hard_cut_check();
    }
}

void SfxPlayer3D::_bind_methods() {
    sfx_bind_player_api<SfxPlayer3D>();
    ClassDB::bind_method(D_METHOD("hard_cut_check", "camera"), &SfxPlayer3D::hard_cut_check, DEFVAL(Variant()));
    ClassDB::bind_method(D_METHOD("set_attenuation_model", "value"), &SfxPlayer3D::set_attenuation_model);
    ClassDB::bind_method(D_METHOD("get_attenuation_model"), &SfxPlayer3D::get_attenuation_model);
    ClassDB::bind_method(D_METHOD("set_unit_size", "value"), &SfxPlayer3D::set_unit_size);
    ClassDB::bind_method(D_METHOD("get_unit_size"), &SfxPlayer3D::get_unit_size);
    ClassDB::bind_method(D_METHOD("set_max_distance", "value"), &SfxPlayer3D::set_max_distance);
    ClassDB::bind_method(D_METHOD("get_max_distance"), &SfxPlayer3D::get_max_distance);
    ClassDB::bind_method(D_METHOD("set_panning_strength", "value"), &SfxPlayer3D::set_panning_strength);
    ClassDB::bind_method(D_METHOD("get_panning_strength"), &SfxPlayer3D::get_panning_strength);
    ClassDB::bind_method(D_METHOD("set_hard_cut_enabled", "value"), &SfxPlayer3D::set_hard_cut_enabled);
    ClassDB::bind_method(D_METHOD("get_hard_cut_enabled"), &SfxPlayer3D::get_hard_cut_enabled);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "attenuation_model", PROPERTY_HINT_ENUM, "Inverse Distance,Inverse Square Distance,Logarithmic,Disabled"),
            "set_attenuation_model", "get_attenuation_model");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "unit_size", PROPERTY_HINT_RANGE, "0.01,100,0.01"), "set_unit_size", "get_unit_size");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "max_distance", PROPERTY_HINT_RANGE, "0,4096,1,or_greater"), "set_max_distance", "get_max_distance");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "hard_cut_enabled"), "set_hard_cut_enabled", "get_hard_cut_enabled");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "panning_strength", PROPERTY_HINT_RANGE, "0,3,0.01"), "set_panning_strength", "get_panning_strength");
    sfx_bind_player_playback<SfxPlayer3D>();
}
