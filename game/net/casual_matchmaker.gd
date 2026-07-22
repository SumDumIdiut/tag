extends Node
class_name CasualMatchmaker

# The "connect to a match, hosting one if needed" flow behind Online menu's
# Casual and Private bars -- extracted from the old standalone quick_play.tscn
# screen (now retired) so it can run as a lightweight inline overlay on
# online_menu.gd instead of its own intermediate screen. start(username,
# false) reproduces quick_play.gd's exact behavior unchanged: join the
# fullest not-full public server, or silently host a new public one if none
# qualify. start(username, true) skips the public-directory step entirely
# and always hosts a fresh, unlisted (--private) server instead -- see
# server_main.gd's --private handling for what "unlisted" actually means
# (it just never registers with the relay's public directory).

signal status_changed(text: String)
signal entered_lobby
signal failed(reason: String)

const DIRECTORY_URL := "https://codecade.co.za/tag/api/servers"
const RELAY_JOIN_BASE := "wss://codecade.co.za/tag/relay/join/"

var _http: HTTPRequest
var _spawner: LocalServerSpawner
var _username := ""
var _private := false
# See quick_play.gd's own _cancelled for the full explanation -- NetworkManager
# is an autoload, so a late async callback (HTTP response, connection signal)
# can still fire after cancel() tears this node down if it's already queued.
var _cancelled := false

func _ready() -> void:
	_spawner = LocalServerSpawner.new()
	add_child(_spawner)
	_spawner.connected.connect(_on_connected_to_own_host)
	_spawner.failed.connect(_on_spawn_failed)
	NetworkManager.connected_to_server.connect(_on_connected_to_existing_server)
	NetworkManager.connection_failed.connect(_on_join_existing_failed)

func start(username: String, private: bool = false) -> void:
	_username = username
	_private = private
	GameSettings.save_username(_username)

	if _private:
		_host_new_match()
		return

	status_changed.emit("Finding a match...")
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_directory_response)
	if _http.request(DIRECTORY_URL) != OK:
		_host_new_match()

func _on_directory_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _cancelled:
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_host_new_match()
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_ARRAY or parsed.is_empty():
		_host_new_match()
		return
	var best = null
	for s in parsed:
		if s.playerCount >= s.maxPlayers:
			continue
		if best == null or s.playerCount > best.playerCount:
			best = s
	if best == null:
		_host_new_match()
		return
	status_changed.emit("Joining %s..." % best.name)
	NetworkManager.set_username(_username)
	NetworkManager.start_client(RELAY_JOIN_BASE + str(best.id), _username)

func _on_join_existing_failed() -> void:
	if _cancelled:
		return
	status_changed.emit("That server just went offline -- hosting a new one instead...")
	_host_new_match()

func _on_connected_to_existing_server() -> void:
	if _cancelled:
		return
	status_changed.emit("Joining match...")
	NetworkManager.lobby_state_updated.connect(_on_in_lobby, CONNECT_ONE_SHOT)
	NetworkManager.quick_join_lobby()

func _host_new_match() -> void:
	if _cancelled:
		return
	if _private:
		status_changed.emit("Starting a private match...")
		_spawner.spawn("%s's Match" % _username, _username, PackedStringArray(["--private"]))
	else:
		status_changed.emit("No open servers -- starting one...")
		_spawner.spawn("%s's Match" % _username, _username)

func _on_spawn_failed(reason: String) -> void:
	if _cancelled:
		return
	status_changed.emit(reason)
	failed.emit(reason)

func _on_connected_to_own_host() -> void:
	if _cancelled:
		return
	if _private:
		NetworkManager.hosted_private_address = "%s:%d" % [LocalServerSpawner.get_lan_ip(), _spawner.get_port()]
		# See ranked_queue.gd's identical call for what this does and why
		# it's a no-op for anyone but the party leader -- private is a real
		# address (never listed in the directory), unlike ranked/casual's
		# server-name lookup.
		if PartyManager.is_leader():
			PartyManager.queue_party(NetworkManager.hosted_private_address, "private", "")
	status_changed.emit("Waiting for players...")
	NetworkManager.lobby_state_updated.connect(_on_in_lobby, CONNECT_ONE_SHOT)
	NetworkManager.quick_join_lobby()

func _on_in_lobby(_lobby: Dictionary) -> void:
	if _cancelled:
		return
	entered_lobby.emit()

func cancel() -> void:
	_cancelled = true
	if NetworkManager.lobby_state_updated.is_connected(_on_in_lobby):
		NetworkManager.lobby_state_updated.disconnect(_on_in_lobby)
	if _http:
		# An in-flight HTTPRequest runs its I/O on a background thread --
		# queue_free()ing this node while a request is pending makes the
		# engine block waiting for that thread to wind down. Cancel first.
		_http.cancel_request()
	# Disconnect our own client connection BEFORE killing any server we
	# spawned, not after -- closing a WebSocket peer tries a graceful close
	# handshake, which can hang waiting on a reply from an already-dead server.
	NetworkManager.disconnect_from_server()
	_spawner.kill_child()
