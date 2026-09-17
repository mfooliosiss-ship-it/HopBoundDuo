extends Node3D

const AudioBank = preload("res://scripts/audio_bank.gd")

const PORT := 24567
const MAX_PLAYERS := 4
const START_ROW := 10
const GOAL_ROW := 0
const X_STEP := 1.6
const Z_STEP := 1.45
const TRACK_HALF := 8.6
const HOP_TIME := 0.18
const HOP_HEIGHT := 0.76
const STAGE_COUNT := 4
const SCORE_TO_ADVANCE := 3

var net_mode := "menu"
var game_active := false
var stage_index := 0
var world_time := 0.0
var sync_accum := 0.0
var swipe_start := Vector2.ZERO
var swipe_tracking := false
var last_host_ip := ""

var settings := {
	"sound": true,
	"music": true,
	"haptics": true,
	"swipe": true,
	"high_refresh": false,
	"shadows": true
}

var players: Dictionary = {}
var player_states: Dictionary = {}
var hop_visuals: Dictionary = {}
var hit_visuals: Dictionary = {}
var goal_visuals: Dictionary = {}
var death_timers: Dictionary = {}
var goal_timers: Dictionary = {}
var last_hop_ms: Dictionary = {}
var road_objects: Array[Dictionary] = []
var river_objects: Array[Dictionary] = []
var weather_objects: Array[Dictionary] = []
var burst_particles: Array[Dictionary] = []

var world_root: Node3D
var effect_root: Node3D
var env_node: WorldEnvironment
var env: Environment
var sun: DirectionalLight3D
var camera: Camera3D
var audio_bank

var ui_root: Control
var safe_root: Control
var menu_panel: PanelContainer
var settings_panel: PanelContainer
var game_ui: Control
var pause_panel: PanelContainer
var dpad_panel: PanelContainer
var flash_rect: ColorRect
var status_label: Label
var score_label: Label
var stage_hud_label: Label
var player_count_label: Label
var menu_stage_label: Label
var ip_line: LineEdit
var toast_label: Label
var next_stage_btn: Button
var toast_time := 0.0
var goal_flash := 0.0
var hit_flash := 0.0

func _ready() -> void:
	_load_settings()
	Engine.max_fps = 120 if bool(settings["high_refresh"]) else 60
	_build_scene_shell()
	_build_stage()
	_build_ui()
	audio_bank = AudioBank.new()
	add_child(audio_bank)
	audio_bank.set_enabled(bool(settings["sound"]), bool(settings["music"]))
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	get_viewport().size_changed.connect(_apply_safe_area)
	call_deferred("_apply_safe_area")
	_show_main_menu()

func _process(delta: float) -> void:
	world_time += delta
	_update_weather(delta)
	_update_bursts(delta)
	_update_feedback(delta)
	if not game_active:
		return
	_update_movers()
	_update_player_visuals(delta)
	_update_camera(delta)
	if net_mode == "solo" or net_mode == "host":
		_update_authority_timers(delta)
		_server_hazards(delta)
		sync_accum += delta
		if net_mode == "host" and sync_accum >= 0.05:
			sync_accum = 0.0
			for peer_id in player_states.keys():
				var s: Dictionary = player_states[peer_id]
				sync_player.rpc(int(peer_id), int(s["row"]), float(s["x"]), int(s["score"]))
	_refresh_hud()

func _unhandled_input(event: InputEvent) -> void:
	if not game_active or pause_panel.visible:
		return
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
			KEY_ESCAPE:
				_toggle_pause()
	elif event is InputEventJoypadButton and event.pressed:
		match event.button_index:
			JOY_BUTTON_DPAD_UP:
				_request_move(Vector2i(0, -1))
			JOY_BUTTON_DPAD_DOWN:
				_request_move(Vector2i(0, 1))
			JOY_BUTTON_DPAD_LEFT:
				_request_move(Vector2i(-1, 0))
			JOY_BUTTON_DPAD_RIGHT:
				_request_move(Vector2i(1, 0))
			JOY_BUTTON_START:
				_toggle_pause()
	elif event is InputEventScreenTouch and bool(settings["swipe"]):
		if event.pressed:
			swipe_start = event.position
			swipe_tracking = true
		elif swipe_tracking:
			swipe_tracking = false
			var delta_pos: Vector2 = event.position - swipe_start
			if delta_pos.length() >= 52.0:
				if absf(delta_pos.x) > absf(delta_pos.y):
					_request_move(Vector2i(1 if delta_pos.x > 0.0 else -1, 0))
				else:
					_request_move(Vector2i(0, 1 if delta_pos.y > 0.0 else -1))

func _build_scene_shell() -> void:
	world_root = Node3D.new()
	world_root.name = "StageWorld"
	add_child(world_root)
	effect_root = Node3D.new()
	effect_root.name = "Effects"
	add_child(effect_root)
	env_node = WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env_node.environment = env
	add_child(env_node)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	add_child(sun)
	camera = Camera3D.new()
	camera.position = Vector3(0.0, 16.6, 15.6)
	camera.fov = 42.0
	add_child(camera)
	camera.look_at(Vector3(0.0, -0.15, -0.3), Vector3.UP)

func _stage_data() -> Dictionary:
	match stage_index:
		1:
			return {
				"name": "Sunset Freeway", "theme": "sunset", "sky": "#e99267", "ambient": "#ffd4ad",
				"ground": "#6f7340", "grass": "#888347", "road": "#3e3739", "water": "#3a6c8d", "bank": "#92764d",
				"road_speeds": [3.4, -3.9, 4.5, -3.1, 4.9], "river_speeds": [1.55, -1.4, 1.8],
				"rain": false, "night": false
			}
		2:
			return {
				"name": "Rainy Marsh", "theme": "marsh", "sky": "#526c78", "ambient": "#b8d1cd",
				"ground": "#375b42", "grass": "#4f714d", "road": "#30373b", "water": "#315c67", "bank": "#695f46",
				"road_speeds": [3.0, -3.5, 4.0, -2.9, 4.4], "river_speeds": [1.8, -1.55, 2.0],
				"rain": true, "night": false
			}
		3:
			return {
				"name": "Neon Industrial", "theme": "industrial", "sky": "#161c31", "ambient": "#8794bd",
				"ground": "#303a35", "grass": "#435747", "road": "#24252e", "water": "#1d4661", "bank": "#575b5e",
				"road_speeds": [3.8, -4.25, 5.0, -3.6, 5.35], "river_speeds": [1.7, -1.75, 2.15],
				"rain": false, "night": true
			}
		_:
			return {
				"name": "Meadow Run", "theme": "meadow", "sky": "#78c8df", "ambient": "#fff1c9",
				"ground": "#4d873f", "grass": "#6eaa4f", "road": "#343a40", "water": "#267ba9", "bank": "#aa9a68",
				"road_speeds": [2.75, -3.2, 3.65, -2.5, 4.0], "river_speeds": [1.35, -1.15, 1.6],
				"rain": false, "night": false
			}

