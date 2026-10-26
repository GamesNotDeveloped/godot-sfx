#include "gnd_sfx_server.hpp"

#include "sfx_player.hpp"

#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/classes/worker_thread_pool.hpp>

using namespace godot;

GndSfxServer *GndSfxServer::singleton = nullptr;
bool GndSfxServer::gone = false;

static Variant setting(const String &p_name, const Variant &p_default) {
    return ProjectSettings::get_singleton()->get_setting(p_name, p_default);
}

void GndSfxServer::register_settings() {
    ProjectSettings *settings = ProjectSettings::get_singleton();
    auto define = [settings](const String &p_name, const Variant &p_default, const String &p_hint) {
        if (!settings->has_setting(p_name)) {
            settings->set_setting(p_name, p_default);
        }
        settings->set_initial_value(p_name, p_default);
        Dictionary info;
        info["name"] = p_name;
        info["type"] = p_default.get_type();
        info["hint"] = PROPERTY_HINT_RANGE;
        info["hint_string"] = p_hint;
        settings->add_property_info(info);
    };
    define(HARD_CUT_DISTANCE_SETTING, 1000.0, "0,10000,10,or_greater");
    define(HARD_CUT_CHECK_INTERVAL_SETTING, 5.0, "0.5,60,0.5,or_greater");
    define(HARD_CUT_CHECK_DISTANCE_SETTING, 100.0, "1,1000,1,or_greater");
    define(WORKER_THREADS_SETTING, 2, "0,16,1");
}

GndSfxServer *GndSfxServer::get(Node *p_from) {
    if (singleton || gone || Engine::get_singleton()->is_editor_hint() || !p_from->is_inside_tree()) {
        return singleton;
    }
    singleton = memnew(GndSfxServer);
    singleton->set_name("GndSfxServer");
    p_from->get_tree()->get_root()->call_deferred("add_child", singleton);
    return singleton;
}

GndSfxServer::GndSfxServer() {
    threads = setting(WORKER_THREADS_SETTING, 2);
    hard_cut_distance = setting(HARD_CUT_DISTANCE_SETTING, 1000.0);
    hard_cut_interval = setting(HARD_CUT_CHECK_INTERVAL_SETTING, 5.0);
    hard_cut_jump = setting(HARD_CUT_CHECK_DISTANCE_SETTING, 100.0);
    set_process_mode(PROCESS_MODE_ALWAYS);
    set_process_priority(-128);
    GndSfxServerPoster *poster = memnew(GndSfxServerPoster);
    poster->set_process_priority(INT32_MAX);
    add_child(poster);
}

GndSfxServer::~GndSfxServer() {
    wait_for_tick();
    for (SfxPlayerCore *core : cores) {
        core->live = false;
    }
    if (singleton == this) {
        singleton = nullptr;
        gone = true;
    }
}

void GndSfxServer::_notification(int p_what) {
    if (p_what == NOTIFICATION_READY) {
        set_process(true);
    } else if (p_what == NOTIFICATION_EXIT_TREE) {
        wait_for_tick();
    }
}

void GndSfxServer::activate(SfxPlayerCore *p_core) {
    wait_for_tick();
    p_core->awake = true;
    if (!p_core->live) {
        p_core->live = true;
        p_core->pending_delta = 0.0;
        cores.push_back(p_core);
    }
}

void GndSfxServer::remove(SfxPlayerCore *p_core) {
    wait_for_tick();
    if (p_core->live) {
        p_core->live = false;
        cores.erase(p_core);
    }
}

void GndSfxServer::wait_for_tick() {
    if (group != -1) {
        WorkerThreadPool::get_singleton()->wait_for_group_task_completion(group);
        group = -1;
    }
}

void GndSfxServer::_process(double p_delta) {
    wait_for_tick();
    // the runtimes run on audio time: a slowed down game (time_scale) does not slow its sounds
    double time_scale = Engine::get_singleton()->get_time_scale();
    double delta = (time_scale > 0.0 ? p_delta / time_scale : 0.0) * AudioServer::get_singleton()->get_playback_speed_scale();
    for (uint32_t i = 0; i < cores.size();) {
        SfxPlayerCore *core = cores[i];
        core->can_process = core->owner->can_process();
        core->pending_delta += core->can_process ? delta : 0.0;
        if (core->ticked) {
            core->ticked = false;
            core->flush(core->runtime->get_clock() + core->pending_delta);
        }
        if (!core->alive && !core->awake && !core->cut) {
            core->live = false;
            cores.remove_at(i);
        } else {
            i++;
        }
    }
    // a camera switched or moved far since the last check is checked at once: what a jump to
    // another place brings into earshot is not heard seconds late
    hard_cut_elapsed += p_delta;
    Camera3D *camera = get_viewport()->get_camera_3d();
    if (hard_cut_elapsed >= hard_cut_interval || (camera && (ObjectID(camera->get_instance_id()) != hard_cut_camera ||
            camera->get_global_position().distance_to(hard_cut_position) > hard_cut_jump))) {
        hard_cut_elapsed = 0.0;
        check_hard_cut(camera);
    }
}

void GndSfxServer::post() {
    due.clear();
    for (SfxPlayerCore *core : cores) {
        if (core->can_process && !core->cut &&
                (core->awake || core->runtime->get_clock() + core->pending_delta >= core->next_wake)) {
            core->awake = false;
            core->ticked = true;
            core->tick_delta = core->pending_delta;
            core->pending_delta = 0.0;
            due.push_back(core);
        }
    }
    if (due.is_empty()) {
        return;
    }
    if (threads <= 0) {
        for (uint32_t i = 0; i < due.size(); i++) {
            tick_core(i);
        }
        return;
    }
    group = WorkerThreadPool::get_singleton()->add_group_task(callable_mp(this, &GndSfxServer::tick_core), due.size(),
            MIN(threads, int(due.size())), true, "gnd_sfx tick");
}

// The worker's body: one player's runtime, which no other thread touches meanwhile
void GndSfxServer::tick_core(uint32_t p_index) {
    due[p_index]->tick();
}

// A player beyond the distance falls silent and stops its triggers until it comes back. Only the
// live players are looked at - an idle one has nothing to cut, and its play() checks for itself
void GndSfxServer::check_hard_cut(Camera3D *p_camera) {
    hard_cut_camera = p_camera ? ObjectID(p_camera->get_instance_id()) : ObjectID();
    hard_cut_position = p_camera ? p_camera->get_global_position() : Vector3();
    for (SfxPlayerCore *core : cores) {
        if (SfxPlayer3D *player = Object::cast_to<SfxPlayer3D>(core->owner)) {
            player->hard_cut_check(p_camera);
        }
    }
}

void GndSfxServer::_bind_methods() {
    ClassDB::bind_method(D_METHOD("wait_for_tick"), &GndSfxServer::wait_for_tick);
}

void GndSfxServerPoster::_process(double p_delta) {
    if (GndSfxServer *server = Object::cast_to<GndSfxServer>(get_parent())) {
        server->post();
    }
}
