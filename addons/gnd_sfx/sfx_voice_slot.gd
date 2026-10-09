@tool
extends RefCounted
class_name SfxVoiceSlot

## One voice as SfxPlaybackRuntime sees it: a set of values instead of an
## AudioStreamPlayer(3D) node.
##
## The runtime runs on SfxServer's worker thread, and Godot's scene tree is
## not thread safe, so the runtime never touches a node. It writes what the
## voice should do here, and SfxPlayerCore copies it into the node and reads
## `playing`/`playback_position` back, both on the main thread. This class is
## the line between the two.

enum Transport { IDLE, PLAY, STOP }

## Bits of `dirty` - what SfxPlayerCore still has to copy into the node.
enum Dirty { STREAM = 1, TRANSPORT = 2, GAIN = 4, PITCH = 8, SPATIAL = 16 }

# --- Written by the runtime, applied by SfxPlayerCore -------------------------

var stream: AudioStream = null
var start_position: float = 0.0
var transport: Transport = Transport.IDLE
## Raised by every play request, so restarting an already playing voice is not
## mistaken for "nothing changed"
var play_serial: int = 0
var volume_db: float = 0.0
var pitch_scale: float = 1.0
## The stream is an AudioStreamGenerator and the voice needs the node's
## AudioStreamGeneratorPlayback handed back in `generator_stream_playback`
var wants_generator: bool = false
## Spatial overrides of the playing event (SfxSpatialConfig). Without them the
## node keeps whatever its SfxPlayer3D configured it with.
var spatial_override: bool = false
var spatial_position: Vector3 = Vector3.ZERO
var spatial_attenuation_model: AudioStreamPlayer3D.AttenuationModel = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
var spatial_unit_size: float = 1.0
## Below zero keeps the player's own max_distance, the way SfxSpatialConfig
## declares it
var spatial_max_distance: float = -1.0
var spatial_panning_strength: float = 1.0
var dirty: int = 0

# --- Written by SfxPlayerCore, read by the runtime ----------------------------

## True while the node plays. A play request seeds it, so the tick that starts a
## voice already sees it playing instead of dropping it before the main thread
## has applied anything.
var playing: bool = false
var playback_position: float = 0.0
var generator_stream_playback: AudioStreamGeneratorPlayback = null
## max_db of the node before the runtime used it (see _apply_slot_gain)
var base_max_db: float = 3.0
var applied_play_serial: int = 0

## Claim counter. A voice remembers the number it got when it took the slot, so
## a voice that was stolen from can tell that the slot is no longer its own.
var token: int = 0


## Takes the slot for a new voice and returns the token identifying that claim.
func claim() -> int:
    token += 1
    return token


func play_stream(p_stream: AudioStream, p_position: float) -> void:
    swap_stream(p_stream)
    replay(p_position)


## Puts another stream on the slot without restarting it.
func swap_stream(p_stream: AudioStream) -> void:
    stream = p_stream
    dirty |= Dirty.STREAM


## Starts the slot's current stream again from `p_position`.
func replay(p_position: float) -> void:
    start_position = p_position
    transport = Transport.PLAY
    play_serial += 1
    playing = true
    playback_position = p_position
    dirty |= Dirty.TRANSPORT


func stop_playback() -> void:
    transport = Transport.STOP
    playing = false
    playback_position = 0.0
    generator_stream_playback = null
    dirty |= Dirty.TRANSPORT


func apply_gain(p_volume_db: float) -> void:
    if is_equal_approx(volume_db, p_volume_db):
        return
    volume_db = p_volume_db
    dirty |= Dirty.GAIN


func apply_pitch(p_pitch_scale: float) -> void:
    if is_equal_approx(pitch_scale, p_pitch_scale):
        return
    pitch_scale = p_pitch_scale
    dirty |= Dirty.PITCH


func apply_spatial(config: SfxSpatialConfig, unit_size: float) -> void:
    if (spatial_override and spatial_position == config.position
            and spatial_attenuation_model == config.attenuation_model
            and is_equal_approx(spatial_unit_size, unit_size)
            and is_equal_approx(spatial_max_distance, config.max_distance)
            and is_equal_approx(spatial_panning_strength, config.panning_strength)):
        return
    spatial_override = true
    spatial_position = config.position
    spatial_attenuation_model = config.attenuation_model
    spatial_unit_size = unit_size
    spatial_max_distance = config.max_distance
    spatial_panning_strength = config.panning_strength
    dirty |= Dirty.SPATIAL


## Gives the node its SfxPlayer3D's own spatial values back.
func clear_spatial() -> void:
    if not spatial_override:
        return
    spatial_override = false
    dirty |= Dirty.SPATIAL


## Back to what an unused slot looks like, with the stream optionally dropped so
## the node stops holding it.
func reset(clear_stream: bool) -> void:
    stop_playback()
    apply_pitch(1.0)
    apply_gain(0.0)
    clear_spatial()
    wants_generator = false
    if clear_stream:
        stream = null
        dirty |= Dirty.STREAM