func _build_stage() -> void:
	for child in world_root.get_children():
		world_root.remove_child(child)
		child.queue_free()
	road_objects.clear()
	river_objects.clear()
	weather_objects.clear()
	_clear_bursts()
	var stage := _stage_data()
	env.background_color = Color(String(stage["sky"]))
	env.ambient_light_color = Color(String(stage["ambient"]))
	env.ambient_light_energy = 0.72 if bool(stage["night"]) else 1.08
	sun.light_energy = 0.58 if bool(stage["night"]) else 1.12
	sun.light_color = Color("#9eb6ff") if bool(stage["night"]) else Color("#fff4d7")
	sun.shadow_enabled = bool(settings["shadows"])
	_add_world_box(Vector3(26.0, 0.24, 22.0), Vector3(0.0, -0.34, 0.0), Color(String(stage["ground"])))
	for row in range(START_ROW + 1):
		var color := Color(String(stage["grass"]))
		if row >= 5 and row <= 9:
			color = Color(String(stage["road"]))
		elif row >= 1 and row <= 3:
			color = Color(String(stage["water"]))
		elif row == 4:
			color = Color(String(stage["bank"]))
		elif row == 0:
			color = Color(String(stage["grass"])).darkened(0.1)
		_add_world_box(Vector3(17.8, 0.18, Z_STEP - 0.04), Vector3(0.0, -0.18, _row_z(row)), color)
	_build_road_detail(stage)
	_build_river_detail(stage)
	_build_goal_area(stage)
	_build_scenery(stage)
	_build_road_objects(stage)
	_build_river_objects(stage)
	if bool(stage["rain"]):
		_build_rain()
	_refresh_stage_labels()

func _build_road_detail(stage: Dictionary) -> void:
	var stripe := Color("#d8c65f") if not bool(stage["night"]) else Color("#7dc8ff")
	for row in range(5, 10):
		for x in range(-5, 6):
			if x % 2 == 0:
				_add_world_box(Vector3(0.86, 0.025, 0.075), Vector3(float(x) * X_STEP, -0.07, _row_z(row) - Z_STEP * 0.48), stripe)
	_add_world_box(Vector3(17.8, 0.11, 0.12), Vector3(0.0, 0.0, _row_z(5) + Z_STEP * 0.5), Color("#d5d7d8"))
	_add_world_box(Vector3(17.8, 0.11, 0.12), Vector3(0.0, 0.0, _row_z(9) - Z_STEP * 0.5), Color("#d5d7d8"))

func _build_river_detail(stage: Dictionary) -> void:
	var glint := Color("#83d7eb") if not bool(stage["night"]) else Color("#467fbc")
	for row in range(1, 4):
		for i in range(8):
			var x := -7.4 + float(i) * 2.1 + float(row % 2) * 0.65
			_add_world_box(Vector3(0.9, 0.018, 0.055), Vector3(x, -0.075, _row_z(row) + 0.2), glint)
	_add_world_box(Vector3(17.8, 0.23, 0.2), Vector3(0.0, -0.02, _row_z(1) + Z_STEP * 0.52), Color(String(stage["bank"])).darkened(0.14))
	_add_world_box(Vector3(17.8, 0.23, 0.2), Vector3(0.0, -0.02, _row_z(3) - Z_STEP * 0.52), Color(String(stage["bank"])).darkened(0.14))

func _build_goal_area(stage: Dictionary) -> void:
	var pad_color := Color("#d5df54") if not bool(stage["night"]) else Color("#76e4cd")
	for x in [-6.4, -3.2, 0.0, 3.2, 6.4]:
		var pad := _mesh_cylinder(0.72, 0.15, pad_color, 10)
		pad.position = Vector3(float(x), 0.02, _row_z(0))
		world_root.add_child(pad)
		var center := _mesh_cylinder(0.24, 0.06, pad_color.darkened(0.22), 10)
		center.position = Vector3(float(x), 0.12, _row_z(0))
		world_root.add_child(center)

