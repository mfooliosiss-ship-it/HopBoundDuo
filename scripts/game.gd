extends Node3D

const PORT := 24567
const MAX_PLAYERS := 4
const START_ROW := 10
const GOAL_ROW := 0
const X_STEP := 1.6
const Z_STEP := 1.45
const TRACK_HALF := 8.6
const HOP_TIME := 0.17
const HOP_HEIGHT := 0.72

var net_mode := "solo"
var players: Dictionary = {}
var player_states: Dictionary = {}
var hop_visuals: Dictionary = {}
var road_objects: Array[Dictionary] = []
var river_objects: Array[Dictionary] = []
var sync_accum := 0.0
var last_hop_ms: Dictionary = {}
var world_time := 0.0
var goal_flash := 0.0
var hit_flash := 0.0

var camera: Camera3D
var status_label: Label
var score_label: Label
var ip_line: LineEdit
var flash_rect: ColorRect

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
	world_time += delta
	_update_movers()
	_update_player_visuals(delta)
	_update_feedback(delta)
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
	env.background_color = Color("#78c8df")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#fff1c9")
	env.ambient_light_energy = 1.08
	env_node.environment = env
	add_child(env_node)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	add_child(sun)

	camera = Camera3D.new()
	camera.position = Vector3(0.0, 16.6, 15.6)
	camera.fov = 42.0
	add_child(camera)
	camera.look_at(Vector3(0.0, -0.15, -0.3), Vector3.UP)

	# Broad base prevents empty edges from showing on wider phones.
	_add_box(Vector3(26.0, 0.24, 22.0), Vector3(0.0, -0.34, 0.0), Color("#4d873f"))

	for row in range(START_ROW + 1):
		var color := Color("#6eaa4f")
		if row >= 5 and row <= 9:
			color = Color("#343a40")
		elif row >= 1 and row <= 3:
			color = Color("#267ba9")
		elif row == 4:
			color = Color("#aa9a68")
		elif row == 0:
			color = Color("#487f42")
		_add_box(Vector3(17.8, 0.18, Z_STEP - 0.04), Vector3(0.0, -0.18, _row_z(row)), color)

	_build_road_detail()
	_build_river_detail()
	_build_goal_area()
	_build_scenery()
	_build_road_objects()
	_build_river_objects()

func _build_road_detail() -> void:
	for row in range(5, 10):
		for x in range(-5, 6):
			if x % 2 == 0:
				_add_box(Vector3(0.86, 0.025, 0.075), Vector3(float(x) * X_STEP, -0.07, _row_z(row) - Z_STEP * 0.48), Color("#e1ca68"))
	# Reflective curb strips at the two road edges.
	_add_box(Vector3(17.8, 0.11, 0.12), Vector3(0.0, 0.0, _row_z(5) + Z_STEP * 0.5), Color("#e7ded0"))
	_add_box(Vector3(17.8, 0.11, 0.12), Vector3(0.0, 0.0, _row_z(9) - Z_STEP * 0.5), Color("#e7ded0"))

func _build_river_detail() -> void:
	for row in range(1, 4):
		for i in range(8):
			var x := -7.4 + float(i) * 2.1 + float(row % 2) * 0.65
			_add_box(Vector3(0.9, 0.018, 0.055), Vector3(x, -0.075, _row_z(row) + 0.2), Color(0.52, 0.84, 0.95, 0.62))
	# River banks.
	_add_box(Vector3(17.8, 0.23, 0.2), Vector3(0.0, -0.02, _row_z(1) + Z_STEP * 0.52), Color("#806942"))
	_add_box(Vector3(17.8, 0.23, 0.2), Vector3(0.0, -0.02, _row_z(3) - Z_STEP * 0.52), Color("#806942"))

