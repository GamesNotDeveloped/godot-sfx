extends Node

const HARD_CUT_DISTANCE_SETTING:StringName = &"gnd_sfx/hard_cut_distance"
const HARD_CUT_CHECK_INTERVAL_SETTING:StringName = &"gnd_sfx/hard_cut_check_interval"
var _players:Array[SfxPlayer3D] = []
var _timer:Timer


func _ready() -> void:
    _timer = Timer.new()
    _timer.wait_time = float(ProjectSettings.get_setting(
            HARD_CUT_CHECK_INTERVAL_SETTING, 5.0))
    _timer.timeout.connect(_on_timer_timeout)
    add_child(_timer)
    _timer.start()
    call_deferred("_check_hard_cut")


func register_player(player:SfxPlayer3D) -> void:
    _players.append(player)


func unregister_player(player:SfxPlayer3D) -> void:
    _players.erase(player)


func _on_timer_timeout() -> void:
    _check_hard_cut()


func _check_hard_cut() -> void:
    var camera:Camera3D = get_viewport().get_camera_3d()
    for player:SfxPlayer3D in _players:
        if is_instance_valid(player):
            player.hard_cut_check(camera)
