@tool
extends Resource
class_name SfxBank

## A named collection of SfxEvents, looked up by name at runtime (see
## get_event) - what SfxPlayer.bank/SfxPlayer3D.bank point at. Roughly
## FMOD's "bank": the unit a game loads to make a set of related sounds
## available.

@export var events: Array[SfxEvent] = []:
    set(value):
        events = value
        _rebuild_events_cache()


var _events_cache: Dictionary = {}

func _rebuild_events_cache() -> void:
    _events_cache = {}
    for event in events:
        if event and event.name:
            _events_cache[event.name] = event

func get_event(event_name: StringName) -> SfxEvent:
    return _events_cache.get(event_name)