func _build_goal_area() -> void:
	for x in [-6.4, -3.2, 0.0, 3.2, 6.4]:
		var pad := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.72
		mesh.bottom_radius = 0.72
		mesh.height = 0.15
		mesh.radial_segments = 10
		pad.mesh = mesh
		pad.position = Vector3(float(x), 0.02, _row_z(0))
		pad.material_override = _mat(Color("#d5df54"), 0.92)
		add_child(pad)
		var center := _mesh_cylinder(0.24, 0.06, Color("#90b34e"), 10)
		center.position = Vector3(float(x), 0.12, _row_z(0))
		add_child(center)

func _build_scenery() -> void:
	for i in range(7):
		var z := -7.0 + float(i) * 2.15
		_add_tree(-10.0 - float(i % 2) * 0.55, z, 0.84 + float(i % 3) * 0.08)
		_add_tree(10.0 + float((i + 1) % 2) * 0.55, z + 0.55, 0.82 + float((i + 1) % 3) * 0.08)
	for i in range(16):
		var side := -1.0 if i % 2 == 0 else 1.0
		var x := side * (9.0 + float((i / 2) % 3) * 0.38)
		var z := -7.0 + float(i % 8) * 1.9
		var flower := _mesh_box(Vector3(0.12, 0.12, 0.12), Color("#f5d85a") if i % 3 else Color("#f07aa8"))
		flower.position = Vector3(x, 0.05, z)
		flower.rotation_degrees.y = float(i * 37)
		add_child(flower)

func _add_tree(x: float, z: float, scale_factor: float) -> void:
	var trunk := _mesh_cylinder(0.18 * scale_factor, 1.25 * scale_factor, Color("#76502f"), 7)
	trunk.position = Vector3(x, 0.5 * scale_factor, z)
	add_child(trunk)
	var crown := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.68 * scale_factor
	sphere.height = 1.25 * scale_factor
	sphere.radial_segments = 8
	sphere.rings = 4
	crown.mesh = sphere
	crown.material_override = _mat(Color("#3c7d43"), 1.0)
	crown.position = Vector3(x, 1.28 * scale_factor, z)
	add_child(crown)

func _build_road_objects() -> void:
	var speeds := [2.75, -3.2, 3.65, -2.5, 4.0]
	var colors := [Color("#d94b4b"), Color("#f1b84b"), Color("#5d9fe8"), Color("#d26be0"), Color("#e6e6e6")]
	for lane_index in range(5):
		var row := 5 + lane_index
		for i in range(4):
			var truck := lane_index == 1 or (lane_index == 3 and i % 2 == 0)
			var vehicle := _make_vehicle(colors[lane_index], truck)
			vehicle.position.y = 0.0
			add_child(vehicle)
			road_objects.append({
				"node": vehicle,
				"row": row,
				"speed": speeds[lane_index],
				"phase": float(i) * 4.75 + float(lane_index) * 1.7,
				"half": 1.46 if truck else 1.02
			})

func _make_vehicle(color: Color, truck: bool) -> Node3D:
	var root := Node3D.new()
	var length := 2.5 if truck else 1.72
	var body := _mesh_box(Vector3(length, 0.43, 0.82), color)
	body.position.y = 0.42
	root.add_child(body)
	if truck:
		var cab := _mesh_box(Vector3(0.75, 0.55, 0.76), color.lightened(0.08))
		cab.position = Vector3(-0.76, 0.68, 0.0)
		root.add_child(cab)
		var window := _mesh_box(Vector3(0.31, 0.24, 0.78), Color("#b9e1eb"))
		window.position = Vector3(-1.05, 0.73, 0.0)
		root.add_child(window)
	else:
		var roof := _mesh_box(Vector3(0.94, 0.36, 0.72), color.lightened(0.08))
		roof.position = Vector3(-0.05, 0.68, 0.0)
		root.add_child(roof)
		var windshield := _mesh_box(Vector3(0.34, 0.22, 0.74), Color("#b9e1eb"))
		windshield.position = Vector3(-0.42, 0.72, 0.0)
		root.add_child(windshield)
	for sx in [-0.55, 0.55]:
		var wheel_x := sx * (1.6 if truck else 1.0)
		for sz in [-0.43, 0.43]:
			var wheel := _mesh_cylinder(0.15, 0.11, Color("#1d2022"), 8)
			wheel.rotation_degrees.x = 90.0
			wheel.position = Vector3(wheel_x, 0.2, sz)
			root.add_child(wheel)
	var bumper := _mesh_box(Vector3(0.12, 0.14, 0.84), Color("#d8d8d8"))
	bumper.position = Vector3(length * 0.5 + 0.04, 0.29, 0.0)
	root.add_child(bumper)
	return root

