class_name Room
extends RefCounted

## 一个房间。房主固定执红（先手），加入者执绿。

var code: String
var host_id: int
var guest_id: int = 0
## 开局后才有值
var session: Session = null
var started := false


func _init(p_code: String, p_host_id: int) -> void:
	code = p_code
	host_id = p_host_id


func has_player(peer_id: int) -> bool:
	return peer_id == host_id or (guest_id != 0 and peer_id == guest_id)


func is_full() -> bool:
	return guest_id != 0


## 对手的 peer id；没有对手时返回 0。
func other_player(peer_id: int) -> int:
	return guest_id if peer_id == host_id else host_id


## 该玩家在这局里执哪一方。
func camp_of(peer_id: int) -> PieceInfo.Camp:
	return PieceInfo.Camp.RED if peer_id == host_id else PieceInfo.Camp.GREEN


## 回到「已创建、等待对手」的状态（对手中途离开时用）。
func reset_to_waiting() -> void:
	guest_id = 0
	started = false
	session = null


func _to_string() -> String:
	return "Room(%s host=%d guest=%d started=%s)" % [code, host_id, guest_id, started]