func _build_scenery(stage: Dictionary) -> void:
	var theme := String(stage["theme"])
	match theme:
		"sunset":
			for i in range(8):
				_add_tree(-10.1, -7.0 + float(i) * 2.0, 0.72 + float(i % 3) * 0.08, Color("#626b3e"))
				_add_tree(10.1, -6.4 + float(i) * 2.0, 0.76 + float((i + 1) % 3) * 0.08, Color("#626b3e"))
			for i in range(6):
				var cone := _mesh_box(Vector3(0.22, 0.45, 0.22), Color("#ed7f35"))
				cone.position = Vector3(-8.1 + float(i) * 3.2, 0.18, _row_z(8) + 0.48)
				world_root.add_child(cone)
		"marsh":
			for i in range(20):
				var side := -1.0 if i % 2 == 0 else 1.0
				var reed := _mesh_box(Vector3(0.08, 0.72 + float(i % 3) * 0.16, 0.08), Color("#75945c"))
				reed.position = Vector3(side * (8.9 + float(i % 3) * 0.18), 0.3, -7.2 + float(i % 10) * 1.55)
				world_root.add_child(reed)
			for i in range(7):
				var lily := _mesh_cylinder(0.34, 0.035, Color("#5c8b5c"), 9)
				lily.position = Vector3(-6.5 + float(i) * 2.0, -0.02, _row_z(2) + (0.22 if i % 2 == 0 else -0.22))
				world_root.add_child(lily)
		"industrial":
			for i in range(7):
				var z := -7.0 + float(i) * 2.15
				var pole := _mesh_box(Vector3(0.14, 2.2, 0.14), Color("#606a76"))
				pole.position = Vector3(-9.7, 0.9, z)
				world_root.add_child(pole)
				var lamp := _mesh_box(Vector3(0.55, 0.14, 0.22), Color("#62e6ff"))
				lamp.position = Vector3(-9.45, 1.9, z)
				world_root.add_child(lamp)
			for i in range(8):
				var crate := _mesh_box(Vector3(0.75, 0.75, 0.75), Color("#6b5a49"))
				crate.position = Vector3(9.4 + float(i % 2) * 0.4, 0.28, -6.8 + float(i) * 1.7)
				world_root.add_child(crate)
		_:
			for i in range(7):
				var z := -7.0 + float(i) * 2.15
				_add_tree(-10.0 - float(i % 2) * 0.55, z, 0.84 + float(i % 3) * 0.08, Color("#3c7d43"))
				_add_tree(10.0 + float((i + 1) % 2) * 0.55, z + 0.55, 0.82 + float((i + 1) % 3) * 0.08, Color("#3c7d43"))
			for i in range(16):
				var side := -1.0 if i % 2 == 0 else 1.0
				var flower := _mesh_box(Vector3(0.12, 0.12, 0.12), Color("#f5d85a") if i % 3 else Color("#f07aa8"))
				flower.position = Vector3(side * (9.0 + float((i / 2) % 3) * 0.38), 0.05, -7.0 + float(i % 8) * 1.9)
				world_root.add_child(flower)

func _add_tree(x: float, z: float, scale_factor: float, crown_color: Color) -> void:
	var trunk := _mesh_cylinder(0.18 * scale_factor, 1.25 * scale_factor, Color("#76502f"), 7)
	trunk.position = Vector3(x, 0.5 * scale_factor, z)
	world_root.add_child(trunk)
	var crown := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.68 * scale_factor
	sphere.height = 1.25 * scale_factor
	sphere.radial_segments = 8
	sphere.rings = 4
	crown.mesh = sphere
	crown.material_override = _mat(crown_color, 1.0)
	crown.position = Vector3(x, 1.28 * scale_factor, z)
	world_root.add_child(crown)

func _build_road_objects(stage: Dictionary) -> void:
	var speeds: Array = stage["road_speeds"]
	var colors := [Color("#d94b4b"), Color("#f1b84b"), Color("#5d9fe8"), Color("#d26be0"), Color("#e6e6e6")]
	if bool(stage["night"]):
		colors = [Color("#eb4c6a"), Color("#f5b84b"), Color("#4ed7e8"), Color("#bd62ff"), Color("#cbd4de")]
	for lane_index in range(5):
		var row := 5 + lane_index
		for i in range(4):
			var truck := lane_index == 1 or (lane_index == 3 and i % 2 == 0)
			var vehicle := _make_vehicle(colors[lane_index], truck, bool(stage["night"]))
			world_root.add_child(vehicle)
			road_objects.append({"node": vehicle, "row": row, "speed": float(speeds[lane_index]), "phase": float(i) * 4.75 + float(lane_index) * 1.7, "half": 1.46 if truck else 1.02})

func _make_vehicle(color: Color, truck: bool, neon: bool) -> Node3D:
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
		var wheel_x: float = float(sx) * (1.6 if truck else 1.0)
		for sz in [-0.43, 0.43]:
			var wheel := _mesh_cylinder(0.15, 0.11, Color("#1d2022"), 8)
			wheel.rotation_degrees.x = 90.0
			wheel.position = Vector3(wheel_x, 0.2, sz)
			root.add_child(wheel)
	var bumper := _mesh_box(Vector3(0.12, 0.14, 0.84), Color("#d8d8d8"))
	bumper.position = Vector3(length * 0.5 + 0.04, 0.29, 0.0)
	root.add_child(bumper)
	if neon:
		var glow := _mesh_box(Vector3(length * 0.78, 0.04, 0.9), color.lightened(0.25))
		glow.position.y = 0.1
		root.add_child(glow)
	return root

func _build_river_objects(stage: Dictionary) -> void:
	var speeds: Array = stage["river_speeds"]
	for lane_index in range(3):
		var row := 1 + lane_index
		for i in range(4):
			var length := 3.15 + float((i + lane_index) % 2) * 0.55
			var raft := String(stage["theme"]) == "industrial" and i % 2 == 0
			var platform := _make_river_platform(length, raft)
			world_root.add_child(platform)
			river_objects.append({"node": platform, "row": row, "speed": float(speeds[lane_index]), "phase": float(i) * 5.1 + float(lane_index) * 2.1, "half": length * 0.5 + 0.08})

func _make_river_platform(length: float, raft: bool) -> Node3D:
	var root := Node3D.new()
	if raft:
		for z in [-0.28, 0.0, 0.28]:
			var plank := _mesh_box(Vector3(length, 0.18, 0.23), Color("#7d5c3a"))
			plank.position = Vector3(0.0, 0.19, z)
			root.add_child(plank)
	else:
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

func _build_rain() -> void:
	for i in range(38):
		var drop := _mesh_box(Vector3(0.025, 0.52, 0.025), Color(0.72, 0.88, 1.0, 0.72))
		drop.position = Vector3(-9.0 + float((i * 37) % 180) / 10.0, 3.0 + float((i * 23) % 60) / 10.0, -8.0 + float((i * 47) % 160) / 10.0)
		world_root.add_child(drop)
		weather_objects.append({"node": drop, "speed": 9.0 + float(i % 5), "seed": i})

func _update_weather(delta: float) -> void:
	for item in weather_objects:
		var n: Node3D = item["node"]
		if not is_instance_valid(n):
			continue
		n.position.y -= float(item["speed"]) * delta
		n.position.x -= 1.3 * delta
		if n.position.y < -0.1:
			n.position.y = 8.0 + float(int(item["seed"]) % 4)
			n.position.x = -9.0 + float((int(item["seed"]) * 37 + int(world_time * 10.0)) % 180) / 10.0