func _build_river_objects() -> void:
	var speeds := [1.35, -1.15, 1.6]
	for lane_index in range(3):
		var row := 1 + lane_index
		for i in range(4):
			var length := 3.15 + float((i + lane_index) % 2) * 0.55
			var log := _make_log(length)
			add_child(log)
			river_objects.append({
				"node": log,
				"row": row,
				"speed": speeds[lane_index],
				"phase": float(i) * 5.1 + float(lane_index) * 2.1,
				"half": length * 0.5 + 0.08
			})

func _make_log(length: float) -> Node3D:
	var root := Node3D.new()
	var log_mesh := _mesh_cylinder(0.28, length, Color("#7d4f2d"), 8)
	log_mesh.rotation_degrees.z = 90.0
	log_mesh.position.y = 0.2
	root.add_child(log_mesh)
	for k in [-0.32, 0.24]:
		var knot := _mesh_cylinder(0.07, 0.08, Color("#55341f"), 7)
		knot.rotation_degrees.x = 90.0
		knot.position = Vector3(length * k, 0.43, 0.0)
		root.add_child(knot)
	return root

func _update_movers() -> void:
	var now := Time.get_unix_time_from_system()
	for o in road_objects:
		var n: Node3D = o.node
		n.position.x = _moving_x(float(o.speed), float(o.phase), now)
		n.position.z = _row_z(int(o.row))
		n.rotation_degrees.y = 0.0 if float(o.speed) > 0.0 else 180.0
	for o in river_objects:
		var n: Node3D = o.node
		n.position.x = _moving_x(float(o.speed), float(o.phase), now)
		n.position.z = _row_z(int(o.row))
		n.position.y = sin(world_time * 2.2 + float(o.phase)) * 0.035

func _moving_x(speed: float, phase: float, now: float) -> float:
	return fposmod(now * speed + phase + TRACK_HALF, TRACK_HALF * 2.0) - TRACK_HALF

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(root)

	flash_rect = ColorRect.new()
	flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash_rect.color = Color(1.0, 1.0, 1.0, 0.0)
	root.add_child(flash_rect)

	var top := PanelContainer.new()
	top.anchor_right = 1.0
	top.offset_left = 10.0
	top.offset_top = 10.0
	top.offset_right = -10.0
	top.offset_bottom = 72.0
	top.add_theme_stylebox_override("panel", _panel_style(Color(0.035, 0.07, 0.09, 0.82), 12))
	root.add_child(top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 9)
	top.add_child(row)

	var title := Label.new()
	title.text = "HOPBOUND DUO"
	title.add_theme_font_size_override("font_size", 22)
	title.custom_minimum_size = Vector2(175, 0)
	row.add_child(title)

	status_label = Label.new()
	status_label.custom_minimum_size = Vector2(245, 0)
	status_label.text = "Solo"
	row.add_child(status_label)

	ip_line = LineEdit.new()
	ip_line.placeholder_text = "Host IP"
	ip_line.custom_minimum_size = Vector2(205, 0)
	ip_line.clear_button_enabled = true
	row.add_child(ip_line)

	var host_btn := _ui_button("HOST")
	host_btn.pressed.connect(_host_game)
	row.add_child(host_btn)
	var join_btn := _ui_button("JOIN")
	join_btn.pressed.connect(_join_game)
	row.add_child(join_btn)
	var solo_btn := _ui_button("SOLO")
	solo_btn.pressed.connect(_start_solo)
	row.add_child(solo_btn)

	score_label = Label.new()
	score_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	score_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	score_label.add_theme_font_size_override("font_size", 18)
	row.add_child(score_label)

	var dpad_panel := PanelContainer.new()
	dpad_panel.anchor_top = 1.0
	dpad_panel.anchor_bottom = 1.0
	dpad_panel.offset_left = 18.0
	dpad_panel.offset_top = -238.0
	dpad_panel.offset_right = 268.0
	dpad_panel.offset_bottom = -12.0
	dpad_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.03, 0.06, 0.08, 0.52), 18))
	root.add_child(dpad_panel)
	var dpad := Control.new()
	dpad.custom_minimum_size = Vector2(250.0, 226.0)
	dpad_panel.add_child(dpad)
	_make_move_button(dpad, "▲", Vector2(86, 8), Vector2i(0, -1))
	_make_move_button(dpad, "▼", Vector2(86, 150), Vector2i(0, 1))
	_make_move_button(dpad, "◀", Vector2(8, 79), Vector2i(-1, 0))
	_make_move_button(dpad, "▶", Vector2(164, 79), Vector2i(1, 0))

	var hint := Label.new()
	hint.anchor_left = 0.5
	hint.anchor_top = 1.0
	hint.anchor_right = 0.5
	hint.anchor_bottom = 1.0
	hint.offset_left = -295.0
	hint.offset_top = -42.0
	hint.offset_right = 295.0
	hint.offset_bottom = -8.0
	hint.text = "Cross the traffic and river • Two phones use HOST / JOIN on the same Wi-Fi"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.86))
	root.add_child(hint)

