class_name PieceInfo
extends RefCounted

## 棋子的纯数据表示：不含任何节点与渲染，可安全地放进局面字典并直接序列化上网。
##
## 渲染用的 Piece（Label）只是 Board 根据局面派生出来的视图，
## 服务端全程不创建任何节点，只操作 Dictionary[Vector2i -> PieceInfo]。

enum Camp { RED, GREEN }
enum Kind { KING, ARCHER, KNIGHT, SHIELD, PAWN }

## 兵种与显示文字。
const SYMBOLS: Dictionary = {
	Kind.KING: "王",
	Kind.ARCHER: "弓",
	Kind.KNIGHT: "骑",
	Kind.SHIELD: "盾",
	Kind.PAWN: "步",
}
## 显示文字到兵种的反查表，用于解析初始布局。
const SYMBOL_KINDS: Dictionary = {
	"王": Kind.KING,
	"弓": Kind.ARCHER,
	"骑": Kind.KNIGHT,
	"盾": Kind.SHIELD,
	"步": Kind.PAWN,
}

## 兵种。
var kind: Kind = Kind.PAWN
## 所属阵营。
var camp: Camp = Camp.RED


func _init(p_kind: Kind = Kind.PAWN, p_camp: Camp = Camp.RED) -> void:
	kind = p_kind
	camp = p_camp


func symbol() -> String:
	return SYMBOLS.get(kind, "?")


func camp_name() -> String:
	return "红" if camp == Camp.RED else "绿"


## 网络传输用的紧凑表示：[兵种, 阵营]
func to_array() -> Array:
	return [kind, camp]


static func from_array(data: Array) -> PieceInfo:
	return PieceInfo.new(data[0], data[1])


func copy() -> PieceInfo:
	return PieceInfo.new(kind, camp)


func equals(other: PieceInfo) -> bool:
	return other != null and other.kind == kind and other.camp == camp


func _to_string() -> String:
	return "PieceInfo(%s%s)" % [camp_name(), symbol()]
