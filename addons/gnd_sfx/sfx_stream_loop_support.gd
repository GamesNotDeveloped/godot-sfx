class_name SfxStreamLoopSupport
extends RefCounted

## Registry of per-AudioStream-type loop handling, keyed by stream.get_class().
## Replaces the `stream is AudioStreamWAV / is AudioStreamOggVorbis /
## is AudioStreamMP3` chains that used to be duplicated independently in
## sfx_playback_runtime.gd, sfx_automation_sync_analyzer.gd and
## sfx_automation_inspector_plugin.gd.
##
## Each handler class implements: is_looping(stream), set_looping(stream,
## enabled), SUPPORTS_PERSISTED_OFFSET (const bool), and - only when that
## const is true - set_persisted_offset(stream, offset). Support another
## stream type by adding an entry to HANDLERS.

class WavLoopHandler:
    const SUPPORTS_PERSISTED_OFFSET := false

    static func is_looping(stream) -> bool:
        return not stream.loop_mode == AudioStreamWAV.LOOP_DISABLED

    static func set_looping(stream, enabled: bool) -> void:
        stream.loop_mode = AudioStreamWAV.LOOP_FORWARD if enabled else AudioStreamWAV.LOOP_DISABLED


class LoopPropertyHandler:
    # Shared by AudioStreamOggVorbis and AudioStreamMP3 - both expose the
    # same `loop: bool` / `loop_offset: float` properties.
    const SUPPORTS_PERSISTED_OFFSET := true

    static func is_looping(stream) -> bool:
        return stream.loop

    static func set_looping(stream, enabled: bool) -> void:
        stream.loop = enabled

    static func set_persisted_offset(stream, offset: float) -> void:
        stream.loop_offset = offset


static var HANDLERS := {
    "AudioStreamWAV": WavLoopHandler,
    "AudioStreamOggVorbis": LoopPropertyHandler,
    "AudioStreamMP3": LoopPropertyHandler,
}


static func is_looping(stream: AudioStream) -> bool:
    if not stream:
        return false
    var handler = HANDLERS.get(stream.get_class())
    if handler:
        return handler.is_looping(stream)
    if "loop" in stream:
        return bool(stream.loop)
    return false


static func set_looping(stream: AudioStream, enabled: bool) -> void:
    if not stream:
        return
    var handler = HANDLERS.get(stream.get_class())
    if handler:
        handler.set_looping(stream, enabled)
        return
    if "loop" in stream:
        stream.loop = enabled


static func supports_persisted_loop_offset(stream: AudioStream) -> bool:
    if not stream:
        return false
    var handler = HANDLERS.get(stream.get_class())
    return handler != null and handler.SUPPORTS_PERSISTED_OFFSET


static func set_persisted_loop_offset(stream: AudioStream, offset: float) -> bool:
    if not stream:
        return false
    var handler = HANDLERS.get(stream.get_class())
    if not handler or not handler.SUPPORTS_PERSISTED_OFFSET:
        return false
    handler.set_persisted_offset(stream, offset)
    return true