func _panel_style(color: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	return style

func _ui_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(70.0, 42.0)
	return b

func _make_move_button(parent: Control, text: String, pos: Vector2, dir: Vector2i) -> void:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = Vector2(78, 68)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 29)
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
	status_label.text = "Connected • Player %d" % multiplayer.get_unique_id()

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
	if dir == Vector2i.ZERO:
		return
	if _local_visual_id() in hop_visuals:
		return
	Input.vibrate_handheld(10)
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
	if last_hop_ms.has(peer_id) and now_ms - int(last_hop_ms[peer_id]) < 120:
		return
	last_hop_ms[peer_id] = now_ms
	var s: Dictionary = player_states[peer_id]
	var old_row := int(s.row)
	var old_x := float(s.x)
	if dir.x != 0:
		s.x = clamp(float(s.x) + float(dir.x) * X_STEP, -6.6, 6.6)
	if dir.y != 0:
		s.row = clamp(int(s.row) + dir.y, GOAL_ROW, START_ROW)
	_trigger_hop_visual(peer_id, old_row, old_x, int(s.row), float(s.x))
	player_states[peer_id] = s
	if int(s.row) == GOAL_ROW:
		s.score = int(s.score) + 1
		player_states[peer_id] = s
		_player_goal_feedback(peer_id)
		if net_mode == "host":
			player_goal.rpc(peer_id)
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
					if absf(x - ox) < float(o.half) + 0.36:
						_reset_player(id)
						break
		elif row >= 1 and row <= 3:
			var on_log := false
			var carry_speed := 0.0
			for o in river_objects:
				if int(o.row) == row:
					var ox := _moving_x(float(o.speed), float(o.phase), now)
					if absf(x - ox) < float(o.half):
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
	if int(s.row) == START_ROW and absf(float(s.x) - _spawn_x(peer_id)) < 0.1:
		return
	_player_hit_feedback(peer_id)
	if net_mode == "host":
		player_hit.rpc(peer_id)
	s.row = START_ROW
	s.x = _spawn_x(peer_id)
	player_states[peer_id] = s
	hop_visuals.erase(peer_id)
	_sync_one(peer_id)

@rpc("authority", "call_local", "reliable")
func player_hit(peer_id: int) -> void:
	_player_hit_feedback(peer_id)

@rpc("authority", "call_local", "reliable")
func player_goal(peer_id: int) -> void:
	_player_goal_feedback(peer_id)