func _update_movers() -> void:
	var now := Time.get_unix_time_from_system()
	for o in road_objects:
		var n: Node3D = o["node"]
		n.position.x = _moving_x(float(o["speed"]), float(o["phase"]), now)
		n.position.z = _row_z(int(o["row"]))
		n.rotation_degrees.y = 0.0 if float(o["speed"]) > 0.0 else 180.0
	for o in river_objects:
		var n: Node3D = o["node"]
		n.position.x = _moving_x(float(o["speed"]), float(o["phase"]), now)
		n.position.z = _row_z(int(o["row"]))
		n.position.y = sin(world_time * 2.2 + float(o["phase"])) * 0.035

func _moving_x(speed: float, phase: float, now: float) -> float:
	return fposmod(now * speed + phase + TRACK_HALF, TRACK_HALF * 2.0) - TRACK_HALF

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	ui_root = Control.new()
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(ui_root)
	flash_rect = ColorRect.new()
	flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash_rect.color = Color(1.0, 1.0, 1.0, 0.0)
	ui_root.add_child(flash_rect)
	safe_root = Control.new()
	safe_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.add_child(safe_root)
	_build_main_menu()
	_build_settings_panel()
	_build_game_ui()
	_build_pause_panel()
	toast_label = Label.new()
	toast_label.anchor_left = 0.5
	toast_label.anchor_top = 0.18
	toast_label.anchor_right = 0.5
	toast_label.offset_left = -280.0
	toast_label.offset_right = 280.0
	toast_label.offset_bottom = 54.0
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.add_theme_font_size_override("font_size", 24)
	toast_label.add_theme_color_override("font_color", Color("#fff5c7"))
	toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_label.visible = false
	safe_root.add_child(toast_label)
	_refresh_stage_labels()

func _build_main_menu() -> void:
	menu_panel = PanelContainer.new()
	menu_panel.anchor_left = 0.5
	menu_panel.anchor_top = 0.5
	menu_panel.anchor_right = 0.5
	menu_panel.anchor_bottom = 0.5
	menu_panel.offset_left = -300.0
	menu_panel.offset_top = -268.0
	menu_panel.offset_right = 300.0
	menu_panel.offset_bottom = 268.0
	menu_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.025, 0.055, 0.07, 0.94), 22))
	safe_root.add_child(menu_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	menu_panel.add_child(v)
	var title := Label.new()
	title.text = "HOPBOUND DUO"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 46)
	title.add_theme_color_override("font_color", Color("#f4f1d0"))
	v.add_child(title)
	var sub := Label.new()
	sub.text = "Retro road-and-river survival • solo or up to 4 phones on LAN"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_color_override("font_color", Color(1, 1, 1, 0.78))
	v.add_child(sub)
	var stage_row := HBoxContainer.new()
	stage_row.alignment = BoxContainer.ALIGNMENT_CENTER
	stage_row.add_theme_constant_override("separation", 12)
	v.add_child(stage_row)
	var prev := _ui_button("◀")
	prev.pressed.connect(_cycle_stage.bind(-1))
	stage_row.add_child(prev)
	menu_stage_label = Label.new()
	menu_stage_label.custom_minimum_size = Vector2(260, 42)
	menu_stage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu_stage_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	menu_stage_label.add_theme_font_size_override("font_size", 22)
	stage_row.add_child(menu_stage_label)
	var next := _ui_button("▶")
	next.pressed.connect(_cycle_stage.bind(1))
	stage_row.add_child(next)
	var solo := _ui_button("PLAY SOLO")
	solo.custom_minimum_size = Vector2(0, 52)
	solo.pressed.connect(_start_solo)
	v.add_child(solo)
	var host := _ui_button("HOST MULTIPLAYER")
	host.custom_minimum_size = Vector2(0, 52)
	host.pressed.connect(_host_game)
	v.add_child(host)
	ip_line = LineEdit.new()
	ip_line.placeholder_text = "Host phone IP (example 192.168.1.25)"
	ip_line.text = last_host_ip
	ip_line.custom_minimum_size = Vector2(0, 48)
	ip_line.clear_button_enabled = true
	v.add_child(ip_line)
	var join := _ui_button("JOIN MULTIPLAYER")
	join.custom_minimum_size = Vector2(0, 52)
	join.pressed.connect(_join_game)
	v.add_child(join)
	var settings_btn := _ui_button("SETTINGS")
	settings_btn.pressed.connect(_show_settings)
	v.add_child(settings_btn)
	var hint := Label.new()
	hint.text = "Same-Wi-Fi multiplayer: host on one phone, enter its shown IP on the others."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.68))
	v.add_child(hint)

