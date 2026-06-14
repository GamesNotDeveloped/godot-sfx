@tool
extends Resource
class_name SfxClip

## One audio (or generator) segment placed on an SfxEvent's timeline or
## inside an SfxAutomation. `offset`/`length` position it on that
## timeline/parameter axis; `stream_offset` is unrelated - it's where
## playback starts *inside the source stream itself* (for skipping a
## silent lead-in, or for multiple clips sharing one long source file).

enum TriggerMode {
    TRIGGER_TIMELINE, ## Starts when the event's elapsed playback time reaches `offset`.
    TRIGGER_SUSTAIN,  ## Only starts once the event enters its release phase (see SfxEvent.adsr_enabled) - for a "tail" sample that plays as the sound winds down.
}

## Not set together with `generator_playback` unless synthesizing.
@export var stream : AudioStream
## Set together with an AudioStreamGenerator `stream` to synthesize this
## clip instead of playing back sample data - see SfxGeneratorPlayback.
@export var generator_playback: SfxGeneratorPlayback
## Position on the event's timeline (seconds) or automation's parameter
## axis (domain units) - not a position within the stream.
@export var offset := 0.0
## Visible/playable span on the timeline or parameter axis, starting at
## `offset`. 0 means "use the stream's own length."
@export var length := 0.0
## Seconds into `stream` where playback starts, independent of `offset`.
@export var stream_offset := 0.0
## Extra shift (seconds) applied when SfxAutomation.phase_locked is on, so
## this clip's loop stays phase-aligned with sibling clips - see
## SfxAutomationSyncAnalyzer.
@export var phase_offset := 0.0
@export var fade_in_curve: Curve
@export var fade_out_curve: Curve
@export var pitch_curve: Curve
@export var trigger_mode: TriggerMode = TriggerMode.TRIGGER_TIMELINE
## When this clip stops being the active one (e.g. an automation parameter
## leaves its range), true stops it immediately; false lets it finish/loop
## out via finish-on-end instead of cutting it off.
@export var cut := true
## Mixer routing (mute/solo/volume/ADSR) for this clip. Falls back to the
## owning SfxEvent's master_track when unset.
@export var track: SfxTrack