func _player_hit_feedback(peer_id: int) -> void:
	if peer_id == _local_visual_id():
		hit_flash = 0.18
		Input.vibrate_handheld(85)
	var frog: Node3D = players.get(peer_id, null)
	if frog != null:
		var visual := frog.get_node_or_null("Visual")
		if visual != null:
			visual.scale = Vector3(1.25, 0.48, 1.25)

func _player_goal_feedback(peer_id: int) -> void:
	if peer_id == _local_visual_id():
		goal_flash = 0.26
		Input.vibrate_handheld(35)

func _update_feedback(delta: float) -> void:
	if flash_rect == null:
		return
	if goal_flash > 0.0:
		goal_flash = maxf(0.0, goal_flash - delta)
		flash_rect.color = Color(0.76, 1.0, 0.42, goal_flash * 0.75)
	elif hit_flash > 0.0:
		hit_flash = maxf(0.0, hit_flash - delta)
		flash_rect.color = Color(1.0, 0.28, 0.24, hit_flash * 1.5)
	else:
		flash_rect.color.a = 0.0

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
	hop_visuals.erase(peer_id)

@rpc("authority", "call_local", "unreliable_ordered")
func sync_player(peer_id: int, row: int, x: float, score: int) -> void:
	_apply_player_state(peer_id, row, x, score)

func _spawn_local_player(peer_id: int, row: int, x: float, score: int) -> void:
	if players.has(peer_id):
		_apply_player_state(peer_id, row, x, score)
		return
	var frog := Node3D.new()
	frog.name = "Hopper_%d" % peer_id
	var visual := Node3D.new()
	visual.name = "Visual"
	frog.add_child(visual)
	var main_color := _player_color(peer_id)
	var body := _mesh_box(Vector3(0.82, 0.30, 0.86), main_color)
	body.position.y = 0.23
	visual.add_child(body)
	var head := _mesh_box(Vector3(0.72, 0.31, 0.52), main_color.lightened(0.08))
	head.position = Vector3(0.0, 0.40, -0.28)
	visual.add_child(head)
	for side in [-1.0, 1.0]:
		var thigh := _mesh_box(Vector3(0.28, 0.18, 0.50), main_color.darkened(0.05))
		thigh.position = Vector3(0.48 * side, 0.17, 0.18)
		thigh.rotation_degrees.y = 18.0 * side
		visual.add_child(thigh)
		var foot := _mesh_box(Vector3(0.36, 0.11, 0.22), main_color.lightened(0.12))
		foot.position = Vector3(0.54 * side, 0.10, 0.52)
		visual.add_child(foot)
		var eye := _mesh_box(Vector3(0.17, 0.18, 0.16), Color("#f5f7ed"))
		eye.position = Vector3(0.23 * side, 0.59, -0.43)
		visual.add_child(eye)
		var pupil := _mesh_box(Vector3(0.075, 0.09, 0.05), Color("#111418"))
		pupil.position = Vector3(0.23 * side, 0.60, -0.53)
		visual.add_child(pupil)
	var stripe := _mesh_box(Vector3(0.48, 0.05, 0.18), main_color.lightened(0.25))
	stripe.position = Vector3(0.0, 0.38, 0.10)
	visual.add_child(stripe)
	add_child(frog)
	players[peer_id] = frog
	player_states[peer_id] = {"row": row, "x": x, "score": score}
	frog.position = Vector3(x, 0.18, _row_z(row))

func _player_color(peer_id: int) -> Color:
	var palette := [Color("#54d36f"), Color("#f0d85b"), Color("#64b5f6"), Color("#e978c6")]
	var slot := abs(peer_id - 1) % palette.size()
	if peer_id == _local_visual_id():
		return palette[slot].lightened(0.06)
	return palette[slot]

