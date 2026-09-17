extends Node3D

const PORT := 24567
const MAX_PLAYERS := 4
const START_ROW := 10
const GOAL_ROW := 0
const X_STEP := 1.6
const Z_STEP := 1.45
const TRACK_HALF := 8.6

var net_mode := "solo"
var players: Dictionary = {}
var player_states: Dictionary = {}
var road_objects: Array[Dictionary] = []
var river_objects: Array[Dictionary] = []
var sync_accum := 0.0
var last_hop_ms: Dictionary = {}

var camera: Camera3D
var status_label: Label
var score_label: Label
var ip_line: LineEdit

func _ready() -> void:
	_build_world()
	_build_ui()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_start_solo()

func _process(delta: float) -> void:
	_update_movers()
	if net_mode == "solo" or net_mode == "host":
		_server_hazards(delta)
		sync_accum += delta
		if net_mode == "host" and sync_accum >= 0.05:
			sync_accum = 0.0
			for peer_id in player_states.keys():
				var s: Dictionary = player_states[peer_id]
				sync_player.rpc(int(peer_id), int(s.row), float(s.x), int(s.score))
	_refresh_score_label()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_UP, KEY_W:
				_request_move(Vector2i(0, -1))
			KEY_DOWN, KEY_S:
				_request_move(Vector2i(0, 1))
			KEY_LEFT, KEY_A:
				_request_move(Vector2i(-1, 0))
			KEY_RIGHT, KEY_D:
				_request_move(Vector2i(1, 0))

func _build_world() -> void:
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#7ac7d9")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#fff4cf")
	env.ambient_light_energy = 1.25
	env_node.environment = env
	add_child(env_node)

	camera = Camera3D.new()
	camera.position = Vector3(0.0, 15.5, 14.5)
	camera.fov = 44.0
	add_child(camera)
	camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)

	for row in range(START_ROW + 1):
		var color := Color("#6aa84f")
		if row >= 5 and row <= 9:
			color = Color("#3b3f43")
		elif row >= 1 and row <= 3:
			color = Color("#2673a8")
		elif row == 4:
			color = Color("#9b8f63")
		_add_box(Vector3(17.8, 0.18, Z_STEP - 0.04), Vector3(0.0, -0.18, _row_z(row)), color)

	for row in range(5, 10):
		for x in range(-4, 5):
			if x % 2 == 0:
				_add_box(Vector3(0.75, 0.03, 0.08), Vector3(float(x) * X_STEP, -0.07, _row_z(row) - Z_STEP * 0.48), Color("#d5c36a"))

	for x in [-6.4, -3.2, 0.0, 3.2, 6.4]:
		var pad := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.72
		mesh.bottom_radius = 0.72
		mesh.height = 0.15
		pad.mesh = mesh
		pad.position = Vector3(float(x), 0.02, _row_z(0))
		pad.material_override = _mat(Color("#d6d957"))
		add_child(pad)

	_build_road_objects()
	_build_river_objects()

func _build_road_objects() -> void:
	var speeds := [2.8, -3.2, 3.8, -2.5, 4.2]
	var colors := [Color("#d84b4b"), Color("#f1b84b"), Color("#74a7e6"), Color("#d26be0"), Color("#e6e6e6")]
	for lane_index in range(5):
		var row := 5 + lane_index
		for i in range(4):
			var mesh := _add_box(Vector3(1.65, 0.55, 0.86), Vector3.ZERO, colors[lane_index])
			mesh.position.y = 0.34
			road_objects.append({"node": mesh, "row": row, "speed": speeds[lane_index], "phase": float(i) * 4.6 + float(lane_index) * 1.7})

func _build_river_objects() -> void:
	var speeds := [1.35, -1.15, 1.6]
	for lane_index in range(3):
		var row := 1 + lane_index
		for i in range(4):
			var mesh := _add_box(Vector3(3.2, 0.32, 0.92), Vector3.ZERO, Color("#7b4e2a"))
			mesh.position.y = 0.18
			river_objects.append({"node": mesh, "row": row, "speed": speeds[lane_index], "phase": float(i) * 5.1 + float(lane_index) * 2.1})

