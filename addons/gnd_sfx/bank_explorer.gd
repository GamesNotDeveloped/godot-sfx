extends Control

const EventViewerScene := preload("res://addons/gnd_sfx/ui/event_viewer.tscn")

@export var demo_bank: SfxBank:
    set(value):
        if _bank_viewer:
            _bank_viewer.bank = value

        if _player:
            _player.bank = value
        demo_bank = value

@onready var _bank_viewer = $BankViewer
@onready var _player: SfxPlayer = $PreviewPlayer


func _ready() -> void:
    _bank_viewer.bank = demo_bank
    _bank_viewer.event_requested.connect(_on_event_requested)
    _player.bank = demo_bank


func _on_event_requested(event: SfxEvent) -> void:
    if event == null:
        return

    var viewer = EventViewerScene.instantiate()
    add_child(viewer)
    viewer.configure(event, _player)
    viewer.popup_centered_ratio(0.72)