func _apply_player_state(peer_id: int, row: int, x: float, score: int) -> void:
	if not players.has(peer_id):
		_spawn_local_player(peer_id, row, x, score)
		return
	var old: Dictionary = player_states.get(peer_id, {"row": row, "x": x, "score": score})
	var old_row := int(old.row)
	var old_x := float(old.x)
	var row_changed := old_row != row
	var side_hop := absf(old_x - x) > X_STEP * 0.72
	player_states[peer_id] = {"row": row, "x": x, "score": score}
	if row_changed or side_hop:
		_trigger_hop_visual(peer_id, old_row, old_x, row, x)

func _trigger_hop_visual(peer_id: int, old_row: int, old_x: float, new_row: int, new_x: float) -> void:
	if not players.has(peer_id):
		return
	var frog: Node3D = players[peer_id]
	var from := frog.position
	if absf(from.x - old_x) > 1.0 or absf(from.z - _row_z(old_row)) > 1.0:
		from = Vector3(old_x, 0.18, _row_z(old_row))
	var target := Vector3(new_x, 0.18, _row_z(new_row))
	hop_visuals[peer_id] = {"from": from, "to": target, "t": 0.0}
	var dx := new_x - old_x
	var dz := _row_z(new_row) - _row_z(old_row)
	if absf(dx) > absf(dz):
		frog.rotation_degrees.y = -90.0 if dx > 0.0 else 90.0
	elif absf(dz) > 0.01:
		frog.rotation_degrees.y = 0.0 if dz < 0.0 else 180.0

func _update_player_visuals(delta: float) -> void:
	for peer_id in players.keys():
		var frog: Node3D = players[peer_id]
		if not is_instance_valid(frog) or not player_states.has(peer_id):
			continue
		var visual := frog.get_node_or_null("Visual")
		if hop_visuals.has(peer_id):
			var hop: Dictionary = hop_visuals[peer_id]
			var t := minf(1.0, float(hop.t) + delta / HOP_TIME)
			hop.t = t
			hop_visuals[peer_id] = hop
			var smooth := t * t * (3.0 - 2.0 * t)
			var pos: Vector3 = (hop.from as Vector3).lerp(hop.to as Vector3, smooth)
			pos.y += sin(t * PI) * HOP_HEIGHT
			frog.position = pos
			if visual != null:
				var squash := sin(t * PI)
				visual.scale = Vector3(1.0 + squash * 0.10, 1.0 - squash * 0.12, 1.0 + squash * 0.07)
				visual.rotation_degrees.z = sin(t * PI * 2.0) * 2.5
			if t >= 1.0:
				hop_visuals.erase(peer_id)
				if visual != null:
					visual.scale = Vector3.ONE
					visual.rotation_degrees.z = 0.0
		else:
			var s: Dictionary = player_states[peer_id]
			var target := Vector3(float(s.x), 0.18, _row_z(int(s.row)))
			var follow := minf(1.0, delta * 16.0)
			frog.position = frog.position.lerp(target, follow)
			if visual != null:
				var breathe := sin(world_time * 3.0 + float(int(peer_id) % 5)) * 0.015
				visual.scale = visual.scale.lerp(Vector3(1.0, 1.0 + breathe, 1.0), minf(1.0, delta * 10.0))

func _clear_players() -> void:
	for n in players.values():
		if is_instance_valid(n):
			n.queue_free()
	players.clear()
	player_states.clear()
	last_hop_ms.clear()
	hop_visuals.clear()

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
	for address in IP.get_local_addresses():
		if address.begins_with("172."):
			return address
	return "this-phone-IP"

func _refresh_score_label() -> void:
	var parts: Array[String] = []
	for peer_id in player_states.keys():
		var s: Dictionary = player_states[peer_id]
		parts.append("P%d  %d" % [int(peer_id), int(s.score)])
	score_label.text = "   ".join(parts)

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
	n.material_override = _mat(color, 0.9)
	return n

func _mesh_cylinder(radius: float, height: float, color: Color, segments: int) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = segments
	n.mesh = mesh
	n.material_override = _mat(color, 0.92)
	return n

func _mat(color: Color, roughness: float = 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	return m