func _build_settings_panel() -> void:
	settings_panel = PanelContainer.new()
	settings_panel.anchor_left = 0.5
	settings_panel.anchor_top = 0.5
	settings_panel.anchor_right = 0.5
	settings_panel.anchor_bottom = 0.5
	settings_panel.offset_left = -270.0
	settings_panel.offset_top = -245.0
	settings_panel.offset_right = 270.0
	settings_panel.offset_bottom = 245.0
	settings_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.025, 0.055, 0.07, 0.96), 22))
	safe_root.add_child(settings_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	settings_panel.add_child(v)
	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	v.add_child(title)
	_add_setting_toggle(v, "Sound effects", "sound")
	_add_setting_toggle(v, "Music", "music")
	_add_setting_toggle(v, "Haptic feedback", "haptics")
	_add_setting_toggle(v, "Swipe controls", "swipe")
	_add_setting_toggle(v, "120 Hz / high refresh", "high_refresh")
	_add_setting_toggle(v, "Dynamic shadows", "shadows")
	var note := Label.new()
	note.text = "Keyboard: WASD/arrows • Controller: D-pad • Phone: D-pad or swipe"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_color_override("font_color", Color(1, 1, 1, 0.72))
	v.add_child(note)
	var back := _ui_button("BACK")
	back.pressed.connect(_hide_settings)
	v.add_child(back)

func _add_setting_toggle(parent: VBoxContainer, text: String, key: String) -> void:
	var toggle := CheckButton.new()
	toggle.text = text
	toggle.button_pressed = bool(settings[key])
	toggle.custom_minimum_size = Vector2(0, 44)
	toggle.toggled.connect(_setting_changed.bind(key))
	parent.add_child(toggle)

func _build_game_ui() -> void:
	game_ui = Control.new()
	game_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	safe_root.add_child(game_ui)
	var top := PanelContainer.new()
	top.anchor_right = 1.0
	top.offset_left = 10.0
	top.offset_top = 10.0
	top.offset_right = -10.0
	top.offset_bottom = 76.0
	top.add_theme_stylebox_override("panel", _panel_style(Color(0.025, 0.055, 0.07, 0.86), 13))
	game_ui.add_child(top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	top.add_child(row)
	stage_hud_label = Label.new()
	stage_hud_label.custom_minimum_size = Vector2(205, 0)
	stage_hud_label.add_theme_font_size_override("font_size", 19)
	row.add_child(stage_hud_label)
	status_label = Label.new()
	status_label.custom_minimum_size = Vector2(260, 0)
	row.add_child(status_label)
	player_count_label = Label.new()
	player_count_label.custom_minimum_size = Vector2(95, 0)
	row.add_child(player_count_label)
	score_label = Label.new()
	score_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	score_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	score_label.add_theme_font_size_override("font_size", 18)
	row.add_child(score_label)
	next_stage_btn = _ui_button("NEXT")
	next_stage_btn.pressed.connect(_cycle_stage_in_game.bind(1))
	row.add_child(next_stage_btn)
	var pause := _ui_button("Ⅱ")
	pause.custom_minimum_size = Vector2(54, 42)
	pause.pressed.connect(_toggle_pause)
	row.add_child(pause)
	dpad_panel = PanelContainer.new()
	dpad_panel.anchor_top = 1.0
	dpad_panel.anchor_bottom = 1.0
	dpad_panel.offset_left = 18.0
	dpad_panel.offset_top = -238.0
	dpad_panel.offset_right = 268.0
	dpad_panel.offset_bottom = -12.0
	dpad_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.03, 0.06, 0.08, 0.5), 18))
	game_ui.add_child(dpad_panel)
	var dpad := Control.new()
	dpad.custom_minimum_size = Vector2(250, 226)
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
	hint.offset_left = -315.0
	hint.offset_top = -44.0
	hint.offset_right = 315.0
	hint.offset_bottom = -8.0
	hint.text = "Reach the far pads • 3 crossings advances the solo stage • swipe or use the D-pad"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.84))
	game_ui.add_child(hint)

