extends VBoxContainer
class_name TrackLaneHeader

@onready var title_label: Label = $Row1/TitleLabel
@onready var solo_button: Button = $Row1/SoloButton
@onready var mute_button: Button = $Row1/MuteButton
@onready var gain_slider: HSlider = $Row2/GainSlider
@onready var gain_spin_box: SpinBox = $Row2/GainSpinBox

@export var index := 0:
    set(value):
        index = value
        _apply_track()

@export var selection_border_color := Color(1.0, 0.831373, 0.117647, 1.0)
@export var selection_border_width := 2.0

var selected := false:
    set(value):
        if selected == value:
            return
        selected = value
        queue_redraw()

var track: SfxTrack:
    set(value):
        if track and track.changed.is_connected(_apply_track):
            track.changed.disconnect(_apply_track)
        track = value
        if track:
            track.changed.connect(_apply_track)
        _apply_track()


func _ready() -> void:
    _hide_grabber(gain_slider)
    gain_spin_box.get_line_edit().add_theme_font_size_override("font_size", 10)
    _apply_track()


func _draw() -> void:
    if selected:
        draw_rect(Rect2(Vector2.ZERO, size), selection_border_color, false, selection_border_width)


static func _hide_grabber(slider: HSlider) -> void:
    var blank_image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
    blank_image.fill(Color(0, 0, 0, 0))
    var blank_texture := ImageTexture.create_from_image(blank_image)
    slider.add_theme_icon_override("grabber", blank_texture)
    slider.add_theme_icon_override("grabber_highlight", blank_texture)
    slider.add_theme_icon_override("grabber_disabled", blank_texture)


func _apply_track() -> void:
    _disconnect_track_signals()
    var has_track := true if track else false
    solo_button.visible = has_track
    mute_button.visible = has_track
    gain_slider.visible = has_track
    gain_spin_box.visible = has_track
    if not has_track:
        title_label.text = ""
        return
    var track_name: String = track.track_name
    title_label.text = track_name if track_name else "Track %d" % (index + 1)
    solo_button.button_pressed = track.solo
    mute_button.button_pressed = track.mute
    _sync_gain_controls(track.volume_db)
    solo_button.toggled.connect(_on_solo_toggled)
    mute_button.toggled.connect(_on_mute_toggled)
    gain_slider.value_changed.connect(_on_gain_changed)
    gain_spin_box.value_changed.connect(_on_gain_changed)


func _disconnect_track_signals() -> void:
    if solo_button.toggled.is_connected(_on_solo_toggled):
        solo_button.toggled.disconnect(_on_solo_toggled)
    if mute_button.toggled.is_connected(_on_mute_toggled):
        mute_button.toggled.disconnect(_on_mute_toggled)
    if gain_slider.value_changed.is_connected(_on_gain_changed):
        gain_slider.value_changed.disconnect(_on_gain_changed)
    if gain_spin_box.value_changed.is_connected(_on_gain_changed):
        gain_spin_box.value_changed.disconnect(_on_gain_changed)


func _on_solo_toggled(pressed: bool) -> void:
    track.solo = pressed


func _on_mute_toggled(pressed: bool) -> void:
    track.mute = pressed


func _on_gain_changed(value: float) -> void:
    track.volume_db = value
    _sync_gain_controls(value)


func _sync_gain_controls(value: float) -> void:
    gain_slider.set_value_no_signal(value)
    gain_spin_box.set_value_no_signal(value)
