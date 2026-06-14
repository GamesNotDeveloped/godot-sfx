@tool
extends EditorInspectorPlugin
class_name SfxAutomationInspectorPlugin

## Adds an "Auto Sync Phase + Loops" button to the inspector whenever an
## SfxAutomation resource is selected. Pressing it runs
## SfxAutomationSyncAnalyzer over the automation's clips and writes the
## resulting per-clip phase offsets and loop points back to disk, so
## multi-sample loops (e.g. idle/mid/high RPM engine layers) stay in sync
## with each other without the user tuning offsets by hand.

const BUTTON_TEXT := "Auto Sync Phase + Loops"


## Engine hook (EditorInspectorPlugin): asked once per selected object to
## decide whether this plugin should add controls to its inspector.
func _can_handle(object: Object) -> bool:
    return object is SfxAutomation


## Engine hook (EditorInspectorPlugin): called once for the selected object
## before its properties are drawn. Builds the sync button, its status
## label, and the confirmation dialog, and injects them into the inspector.
func _parse_begin(object: Object) -> void:
    var automation := object as SfxAutomation
    if not automation:
        return

    var container := VBoxContainer.new()
    container.size_flags_horizontal = Control.SIZE_EXPAND_FILL

    var button := Button.new()
    button.text = BUTTON_TEXT
    button.tooltip_text = "Analyze clip timing, set phase offsets, and rewrite supported loop offsets."
    button.disabled = _count_stream_clips(automation) < 2
    container.add_child(button)

    var confirmation := ConfirmationDialog.new()
    confirmation.title = BUTTON_TEXT
    confirmation.dialog_text = "Analyze the current automation and apply phase/loop changes?"
    confirmation.ok_button_text = "Analyze"
    container.add_child(confirmation)

    var status := Label.new()
    status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    status.text = "Requires at least two clips with AudioStream resources."
    if not button.disabled:
        status.text = "Analyzes PCM from the current automation and writes phase + loop settings."
    container.add_child(status)

    button.pressed.connect(_on_sync_confirmation_requested.bind(confirmation))
    confirmation.confirmed.connect(_on_sync_pressed.bind(automation, button, status))
    add_custom_control(container)


## Shows the "are you sure" dialog when the sync button is pressed.
func _on_sync_confirmation_requested(confirmation: ConfirmationDialog) -> void:
    if not confirmation:
        return
    confirmation.popup_centered()


## Runs the actual sync after the user confirms: analyzes the automation,
## writes the estimated phase offset (and, where supported, loop offset)
## onto each clip, saves the owning resource to disk, reimports any audio
## files whose loop settings changed, and reports a summary in `status`.
func _on_sync_pressed(automation: SfxAutomation, button: Button, status: Label) -> void:
    button.disabled = true
    status.text = "Analyzing clips..."

    var result: Dictionary = SfxAutomationSyncAnalyzer.analyze_automation(automation)
    if not result.get("ok", false):
        status.text = result.get("error", "Auto-sync failed.")
        button.disabled = false
        return

    var touched_stream_paths := PackedStringArray()
    var warnings: PackedStringArray = result.get("warnings", PackedStringArray())

    automation.phase_locked = true
    automation.phase_period = result["phase_period"]

    for clip_result in result["clip_results"]:
        var clip: SfxClip = clip_result["clip"]
        clip.phase_offset = clip_result["phase_offset"]

        if clip_result.has("loop_offset"):
            var loop_apply := _apply_loop_offset(clip, clip_result["loop_offset"])
            if loop_apply.get("ok", false):
                var stream_path: String = loop_apply.get("stream_path", "")
                if stream_path and not touched_stream_paths.has(stream_path):
                    touched_stream_paths.append(stream_path)
            else:
                var error_text: String = loop_apply.get("error", "")
                if error_text:
                    warnings.append(error_text)

    automation.emit_changed()
    var save_result := _save_automation_owner(automation)
    if not save_result.get("ok", false):
        var save_error: String = save_result.get("error", "")
        if save_error:
            warnings.append(save_error)

    _reimport_streams(touched_stream_paths)

    var summary := "Applied phase sync to %d clips. phase_period=%.4fs" % [
        result["clip_results"].size(),
        result["phase_period"],
    ]
    if warnings:
        summary += "\nWarnings: %s" % [", ".join(warnings)]
    status.text = summary
    button.disabled = false


