@tool
extends EditorPlugin

var _automation_inspector_plugin: EditorInspectorPlugin


func _enter_tree() -> void:
    _add_project_setting(
            "gnd_sfx/max_tracks", 4, TYPE_INT,
            PROPERTY_HINT_RANGE, "1,32,1")
    _add_project_setting(
            "gnd_sfx/hard_cut_distance", 1000.0, TYPE_FLOAT,
            PROPERTY_HINT_RANGE, "0.0,10000.0,10.0,or_greater")
    _add_project_setting(
            "gnd_sfx/hard_cut_check_interval", 5.0, TYPE_FLOAT,
            PROPERTY_HINT_RANGE, "0.5,60.0,0.5,or_greater")
    _automation_inspector_plugin = SfxAutomationInspectorPlugin.new()
    add_inspector_plugin(_automation_inspector_plugin)


func _enable_plugin() -> void:
    add_autoload_singleton("GndSfxSystem", "res://addons/gnd_sfx/gnd_sfx_system.gd")


func _disable_plugin() -> void:
    remove_autoload_singleton("GndSfxSystem")


func _exit_tree() -> void:
    if _automation_inspector_plugin:
        remove_inspector_plugin(_automation_inspector_plugin)
        _automation_inspector_plugin = null


func _add_project_setting(
        name:String, default_value:Variant, type:int,
        hint:int = PROPERTY_HINT_NONE, hint_string:String = "") -> void:
    if ProjectSettings.has_setting(name):
        return
    ProjectSettings.set_setting(name, default_value)
    ProjectSettings.add_property_info({
        "name": name, "type": type, "hint": hint, "hint_string": hint_string})
    ProjectSettings.set_initial_value(name, default_value)
