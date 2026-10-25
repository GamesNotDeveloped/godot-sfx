#pragma once

// The nodes a game plays a bank with. Thin: SfxPlayerCore holds the shared part, the runtime plays

#include "sfx_player_core.hpp"

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/node3d.hpp>

namespace godot {

class SfxPlayer : public Node, public SfxPlayerCore::Host {
    GDCLASS(SfxPlayer, Node);
    SfxPlayerCore core{ this, this };
    SFX_PLAYER_FORWARDS

public:
    Node *make_voice() override;
    void configure_voice(Node *p_voice) override;
    void play(const StringName &p_event, const Variant &p_offset_or_parameters, const Dictionary &p_parameters);

protected:
    static void _bind_methods();
    void _notification(int p_what);
};

class SfxPlayer3D : public Node3D, public SfxPlayerCore::Host {
    GDCLASS(SfxPlayer3D, Node3D);
    SfxPlayerCore core{ this, this };
    SFX_PLAYER_FORWARDS

public:
    int attenuation_model = 0;
    double unit_size = 10.0;
    int max_distance = 0;
    double panning_strength = 1.0;
    // Silent beyond gnd_sfx/hard_cut_distance of the camera. Off for a player whose events carry
    // their own places (SfxSpatialConfig.position): its own place says nothing of its voices'
    bool hard_cut_enabled = true;

    Node *make_voice() override;
    void configure_voice(Node *p_voice) override;
    void play(const StringName &p_event, const Variant &p_offset_or_parameters, const Dictionary &p_parameters);
    void hard_cut_check(Camera3D *p_camera = nullptr);

    void set_attenuation_model(int p_value);
    int get_attenuation_model() const { return attenuation_model; }
    void set_unit_size(double p_value);
    double get_unit_size() const { return unit_size; }
    void set_max_distance(int p_value);
    int get_max_distance() const { return max_distance; }
    void set_panning_strength(double p_value);
    double get_panning_strength() const { return panning_strength; }
    void set_hard_cut_enabled(bool p_value) { hard_cut_enabled = p_value; }
    bool get_hard_cut_enabled() const { return hard_cut_enabled; }

protected:
    static void _bind_methods();
    void _notification(int p_what);
};

} // namespace godot
