extends Node

# Every sound effect here is synthesized at runtime (short sine-tone
# sequences written directly into PCM data) rather than shipped as audio
# asset files -- there was no audio bus or a single sound file anywhere in
# the project before this (confirmed by grep before adding it), and
# generating real recorded/mixed audio assets isn't something this pass can
# do. This is the audio equivalent of the game's already-procedural menu
# art (see ui/mode_icon.gd's pre-Art-Tool-Icons-page fallback): a real, if
# minimal, SFX layer with zero new binary assets to ship or review.

const SAMPLE_RATE := 22050
const POOL_SIZE := 6

var _streams := {} # name -> AudioStreamWAV
var _pool: Array[AudioStreamPlayer] = []
var _next_pool_index := 0

func _ready() -> void:
	_streams["tag"] = _make_tone([880.0, 440.0], 0.12, 0.5)
	_streams["countdown_tick"] = _make_tone([660.0], 0.06, 0.35)
	_streams["victory"] = _make_tone([523.25, 659.25, 783.99], 0.5, 0.5)
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)

## Round-robins across a small player pool rather than one shared player, so
## two calls landing close together (e.g. two players tagged back-to-back
## across a short window) don't cut each other off.
func play(sound_name: String) -> void:
	if not _streams.has(sound_name) or _pool.is_empty():
		return
	var p := _pool[_next_pool_index]
	_next_pool_index = (_next_pool_index + 1) % _pool.size()
	p.stream = _streams[sound_name]
	p.play()

## Synthesizes a short clip from one or more sequential tone segments --
## `freqs` play back-to-back, each getting an equal share of `duration`
## seconds. A linear fade to silence across the whole clip avoids an
## audible click at the end (no per-segment fade needed since segments run
## back-to-back at zero-crossing-agnostic boundaries anyway -- at these
## short durations/frequencies any seam is inaudible under the overall
## fade).
func _make_tone(freqs: Array, duration: float, volume: float) -> AudioStreamWAV:
	var total_frames := int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(total_frames * 2) # 16-bit mono
	var segment_frames := maxi(total_frames / maxi(freqs.size(), 1), 1)
	var frame := 0
	for freq in freqs:
		for i in segment_frames:
			if frame >= total_frames:
				break
			var t := float(i) / SAMPLE_RATE
			var fade := 1.0 - float(frame) / float(total_frames)
			var sample := sin(TAU * float(freq) * t) * volume * fade
			var value := int(clampf(sample, -1.0, 1.0) * 32767.0)
			data.encode_s16(frame * 2, value)
			frame += 1
	var stream := AudioStreamWAV.new()
	stream.data = data
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	return stream