## Counts clips that have a playable stream assigned, to decide whether
## there's enough data for the analyzer to run (it needs at least two).
func _count_stream_clips(automation: SfxAutomation) -> int:
    var count := 0
    for clip in automation.clips:
        if clip and clip.stream:
            count += 1
    return count


## Writes an estimated loop offset onto a clip's stream and persists it in
## the stream's .import file, so the offset survives the next reimport
## instead of only living in memory until the next asset refresh.
func _apply_loop_offset(clip: SfxClip, loop_offset: float) -> Dictionary:
    if not clip or not clip.stream:
        return {"ok": false, "error": "Clip is missing an AudioStream."}
    var stream: AudioStream = clip.stream
    if not SfxStreamLoopSupport.supports_persisted_loop_offset(stream):
        return {"ok": false, "error": "Stream type does not support loop_offset editing."}

    SfxStreamLoopSupport.set_looping(stream, true)
    SfxStreamLoopSupport.set_persisted_loop_offset(stream, loop_offset)

    var stream_path := stream.resource_path
    if not stream_path:
        return {"ok": false, "error": "Stream has no resource_path, so loop_offset could not be persisted."}

    var import_path := "%s.import" % stream_path
    if not FileAccess.file_exists(import_path):
        return {"ok": false, "error": "Missing import config for %s." % stream_path}

    var config := ConfigFile.new()
    var load_error := config.load(import_path)
    if not load_error == OK:
        return {"ok": false, "error": "Could not load %s." % import_path}

    config.set_value("params", "loop", true)
    config.set_value("params", "loop_offset", loop_offset)

    var save_error := config.save(import_path)
    if not save_error == OK:
        return {"ok": false, "error": "Could not save %s." % import_path}

    return {
        "ok": true,
        "stream_path": stream_path,
    }


## Reloads and re-saves the .tres/.res file that owns this automation, so
## the phase/loop edits above are written to disk right away instead of
## waiting for the user to manually save the scene or resource.
func _save_automation_owner(automation: SfxAutomation) -> Dictionary:
    var owner_path := _resolve_owner_path(automation.resource_path)
    if not owner_path:
        return {"ok": false, "error": "Automation resource has no save path; save it manually after apply."}
    if not owner_path.ends_with(".tres") and not owner_path.ends_with(".res"):
        return {"ok": false, "error": "Auto-save currently supports .tres/.res owners only; save the resource manually."}

    var owner_resource := ResourceLoader.load(owner_path, "", ResourceLoader.CACHE_MODE_REUSE)
    if not owner_resource:
        return {"ok": false, "error": "Could not reload %s for saving." % owner_path}

    var save_error := ResourceSaver.save(owner_resource, owner_path)
    if not save_error == OK:
        return {"ok": false, "error": "Could not save %s." % owner_path}
    return {"ok": true}


## Asks the editor to reimport the audio files whose loop settings were
## just changed, so the reimported stream picks up the new loop_offset.
func _reimport_streams(stream_paths: PackedStringArray) -> void:
    if not stream_paths:
        return

    var filesystem := EditorInterface.get_resource_filesystem()
    if not filesystem:
        return
    filesystem.reimport_files(stream_paths)


## Strips the "::subresource_id" suffix Godot appends to the resource_path
## of resources embedded in a scene or another resource, returning the
## path of the actual file that needs to be saved.
func _resolve_owner_path(resource_path: String) -> String:
    if not resource_path:
        return ""
    var separator := resource_path.find("::")
    if separator == -1:
        return resource_path
    return resource_path.substr(0, separator)
