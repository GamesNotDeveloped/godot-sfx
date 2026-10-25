@tool
extends EditorPlugin

## The editor side of gnd_sfx. The classes and project settings come from the GDExtension
## (gnd_sfx.gdextension); GndSfxServer makes itself in game, so there is no autoload.

const OLD_AUTOLOAD := "GndSfxServer"

var _automation_inspector_plugin: EditorInspectorPlugin


func _enter_tree() -> void:
    # the GDScript version of the addon registered the server as an autoload
    if ProjectSettings.has_setting("autoload/" + OLD_AUTOLOAD):
        remove_autoload_singleton(OLD_AUTOLOAD)
    _automation_inspector_plugin = SfxAutomationInspectorPlugin.new()
    add_inspector_plugin(_automation_inspector_plugin)


func _exit_tree() -> void:
    if _automation_inspector_plugin:
        remove_inspector_plugin(_automation_inspector_plugin)
        _automation_inspector_plugin = null