func _build_pause_panel() -> void:
	pause_panel = PanelContainer.new()
	pause_panel.anchor_left = 0.5
	pause_panel.anchor_top = 0.5
	pause_panel.anchor_right = 0.5
	pause_panel.anchor_bottom = 0.5
	pause_panel.offset_left = -185.0
	pause_panel.offset_top = -125.0
	pause_panel.offset_right = 185.0
	pause_panel.offset_bottom = 125.0
	pause_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.02, 0.04, 0.06, 0.96), 20))
	safe_root.add_child(pause_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	pause_panel.add_child(v)
	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	v.add_child(title)
	var resume := _ui_button("RESUME")
	resume.pressed.connect(_toggle_pause)
	v.add_child(resume)
	var menu := _ui_button("MAIN MENU")
	menu.pressed.connect(_return_to_menu)
	v.add_child(menu)

func _apply_safe_area() -> void:
	if safe_root == null:
		return
	var window_size := DisplayServer.window_get_size()
	if window_size.x <= 0 or window_size.y <= 0:
		return
	var safe := DisplayServer.get_display_safe_area()
	var vp := get_viewport().get_visible_rect().size
	var sx := vp.x / float(window_size.x)
	var sy := vp.y / float(window_size.y)
	safe_root.offset_left = maxf(0.0, float(safe.position.x) * sx)
	safe_root.offset_top = maxf(0.0, float(safe.position.y) * sy)
	safe_root.offset_right = -maxf(0.0, float(window_size.x - safe.end.x) * sx)
	safe_root.offset_bottom = -maxf(0.0, float(window_size.y - safe.end.y) * sy)

func _panel_style(color: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	return style

func _ui_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(78, 44)
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

func _show_main_menu() -> void:
	game_active = false
	net_mode = "menu"
	_close_network()
	_clear_players()
	menu_panel.visible = true
	settings_panel.visible = false
	game_ui.visible = false
	pause_panel.visible = false
	_refresh_stage_labels()

func _show_settings() -> void:
	_sfx("ui")
	menu_panel.visible = false
	settings_panel.visible = true

func _hide_settings() -> void:
	_sfx("ui")
	settings_panel.visible = false
	menu_panel.visible = true

func _toggle_pause() -> void:
	if not game_active:
		return
	_sfx("ui")
	pause_panel.visible = not pause_panel.visible
	dpad_panel.visible = not pause_panel.visible

func _return_to_menu() -> void:
	_sfx("ui")
	_show_main_menu()

func _start_game_ui() -> void:
	game_active = true
	menu_panel.visible = false
	settings_panel.visible = false
	game_ui.visible = true
	pause_panel.visible = false
	dpad_panel.visible = true
	_refresh_hud()

func _start_solo() -> void:
	_sfx("ui")
	_close_network()
	net_mode = "solo"
	_clear_players()
	_spawn_local_player(1, START_ROW, 0.0, 0)
	_start_game_ui()
	status_label.text = "Solo"
	_toast("%s • Cross %d times to advance" % [String(_stage_data()["name"]), SCORE_TO_ADVANCE], 2.4)

func _host_game() -> void:
	_sfx("ui")
	_close_network()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		menu_panel.visible = true
		_toast("Host failed: %s" % error_string(err), 2.5)
		return
	multiplayer.multiplayer_peer = peer
	net_mode = "host"
	_clear_players()
	_spawn_local_player(1, START_ROW, 0.0, 0)
	_start_game_ui()
	status_label.text = "HOST • %s:%d" % [_best_lan_ip(), PORT]
	_toast("Host ready • Other phones can join now", 2.4)

func _join_game() -> void:
	_sfx("ui")
	var host := ip_line.text.strip_edges()
	if host.is_empty():
		_toast("Enter the host phone's LAN IP first", 2.5)
		return
	last_host_ip = host
	_save_settings()
	_close_network()
	_clear_players()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, PORT)
	if err != OK:
		_toast("Join failed: %s" % error_string(err), 2.5)
		return
	multiplayer.multiplayer_peer = peer
	net_mode = "client"
	_start_game_ui()
	status_label.text = "Connecting to %s:%d..." % [host, PORT]

func _close_network() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func _on_connected_to_server() -> void:
	status_label.text = "Connected • Player %d" % multiplayer.get_unique_id()
	_toast("Connected to host", 1.8)

func _on_connection_failed() -> void:
	_toast("Connection failed", 2.4)
	_show_main_menu()
	ip_line.text = last_host_ip

func _on_server_disconnected() -> void:
	_toast("Host disconnected", 2.4)
	_show_main_menu()
	ip_line.text = last_host_ip

func _on_peer_connected(peer_id: int) -> void:
	if net_mode != "host":
		return
	set_stage_remote.rpc_id(peer_id, stage_index)
	for existing_id in player_states.keys():
		var s: Dictionary = player_states[existing_id]
		spawn_player.rpc_id(peer_id, int(existing_id), int(s["row"]), float(s["x"]), int(s["score"]))
	spawn_player.rpc(peer_id, START_ROW, _spawn_x(peer_id), 0)
	_toast("Player %d joined" % peer_id, 1.8)

func _on_peer_disconnected(peer_id: int) -> void:
	if net_mode == "host":
		despawn_player.rpc(peer_id)
		_toast("Player %d left" % peer_id, 1.6)

func _cycle_stage(delta: int) -> void:
	_sfx("ui")
	stage_index = posmod(stage_index + delta, STAGE_COUNT)
	_build_stage()
	_refresh_stage_labels()

func _cycle_stage_in_game(delta: int) -> void:
	if net_mode == "client":
		return
	stage_index = posmod(stage_index + delta, STAGE_COUNT)
	_build_stage()
	if net_mode == "host":
		set_stage_remote.rpc(stage_index)
	_sfx("stage")
	_toast("Stage: %s" % String(_stage_data()["name"]), 2.0)

@rpc("authority", "call_local", "reliable")
func set_stage_remote(index: int) -> void:
	stage_index = clampi(index, 0, STAGE_COUNT - 1)
	_build_stage()
	_sfx("stage")
	_toast("Stage: %s" % String(_stage_data()["name"]), 2.0)

func _request_move(dir: Vector2i) -> void:
	if not game_active or pause_panel.visible or dir == Vector2i.ZERO:
		return
	var local_id := _local_visual_id()
	if local_id in hop_visuals or local_id in hit_visuals or local_id in goal_visuals:
		return
	_vibrate(10)
	_sfx("hop")
	if net_mode == "client":
		request_hop.rpc_id(1, dir)
	else:
		var peer_id := 1 if net_mode == "solo" else multiplayer.get_unique_id()
		_server_try_hop(peer_id, dir)

@rpc("any_peer", "reliable")
func request_hop(dir: Vector2i) -> void:
	if net_mode != "host":
		return
	_server_try_hop(multiplayer.get_remote_sender_id(), dir)

func _server_try_hop(peer_id: int, dir: Vector2i) -> void:
	if not player_states.has(peer_id) or death_timers.has(peer_id) or goal_timers.has(peer_id):
		return
	var now_ms := Time.get_ticks_msec()
	if last_hop_ms.has(peer_id) and now_ms - int(last_hop_ms[peer_id]) < 120:
		return
	last_hop_ms[peer_id] = now_ms
	var s: Dictionary = player_states[peer_id]
	var old_row := int(s["row"])
	var old_x := float(s["x"])
	if dir.x != 0:
		s["x"] = clamp(float(s["x"]) + float(dir.x) * X_STEP, -6.6, 6.6)
	if dir.y != 0:
		s["row"] = clamp(int(s["row"]) + dir.y, GOAL_ROW, START_ROW)
	player_states[peer_id] = s
	_trigger_hop_visual(peer_id, old_row, old_x, int(s["row"]), float(s["x"]))
	if int(s["row"]) == GOAL_ROW:
		s["score"] = int(s["score"]) + 1
		player_states[peer_id] = s
		goal_timers[peer_id] = 0.48
		_player_goal_feedback(peer_id)
		if net_mode == "host":
			player_goal.rpc(peer_id)
	_sync_one(peer_id)

func _server_hazards(delta: float) -> void:
	var now := Time.get_unix_time_from_system()
	for peer_id in player_states.keys():
		var id := int(peer_id)
		if death_timers.has(id) or goal_timers.has(id):
			continue
		var s: Dictionary = player_states[id]
		var row := int(s["row"])
		var x := float(s["x"])
		if row >= 5 and row <= 9:
			for o in road_objects:
				if int(o["row"]) == row:
					var ox := _moving_x(float(o["speed"]), float(o["phase"]), now)
					if absf(x - ox) < float(o["half"]) + 0.36:
						_kill_player(id, "hit")
						break
		elif row >= 1 and row <= 3:
			var on_platform := false
			var carry_speed := 0.0
			for o in river_objects:
				if int(o["row"]) == row:
					var ox := _moving_x(float(o["speed"]), float(o["phase"]), now)
					if absf(x - ox) < float(o["half"]):
						on_platform = true
						carry_speed = float(o["speed"])
						break
			if on_platform:
				s["x"] = x + carry_speed * delta
				player_states[id] = s
				if absf(float(s["x"])) > 7.2:
					_kill_player(id, "splash")
			else:
				_kill_player(id, "splash")

func _kill_player(peer_id: int, cause: String) -> void:
	if death_timers.has(peer_id):
		return
	death_timers[peer_id] = 0.38
	hop_visuals.erase(peer_id)
	_player_hit_feedback(peer_id, cause)
	if net_mode == "host":
		player_hit.rpc(peer_id, cause)

func _update_authority_timers(delta: float) -> void:
	for peer_id in death_timers.keys():
		var t := float(death_timers[peer_id]) - delta
		if t <= 0.0:
			death_timers.erase(peer_id)
			_respawn_player(int(peer_id))
		else:
			death_timers[peer_id] = t
	for peer_id in goal_timers.keys():
		var t := float(goal_timers[peer_id]) - delta
		if t <= 0.0:
			goal_timers.erase(peer_id)
			var id := int(peer_id)
			var score := int(player_states[id]["score"]) if player_states.has(id) else 0
			_respawn_player(id)
			if net_mode == "solo" and score > 0 and score % SCORE_TO_ADVANCE == 0:
				_cycle_stage_in_game(1)
		else:
			goal_timers[peer_id] = t

func _respawn_player(peer_id: int) -> void:
	if not player_states.has(peer_id):
		return
	var s: Dictionary = player_states[peer_id]
	s["row"] = START_ROW
	s["x"] = _spawn_x(peer_id)
	player_states[peer_id] = s
	hop_visuals.erase(peer_id)
	_sync_one(peer_id)

@rpc("authority", "call_local", "reliable")
func player_hit(peer_id: int, cause: String) -> void:
	_player_hit_feedback(peer_id, cause)

@rpc("authority", "call_local", "reliable")
func player_goal(peer_id: int) -> void:
	_player_goal_feedback(peer_id)

func _player_hit_feedback(peer_id: int, cause: String) -> void:
	hit_visuals[peer_id] = 0.38
	if peer_id == _local_visual_id():
		hit_flash = 0.20
		_vibrate(95 if cause == "hit" else 60)
		_sfx("splash" if cause == "splash" else "hit", -3.0)
	var frog: Node3D = players.get(peer_id, null)
	if frog != null:
		_spawn_burst(frog.position + Vector3(0, 0.35, 0), Color("#76cce8") if cause == "splash" else Color("#f17c62"), 10)

func _player_goal_feedback(peer_id: int) -> void:
	goal_visuals[peer_id] = 0.48
	if peer_id == _local_visual_id():
		goal_flash = 0.28
		_vibrate(38)
		_sfx("goal", -2.0)
		_toast("Crossing complete!", 1.2)
	var frog: Node3D = players.get(peer_id, null)
	if frog != null:
		_spawn_burst(frog.position + Vector3(0, 0.35, 0), Color("#d7ef5c"), 12)

func _update_feedback(delta: float) -> void:
	if toast_time > 0.0:
		toast_time = maxf(0.0, toast_time - delta)
		toast_label.visible = true
		toast_label.modulate.a = minf(1.0, toast_time * 2.5)
	elif toast_label != null:
		toast_label.visible = false
	if flash_rect == null:
		return
	if goal_flash > 0.0:
		goal_flash = maxf(0.0, goal_flash - delta)
		flash_rect.color = Color(0.76, 1.0, 0.42, goal_flash * 0.72)
	elif hit_flash > 0.0:
		hit_flash = maxf(0.0, hit_flash - delta)
		flash_rect.color = Color(1.0, 0.28, 0.24, hit_flash * 1.5)
	else:
		flash_rect.color.a = 0.0

func _toast(text: String, duration: float = 1.8) -> void:
	if toast_label == null:
		return
	toast_label.text = text
	toast_time = duration
	toast_label.visible = true
	toast_label.modulate.a = 1.0

func _spawn_burst(pos: Vector3, color: Color, count: int) -> void:
	for i in range(count):
		var p := _mesh_box(Vector3(0.09, 0.09, 0.09), color.lightened(float(i % 3) * 0.08))
		p.position = pos
		effect_root.add_child(p)
		var angle := float(i) / float(maxi(1, count)) * TAU
		var vel := Vector3(cos(angle) * (1.4 + float(i % 4) * 0.22), 1.8 + float(i % 3) * 0.45, sin(angle) * (1.4 + float((i + 2) % 4) * 0.22))
		burst_particles.append({"node": p, "vel": vel, "life": 0.62})

func _update_bursts(delta: float) -> void:
	for i in range(burst_particles.size() - 1, -1, -1):
		var item: Dictionary = burst_particles[i]
		var n: Node3D = item["node"]
		var life := float(item["life"]) - delta
		var vel: Vector3 = item["vel"]
		vel.y -= 5.5 * delta
		if is_instance_valid(n):
			n.position += vel * delta
			n.rotation_degrees += Vector3(180.0, 130.0, 90.0) * delta
			n.scale = Vector3.ONE * maxf(0.1, life / 0.62)
		if life <= 0.0:
			if is_instance_valid(n):
				n.queue_free()
			burst_particles.remove_at(i)
		else:
			item["life"] = life
			item["vel"] = vel
			burst_particles[i] = item

func _clear_bursts() -> void:
	for item in burst_particles:
		var n: Node = item["node"]
		if is_instance_valid(n):
			n.queue_free()
	burst_particles.clear()

func _sync_one(peer_id: int) -> void:
	var s: Dictionary = player_states[peer_id]
	if net_mode == "host":
		sync_player.rpc(peer_id, int(s["row"]), float(s["x"]), int(s["score"]))
	else:
		_apply_player_state(peer_id, int(s["row"]), float(s["x"]), int(s["score"]))

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
	hit_visuals.erase(peer_id)
	goal_visuals.erase(peer_id)
	death_timers.erase(peer_id)
	goal_timers.erase(peer_id)

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
	var belly := _mesh_box(Vector3(0.47, 0.18, 0.54), main_color.lightened(0.18))
	belly.position = Vector3(0, 0.31, 0.03)
	visual.add_child(belly)
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
	stripe.position = Vector3(0.0, 0.46, -0.05)
	visual.add_child(stripe)
	add_child(frog)
	players[peer_id] = frog
	player_states[peer_id] = {"row": row, "x": x, "score": score}
	frog.position = Vector3(x, 0.18, _row_z(row))

func _player_color(peer_id: int) -> Color:
	var palette := [Color("#54d36f"), Color("#f0d85b"), Color("#64b5f6"), Color("#e978c6")]
	var slot := abs(peer_id - 1) % palette.size()
	return palette[slot].lightened(0.06) if peer_id == _local_visual_id() else palette[slot]

func _apply_player_state(peer_id: int, row: int, x: float, score: int) -> void:
	if not players.has(peer_id):
		_spawn_local_player(peer_id, row, x, score)
		return
	var old: Dictionary = player_states.get(peer_id, {"row": row, "x": x, "score": score})
	var old_row := int(old["row"])
	var old_x := float(old["x"])
	player_states[peer_id] = {"row": row, "x": x, "score": score}
	if not hit_visuals.has(peer_id) and not goal_visuals.has(peer_id):
		if old_row != row or absf(old_x - x) > X_STEP * 0.72:
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
		var visual: Node3D = frog.get_node_or_null("Visual")
		if hit_visuals.has(peer_id):
			var remaining := maxf(0.0, float(hit_visuals[peer_id]) - delta)
			hit_visuals[peer_id] = remaining
			frog.rotation_degrees.y += 760.0 * delta
			if visual != null:
				var k := remaining / 0.38
				visual.scale = Vector3(1.25 - k * 0.15, 0.42 + k * 0.32, 1.25 - k * 0.15)
			if remaining <= 0.0:
				hit_visuals.erase(peer_id)
				frog.rotation_degrees.y = 0.0
				if visual != null:
					visual.scale = Vector3.ONE
			continue
		if goal_visuals.has(peer_id):
			var remaining := maxf(0.0, float(goal_visuals[peer_id]) - delta)
			goal_visuals[peer_id] = remaining
			if visual != null:
				var t := 1.0 - remaining / 0.48
				visual.position.y = sin(t * PI * 2.0) * 0.18
				visual.rotation_degrees.y += 520.0 * delta
			if remaining <= 0.0:
				goal_visuals.erase(peer_id)
				if visual != null:
					visual.position.y = 0.0
					visual.rotation_degrees.y = 0.0
			continue
		if hop_visuals.has(peer_id):
			var hop: Dictionary = hop_visuals[peer_id]
			var t := minf(1.0, float(hop["t"]) + delta / HOP_TIME)
			hop["t"] = t
			hop_visuals[peer_id] = hop
			var smooth := t * t * (3.0 - 2.0 * t)
			var pos: Vector3 = (hop["from"] as Vector3).lerp(hop["to"] as Vector3, smooth)
			pos.y += sin(t * PI) * HOP_HEIGHT
			frog.position = pos
			if visual != null:
				var squash := sin(t * PI)
				visual.scale = Vector3(1.0 + squash * 0.10, 1.0 - squash * 0.12, 1.0 + squash * 0.07)
				visual.rotation_degrees.z = sin(t * PI * 2.0) * 2.5
			if t >= 1.0:
				hop_visuals.erase(peer_id)
				if peer_id == _local_visual_id():
					_sfx("land", -8.0)
				if visual != null:
					visual.scale = Vector3.ONE
					visual.rotation_degrees.z = 0.0
		else:
			var s: Dictionary = player_states[peer_id]
			var target := Vector3(float(s["x"]), 0.18, _row_z(int(s["row"])))
			frog.position = frog.position.lerp(target, minf(1.0, delta * 16.0))
			if visual != null:
				var breathe := sin(world_time * 3.0 + float(int(peer_id) % 5)) * 0.015
				visual.scale = visual.scale.lerp(Vector3(1.0, 1.0 + breathe, 1.0), minf(1.0, delta * 10.0))

func _update_camera(delta: float) -> void:
	var local_id := _local_visual_id()
	var x_offset := 0.0
	var z_offset := 0.0
	if players.has(local_id):
		var frog: Node3D = players[local_id]
		x_offset = frog.position.x * 0.055
		z_offset = frog.position.z * 0.035
	var desired := Vector3(x_offset, 16.6, 15.6 + z_offset)
	camera.position = camera.position.lerp(desired, minf(1.0, delta * 3.5))
	camera.look_at(Vector3(x_offset * 0.35, -0.15, -0.3 + z_offset * 0.35), Vector3.UP)

func _clear_players() -> void:
	for n in players.values():
		if is_instance_valid(n):
			n.queue_free()
	players.clear()
	player_states.clear()
	last_hop_ms.clear()
	hop_visuals.clear()
	hit_visuals.clear()
	goal_visuals.clear()
	death_timers.clear()
	goal_timers.clear()

func _local_visual_id() -> int:
	if net_mode == "client" or net_mode == "host":
		return multiplayer.get_unique_id()
	return 1

func _spawn_x(peer_id: int) -> float:
	var slot: int = (peer_id - 1) % 4
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

func _refresh_stage_labels() -> void:
	var name := String(_stage_data()["name"])
	if menu_stage_label != null:
		menu_stage_label.text = "%d / %d  •  %s" % [stage_index + 1, STAGE_COUNT, name]
	if stage_hud_label != null:
		stage_hud_label.text = "STAGE %d • %s" % [stage_index + 1, name]

func _refresh_hud() -> void:
	_refresh_stage_labels()
	if score_label == null:
		return
	var parts: Array[String] = []
	for peer_id in player_states.keys():
		var s: Dictionary = player_states[peer_id]
		parts.append("P%d %d" % [int(peer_id), int(s["score"])])
	score_label.text = "   ".join(parts)
	player_count_label.text = "%d/%d frogs" % [players.size(), MAX_PLAYERS]
	if next_stage_btn != null:
		next_stage_btn.disabled = net_mode == "client"

func _setting_changed(value: bool, key: String) -> void:
	settings[key] = value
	if key == "high_refresh":
		Engine.max_fps = 120 if value else 60
	elif key == "shadows":
		sun.shadow_enabled = value
	if audio_bank != null:
		audio_bank.set_enabled(bool(settings["sound"]), bool(settings["music"]))
	_save_settings()
	_sfx("ui")

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") != OK:
		return
	for key in settings.keys():
		settings[key] = cfg.get_value("settings", key, settings[key])
	last_host_ip = String(cfg.get_value("player", "last_host_ip", ""))

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	for key in settings.keys():
		cfg.set_value("settings", key, settings[key])
	cfg.set_value("player", "last_host_ip", last_host_ip)
	cfg.save("user://settings.cfg")

func _vibrate(ms: int) -> void:
	if bool(settings["haptics"]):
		Input.vibrate_handheld(ms)

func _sfx(name: String, volume_db: float = -5.0) -> void:
	if audio_bank != null:
		audio_bank.play(name, volume_db)

func _add_world_box(size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var n := _mesh_box(size, color)
	n.position = pos
	world_root.add_child(n)
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