func _update_movers() -> void:
	var now := Time.get_unix_time_from_system()
	for o in road_objects:
		var n: MeshInstance3D = o.node
		n.position.x = _moving_x(float(o.speed), float(o.phase), now)
		n.position.z = _row_z(int(o.row))
	for o in river_objects:
		var n: MeshInstance3D = o.node
		n.position.x = _moving_x(float(o.speed), float(o.phase), now)
		n.position.z = _row_z(int(o.row))

func _moving_x(speed: float, phase: float, now: float) -> float:
	return fposmod(now * speed + phase + TRACK_HALF, TRACK_HALF * 2.0) - TRACK_HALF

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(root)

	var top := PanelContainer.new()
	top.anchor_right = 1.0
	top.offset_left = 10.0
	top.offset_top = 10.0
	top.offset_right = -10.0
	top.offset_bottom = 64.0
	root.add_child(top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	top.add_child(row)
	status_label = Label.new()
	status_label.custom_minimum_size = Vector2(270, 0)
	status_label.text = "Solo"
	row.add_child(status_label)
	ip_line = LineEdit.new()
	ip_line.placeholder_text = "Host IP, e.g. 192.168.1.25"
	ip_line.custom_minimum_size = Vector2(250, 0)
	row.add_child(ip_line)
	var host_btn := Button.new()
	host_btn.text = "HOST"
	host_btn.pressed.connect(_host_game)
	row.add_child(host_btn)
	var join_btn := Button.new()
	join_btn.text = "JOIN"
	join_btn.pressed.connect(_join_game)
	row.add_child(join_btn)
	var solo_btn := Button.new()
	solo_btn.text = "SOLO"
	solo_btn.pressed.connect(_start_solo)
	row.add_child(solo_btn)
	score_label = Label.new()
	score_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(score_label)

	var dpad := Control.new()
	dpad.anchor_top = 1.0
	dpad.anchor_bottom = 1.0
	dpad.offset_left = 20.0
	dpad.offset_top = -225.0
	dpad.offset_right = 255.0
	dpad.offset_bottom = -12.0
	root.add_child(dpad)
	_make_move_button(dpad, "▲", Vector2(78, 0), Vector2i(0, -1))
	_make_move_button(dpad, "▼", Vector2(78, 142), Vector2i(0, 1))
	_make_move_button(dpad, "◀", Vector2(0, 71), Vector2i(-1, 0))
	_make_move_button(dpad, "▶", Vector2(156, 71), Vector2i(1, 0))

	var hint := Label.new()
	hint.anchor_left = 0.5
	hint.anchor_top = 1.0
	hint.anchor_right = 0.5
	hint.anchor_bottom = 1.0
	hint.offset_left = -240.0
	hint.offset_top = -46.0
	hint.offset_right = 240.0
	hint.offset_bottom = -10.0
	hint.text = "Two phones: tap HOST on one, enter its LAN IP on the other, then JOIN"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(hint)

func _make_move_button(parent: Control, text: String, pos: Vector2, dir: Vector2i) -> void:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = Vector2(78, 68)
	b.focus_mode = Control.FOCUS_NONE
	b.button_down.connect(_request_move.bind(dir))
	parent.add_child(b)

func _start_solo() -> void:
	_close_network()
	net_mode = "solo"
	_clear_players()
	_spawn_local_player(1, START_ROW, 0.0, 0)
	status_label.text = "Solo practice"

func _host_game() -> void:
	_close_network()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		status_label.text = "Host failed: %s" % error_string(err)
		return
	multiplayer.multiplayer_peer = peer
	net_mode = "host"
	_clear_players()
	_spawn_local_player(1, START_ROW, 0.0, 0)
	status_label.text = "Hosting %s:%d" % [_best_lan_ip(), PORT]

func _join_game() -> void:
	var host := ip_line.text.strip_edges()
	if host.is_empty():
		status_label.text = "Enter the host phone's LAN IP first"
		return
	_close_network()
	_clear_players()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, PORT)
	if err != OK:
		status_label.text = "Join failed: %s" % error_string(err)
		return
	multiplayer.multiplayer_peer = peer
	net_mode = "client"
	status_label.text = "Connecting to %s:%d..." % [host, PORT]

