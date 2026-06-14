extends HBoxContainer
class_name TrackLaneView

@onready var header: TrackLaneHeader = $Header
@onready var waveform: TrackLaneWaveform = $Waveform

@export var index := 0:
    set(value):
        index = value
        _apply()

@export var track: SfxTrack:
    set(value):
        track = value
        _apply()

@export var clips: Array[SfxClip] = []:
    set(value):
        clips = value
        _apply()

@export var column_width := 220.0:
    set(value):
        column_width = value
        _apply()

@export var row_height := 52.0:
    set(value):
        row_height = value
        _apply()


func _ready() -> void:
    _apply()


func _apply() -> void:
    if not is_node_ready():
        return
    header.custom_minimum_size = Vector2(column_width, row_height)
    waveform.custom_minimum_size = Vector2(0.0, row_height)
    header.index = index
    header.track = track
    waveform.ensure_bar_count(clips.size())
