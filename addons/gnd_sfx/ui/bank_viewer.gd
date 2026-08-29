extends Control
class_name BankViewer

signal event_requested(event: SfxEvent)

const BankEventButtonScene := preload("./bank_event_button.tscn")

@export var bank: SfxBank:
    set(value):
        bank = value
        _refresh()

@onready var _summary_label: Label = $Margin/VBox/SummaryLabel
@onready var _event_list: VBoxContainer = $Margin/VBox/Scroll/EventList
@onready var _empty_label: Label = $Margin/VBox/EmptyLabel


func _ready() -> void:
    _refresh()


func _refresh() -> void:
    if not is_node_ready():
        return

    for child in _event_list.get_children():
        child.queue_free()

    if not bank:
        _summary_label.text = "No bank assigned"
        _empty_label.text = "Assign an SfxBank to BankViewer in demo.tscn."
        _empty_label.show()
        return

    var valid_events: Array[SfxEvent] = []
    for event in bank.events:
        if event is SfxEvent:
            valid_events.append(event as SfxEvent)

    _summary_label.text = "%d events" % valid_events.size()
    if not valid_events:
        _empty_label.text = "This bank does not define any events."
        _empty_label.show()
        return

    _empty_label.hide()
    for event in valid_events:
        var name_text: String = event.name
        if not name_text:
            name_text = "Unnamed Event"
        var button: Button = BankEventButtonScene.instantiate()
        button.text = "%s    %d timeline clips    %d automations" % [
            name_text,
            event.clips.size(),
            event.automations.size(),
        ]
        button.pressed.connect(_on_event_pressed.bind(event))
        _event_list.add_child(button)


func _on_event_pressed(event: SfxEvent) -> void:
    event_requested.emit(event)
