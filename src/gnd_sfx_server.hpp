#pragma once

// Ticks every player of the game: SfxPlayer/SfxPlayer3D do not process themselves. Made by the
// first player that needs it (no autoload), as a child of the root.
//
// The tick runs on WorkerThreadPool, over gnd_sfx/worker_threads threads (0: on the main thread),
// each player's runtime on one thread at a time. What makes it safe is the schedule:
//   * the tick is posted at the very end of the frame's _process (GndSfxServerPoster, last by
//     process priority), so it runs while the engine renders and steps the next physics frame;
//   * GndSfxServer's own _process, first by priority, waits for it and copies its results into the
//     audio nodes (SfxPlayerCore::flush) - the worker touches no node at all;
//   * any player API called meanwhile (a _physics_process, a signal) waits for it first.
// A player is visited only while its runtime has work to do: a held loop or a sound between its
// fades is not ticked at all.

#include "sfx_player_core.hpp"

#include <godot_cpp/classes/node.hpp>

namespace godot {

class Camera3D;

class GndSfxServer : public Node {
    GDCLASS(GndSfxServer, Node);

    static GndSfxServer *singleton;
    static bool gone; // the game is closing: no new server
    LocalVector<SfxPlayerCore *> cores; // the live ones
    LocalVector<SfxPlayerCore *> due; // what the posted tick works on
    int64_t group = -1;
    int threads = 2;
    double hard_cut_distance = 1000.0, hard_cut_interval = 5.0, hard_cut_elapsed = 0.0, hard_cut_jump = 100.0;
    // the camera of the last distance check and where it stood
    ObjectID hard_cut_camera;
    Vector3 hard_cut_position;

    void tick_core(uint32_t p_index);
    void check_hard_cut(Camera3D *p_camera);

protected:
    static void _bind_methods();
    void _notification(int p_what);

public:
    static constexpr const char *HARD_CUT_DISTANCE_SETTING = "gnd_sfx/hard_cut_distance";
    static constexpr const char *HARD_CUT_CHECK_INTERVAL_SETTING = "gnd_sfx/hard_cut_check_interval";
    static constexpr const char *HARD_CUT_CHECK_DISTANCE_SETTING = "gnd_sfx/hard_cut_check_distance";
    static constexpr const char *WORKER_THREADS_SETTING = "gnd_sfx/worker_threads";
    static void register_settings();

    // The server of the game `p_from` is in, made when there is none; nullptr in the editor
    static GndSfxServer *get(Node *p_from);
    static GndSfxServer *get_singleton() { return singleton; }
    double get_hard_cut_distance() const { return hard_cut_distance; }

    GndSfxServer();
    ~GndSfxServer();
    void activate(SfxPlayerCore *p_core);
    void remove(SfxPlayerCore *p_core);
    void wait_for_tick();
    void post();
    void _process(double p_delta) override;
};

// The last node to process: posts the tick (see GndSfxServer)
class GndSfxServerPoster : public Node {
    GDCLASS(GndSfxServerPoster, Node);

protected:
    static void _bind_methods() {}

public:
    void _process(double p_delta) override;
};

} // namespace godot
