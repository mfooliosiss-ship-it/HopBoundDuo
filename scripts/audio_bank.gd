extends Node

var sfx_enabled := true
var music_enabled := true
var sfx: Dictionary = {}
var music_player: AudioStreamPlayer

func _ready() -> void:
	sfx["hop"] = _tone(520.0, 0.075, 0.72, "square", 90.0)
	sfx["land"] = _tone(250.0, 0.055, 0.48, "triangle", -45.0)
	sfx["hit"] = _tone(110.0, 0.22, 0.95, "noise", -55.0)
	sfx["splash"] = _tone(175.0, 0.28, 0.82, "noise", 130.0)
	sfx["goal"] = _chime([660.0, 880.0, 1046.5], 0.105)
	sfx["ui"] = _tone(740.0, 0.045, 0.34, "square", 0.0)
	sfx["stage"] = _chime([392.0, 523.25, 659.25, 783.99], 0.085)
	music_player = AudioStreamPlayer.new()
	music_player.name = "RetroMusic"
	music_player.volume_db = -23.0
	music_player.stream = _make_music_loop()
	add_child(music_player)
	music_player.play()

func set_enabled(sound_on: bool, music_on: bool) -> void:
	sfx_enabled = sound_on
	music_enabled = music_on
	if music_player != null:
		music_player.volume_db = -23.0 if music_enabled else -80.0
		if music_enabled and not music_player.playing:
			music_player.play()

func play(name: String, volume_db: float = -5.0) -> void:
	if not sfx_enabled or not sfx.has(name):
		return
	var p := AudioStreamPlayer.new()
	p.stream = sfx[name]
	p.volume_db = volume_db
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()

func _tone(freq: float, duration: float, amp: float, wave_type: String, sweep: float) -> AudioStreamWAV:
	var rate := 11025
	var count := maxi(1, int(duration * float(rate)))
	var bytes := PackedByteArray()
	bytes.resize(count)
	var seed := 918273
	for i in range(count):
		var t := float(i) / float(rate)
		var env := pow(1.0 - float(i) / float(count), 1.7)
		var f := maxf(40.0, freq + sweep * t)
		var phase := fposmod(t * f, 1.0)
		var v := 0.0
		match wave_type:
			"square":
				v = 1.0 if phase < 0.5 else -1.0
			"triangle":
				v = 1.0 - 4.0 * absf(phase - 0.5)
			"noise":
				seed = int((seed * 1103515245 + 12345) & 0x7fffffff)
				v = (float(seed % 2001) / 1000.0) - 1.0
			_:
				v = sin(t * TAU * f)
		var signed_sample := int(clampf(v * amp * env, -1.0, 1.0) * 127.0)
		bytes[i] = signed_sample & 0xff
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_8_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = bytes
	return wav

func _chime(notes: Array, note_time: float) -> AudioStreamWAV:
	var rate := 11025
	var count := maxi(1, int(float(notes.size()) * note_time * float(rate)))
	var bytes := PackedByteArray()
	bytes.resize(count)
	for i in range(count):
		var t := float(i) / float(rate)
		var note_index := mini(notes.size() - 1, int(t / note_time))
		var local_t := fposmod(t, note_time)
		var env := pow(maxf(0.0, 1.0 - local_t / note_time), 0.7)
		var freq := float(notes[note_index])
		var phase := fposmod(t * freq, 1.0)
		var v := (1.0 if phase < 0.5 else -1.0) * 0.58 * env
		var signed_sample := int(clampf(v, -1.0, 1.0) * 127.0)
		bytes[i] = signed_sample & 0xff
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_8_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = bytes
	return wav

func _make_music_loop() -> AudioStreamWAV:
	var rate := 11025
	var step_time := 0.18
	var melody := [392.0, 523.25, 587.33, 523.25, 659.25, 587.33, 523.25, 440.0, 392.0, 440.0, 523.25, 659.25, 587.33, 523.25, 440.0, 329.63]
	var bass := [130.81, 130.81, 146.83, 146.83, 164.81, 164.81, 146.83, 146.83]
	var duration := float(melody.size()) * step_time
	var count := int(duration * float(rate))
	var bytes := PackedByteArray()
	bytes.resize(count)
	for i in range(count):
		var t := float(i) / float(rate)
		var step := int(t / step_time) % melody.size()
		var bass_step := int(t / (step_time * 2.0)) % bass.size()
		var f1 := float(melody[step])
		var f2 := float(bass[bass_step])
		var p1 := fposmod(t * f1, 1.0)
		var p2 := fposmod(t * f2, 1.0)
		var local_t := fposmod(t, step_time)
		var gate := 1.0 if local_t < step_time * 0.78 else 0.0
		var lead := (1.0 if p1 < 0.5 else -1.0) * 0.18 * gate
		var low := (1.0 - 4.0 * absf(p2 - 0.5)) * 0.12
		var pulse := 0.06 if fposmod(t, step_time * 2.0) < 0.025 else 0.0
		var signed_sample := int(clampf(lead + low + pulse, -1.0, 1.0) * 127.0)
		bytes[i] = signed_sample & 0xff
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_8_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = bytes
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = count
	return wav
