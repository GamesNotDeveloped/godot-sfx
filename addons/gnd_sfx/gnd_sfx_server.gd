extends Node

## The one place playback is ticked. SfxPlayer/SfxPlayer3D register their
## SfxPlayerCore here and do not process themselves - a scenery holds hundreds
## of players, and hundreds of GDScript _process callbacks cost more than the
## work inside them.
##
## The tick runs on a worker thread, and what makes that safe is the schedule
## rather than a lock:
##   * it is posted at `process_frame`, after every node's _process of the
##     frame has run;
##   * it is waited for at the start of the next frame, in _physics_process and
##     _process, before any game code of that frame runs.
## The worker therefore only ever runs while the main thread sits inside the
## engine - except for whatever else listens to `process_frame` after
## `_post_tick`: a player's API called from there would mutate the very state
## the tick reads. So every call of that API waits for the tick first
## (wait_for_tick()). That API is main-thread only.
##
## The worker touches no node at all: a tick writes SfxVoiceSlots, and
## SfxPlayerCore.flush()/observe() copy them into the audio nodes here.

const HARD_CUT_DISTANCE_SETTING:StringName = &"gnd_sfx/hard_cut_distance"
const HARD_CUT_CHECK_INTERVAL_SETTING:StringName = &"gnd_sfx/hard_cut_check_interval"

var _players:Array[SfxPlayer3D] = []
## Cores with something to do, the only ones a tick visits
var _cores:Array[SfxPlayerCore] = []
var _timer:Timer
var _task_id:int = -1
var _tick_delta:float = 0.0


func _ready() -> void:
    process_priority = -128
    process_physics_priority = -128
    set_process(false)
    set_physics_process(false)
    _timer = Timer.new()
    _timer.wait_time = float(ProjectSettings.get_setting(
            HARD_CUT_CHECK_INTERVAL_SETTING, 5.0))
    _timer.timeout.connect(_check_hard_cut)
    add_child(_timer)
    _timer.start()
    get_tree().process_frame.connect(_post_tick)
    call_deferred("_check_hard_cut")


func register_player(player:SfxPlayer3D) -> void:
    _players.append(player)


func unregister_player(player:SfxPlayer3D) -> void:
    _players.erase(player)


## Starts visiting `core` again, because something was played, stopped or
## modulated on it.
func activate_core(core:SfxPlayerCore) -> void:
    wait_for_tick()
    if core.ticking:
        return
    core.ticking = true
    _cores.append(core)
    set_process(true)
    set_physics_process(true)


func unregister_core(core:SfxPlayerCore) -> void:
    wait_for_tick()
    if not core.ticking:
        return
    core.ticking = false
    _cores.erase(core)


func _physics_process(_delta:float) -> void:
    wait_for_tick()


func _process(delta:float) -> void:
    wait_for_tick()
    for core:SfxPlayerCore in _cores:
        core.flush()
        core.observe()
    _drop_idle_cores()
    _tick_delta = delta


func _post_tick() -> void:
    if not _cores or not _task_id == -1:
        return
    _task_id = WorkerThreadPool.add_task(_run_tick)


## The worker body. Runs off the main thread - see the class comment.
func _run_tick() -> void:
    for core:SfxPlayerCore in _cores:
        core.tick(_tick_delta)


## Returns once no tick is running - a player calls it before it touches what
## the tick works on
func wait_for_tick() -> void:
    if _task_id == -1:
        return
    WorkerThreadPool.wait_for_task_completion(_task_id)
    _task_id = -1


func _drop_idle_cores() -> void:
    for index in range(_cores.size() - 1, -1, -1):
        var core:SfxPlayerCore = _cores[index]
        if core.requires_process():
            continue
        core.ticking = false
        _cores.remove_at(index)
    if _cores:
        return
    set_process(false)
    set_physics_process(false)


func _check_hard_cut() -> void:
    var camera:Camera3D = get_viewport().get_camera_3d()
    for player:SfxPlayer3D in _players:
        if is_instance_valid(player):
            player.hard_cut_check(camera)


func _exit_tree() -> void:
    wait_for_tick()