func _close_network() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func _on_connected_to_server() -> void:
	status_label.text = "Connected - player %d" % multiplayer.get_unique_id()

func _on_connection_failed() -> void:
	status_label.text = "Connection failed"
	_start_solo()

func _on_server_disconnected() -> void:
	status_label.text = "Host disconnected"
	_start_solo()

func _on_peer_connected(peer_id: int) -> void:
	if net_mode != "host":
		return
	for existing_id in player_states.keys():
		var s: Dictionary = player_states[existing_id]
		spawn_player.rpc_id(peer_id, int(existing_id), int(s.row), float(s.x), int(s.score))
	spawn_player.rpc(peer_id, START_ROW, _spawn_x(peer_id), 0)

func _on_peer_disconnected(peer_id: int) -> void:
	if net_mode == "host":
		despawn_player.rpc(peer_id)

func _request_move(dir: Vector2i) -> void:
	if net_mode == "client":
		request_hop.rpc_id(1, dir)
	else:
		var peer_id := 1 if net_mode == "solo" else multiplayer.get_unique_id()
		_server_try_hop(peer_id, dir)

@rpc("any_peer", "reliable")
func request_hop(dir: Vector2i) -> void:
	if net_mode != "host":
		return
	var sender := multiplayer.get_remote_sender_id()
	_server_try_hop(sender, dir)

func _server_try_hop(peer_id: int, dir: Vector2i) -> void:
	if not player_states.has(peer_id):
		return
	var now_ms := Time.get_ticks_msec()
	if last_hop_ms.has(peer_id) and now_ms - int(last_hop_ms[peer_id]) < 105:
		return
	last_hop_ms[peer_id] = now_ms
	var s: Dictionary = player_states[peer_id]
	if dir.x != 0:
		s.x = clamp(float(s.x) + float(dir.x) * X_STEP, -6.6, 6.6)
	if dir.y != 0:
		s.row = clamp(int(s.row) + dir.y, GOAL_ROW, START_ROW)
	player_states[peer_id] = s
	if int(s.row) == GOAL_ROW:
		s.score = int(s.score) + 1
		s.row = START_ROW
		s.x = _spawn_x(peer_id)
		player_states[peer_id] = s
	_sync_one(peer_id)

func _server_hazards(delta: float) -> void:
	var now := Time.get_unix_time_from_system()
	for peer_id in player_states.keys():
		var id := int(peer_id)
		var s: Dictionary = player_states[id]
		var row := int(s.row)
		var x := float(s.x)
		if row >= 5 and row <= 9:
			for o in road_objects:
				if int(o.row) == row:
					var ox := _moving_x(float(o.speed), float(o.phase), now)
					if absf(x - ox) < 1.18:
						_reset_player(id)
						break
		elif row >= 1 and row <= 3:
			var on_log := false
			var carry_speed := 0.0
			for o in river_objects:
				if int(o.row) == row:
					var ox := _moving_x(float(o.speed), float(o.phase), now)
					if absf(x - ox) < 1.72:
						on_log = true
						carry_speed = float(o.speed)
						break
			if on_log:
				s.x = x + carry_speed * delta
				player_states[id] = s
				if absf(float(s.x)) > 7.2:
					_reset_player(id)
			elif net_mode == "solo" or net_mode == "host":
				_reset_player(id)

func _reset_player(peer_id: int) -> void:
	if not player_states.has(peer_id):
		return
	var s: Dictionary = player_states[peer_id]
	s.row = START_ROW
	s.x = _spawn_x(peer_id)
	player_states[peer_id] = s
	_sync_one(peer_id)

func _sync_one(peer_id: int) -> void:
	var s: Dictionary = player_states[peer_id]
	if net_mode == "host":
		sync_player.rpc(peer_id, int(s.row), float(s.x), int(s.score))
	else:
		_apply_player_state(peer_id, int(s.row), float(s.x), int(s.score))

@rpc("authority", "call_local", "reliable")
func spawn_player(peer_id: int, row: int, x: float, score: int) -> void:
	_spawn_local_player(peer_id, row, x, score)

@rpc("authority", "call_local", "reliable")
func despawn_player(peer_id: int) -> void:
	if players.has(peer_id):
		players[peer_id].queue_free()
		players.erase(peer_id)
	player_states.erase(peer_id)
	last_hop_ms.erase(peer_id)

@rpc("authority", "call_local", "unreliable_ordered")
func sync_player(peer_id: int, row: int, x: float, score: int) -> void:
	_apply_player_state(peer_id, row, x, score)

func _spawn_local_player(peer_id: int, row: int, x: float, score: int) -> void:
	if players.has(peer_id):
		_apply_player_state(peer_id, row, x, score)
		return
	var frog := Node3D.new()
	frog.name = "Hopper_%d" % peer_id
	var main_color := Color("#52d273") if peer_id == _local_visual_id() else Color("#f0d95d")
	var body := _mesh_box(Vector3(0.86, 0.34, 0.88), main_color)
	body.position.y = 0.2
	frog.add_child(body)
	var head := _mesh_box(Vector3(0.76, 0.32, 0.52), main_color.lightened(0.08))
	head.position = Vector3(0.0, 0.34, -0.24)
	frog.add_child(head)
	for side in [-1.0, 1.0]:
		var eye := _mesh_box(Vector3(0.16, 0.18, 0.16), Color.WHITE)
		eye.position = Vector3(0.23 * side, 0.56, -0.43)
		frog.add_child(eye)
		var pupil := _mesh_box(Vector3(0.075, 0.09, 0.05), Color("#111111"))
		pupil.position = Vector3(0.23 * side, 0.57, -0.53)
		frog.add_child(pupil)
	add_child(frog)
	players[peer_id] = frog
	player_states[peer_id] = {"row": row, "x": x, "score": score}
	_apply_player_state(peer_id, row, x, score)

func _apply_player_state(peer_id: int, row: int, x: float, score: int) -> void:
	if not players.has(peer_id):
		_spawn_local_player(peer_id, row, x, score)
		return
	player_states[peer_id] = {"row": row, "x": x, "score": score}
	var frog: Node3D = players[peer_id]
	frog.position = Vector3(x, 0.18, _row_z(row))

func _clear_players() -> void:
	for n in players.values():
		if is_instance_valid(n):
			n.queue_free()
	players.clear()
	player_states.clear()
	last_hop_ms.clear()

func _local_visual_id() -> int:
	if net_mode == "client" or net_mode == "host":
		return multiplayer.get_unique_id()
	return 1

func _spawn_x(peer_id: int) -> float:
	var slot := (peer_id - 1) % 4
	return [-2.4, -0.8, 0.8, 2.4][slot]

func _row_z(row: int) -> float:
	return (float(row) - 5.0) * Z_STEP

func _best_lan_ip() -> String:
	for address in IP.get_local_addresses():
		if address.begins_with("192.168.") or address.begins_with("10."):
			return address
		if address.begins_with("172."):
			return address
	return "this-phone-IP"

func _refresh_score_label() -> void:
	var parts: Array[String] = []
	for peer_id in player_states.keys():
		var s: Dictionary = player_states[peer_id]
		parts.append("P%d:%d" % [int(peer_id), int(s.score)])
	score_label.text = "  ".join(parts)

func _add_box(size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var n := _mesh_box(size, color)
	n.position = pos
	add_child(n)
	return n

func _mesh_box(size: Vector3, color: Color) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	n.mesh = mesh
	n.material_override = _mat(color)
	return n

func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 1.0
	return m
