class_name Session
extends RefCounted

## 一局对局的权威流程：持有局面与当前回合，负责走子、吃子与两个结算时点。
##
## 这一层不含任何节点，所以：
##   - 服务端每个房间持有一个 Session，作为唯一权威；
##   - 单机模式由 Game 自己持有一个 Session，行为与联机完全一致；
##   - 客户端联机时不自建 Session，只按服务端下发的局面渲染。
##
## 回合结构（已与需求确认）：
##   红回合开始 → 结算红 → 红走子 → 红回合结束 → 结算红
##   → 绿回合开始 → 结算绿 → 绿走子 → 绿回合结束 → 结算绿 → 循环
## 每个棋子在己方回合内有「走子前」「走子后」两个攻击窗口；
## 每次结算只结算该回合玩家的棋子（盾的抵抗是被动检查，不占结算名额）。

## 初始布局，7 行 × 7 列，"." 表示空位（原点在左上角）。
##
## 左上角为红方，右下角为绿方，双方关于棋盘中心 180° 旋转对称。
## 反对角线（col + row == board_size - 1）上恰好全是空位，因此可以无歧义地按它划分阵营。
const INITIAL_LAYOUT: Array[String] = [
	"王.弓.骑..",
	"..盾步...",
	"弓盾....骑",
	".步...步.",
	"骑....盾弓",
	"...步盾..",
	"..骑.弓.王",
]

## 布局中的空位符号。
const EMPTY_SYMBOL := "."

var board_size: int = 7
## 局面：{Vector2i: PieceInfo}
var state: Dictionary = {}
## 当前该谁走
var current_camp: PieceInfo.Camp = PieceInfo.Camp.RED


func _init(p_board_size: int = 7) -> void:
	board_size = p_board_size


# --- 开局 ---

## 按初始布局开局（红先），并立即做一次红方的回合开始结算。
func start() -> void:
	state = initial_state(board_size)
	current_camp = PieceInfo.Camp.RED
	settle(current_camp)


## 构造初始局面。
static func initial_state(size: int) -> Dictionary:
	var result := {}
	if INITIAL_LAYOUT.size() != size:
		push_error("初始布局有 %d 行，棋盘需要 %d 行" % [INITIAL_LAYOUT.size(), size])
		return result
	for row in range(size):
		var line: String = INITIAL_LAYOUT[row]
		if line.length() != size:
			push_error("初始布局第 %d 行有 %d 列，棋盘需要 %d 列" % [row, line.length(), size])
			continue
		for col in range(size):
			var symbol := line[col]
			if symbol == EMPTY_SYMBOL:
				continue
			if not PieceInfo.SYMBOL_KINDS.has(symbol):
				push_error("初始布局出现未知棋子符号「%s」" % symbol)
				continue
			var cell := Vector2i(col, row)
			result[cell] = PieceInfo.new(PieceInfo.SYMBOL_KINDS[symbol], Rules.camp_of(cell, size))
	return result


# --- 走子 ---

## from 格的棋子现在能否走到 to 格（必须是当前回合玩家的棋子，且落点合法）。
func can_move(from: Vector2i, to: Vector2i) -> bool:
	var piece: PieceInfo = state.get(from)
	if piece == null or piece.camp != current_camp:
		return false
	return to in Rules.reachable_cells(state, from, board_size)


## from 格的棋子能走到的全部格子（不含「轮到谁」这一层限制）。
func moves_for(from: Vector2i) -> Array[Vector2i]:
	return Rules.reachable_cells(state, from, board_size)


## 执行一步：走子（含王的吃子）→ 回合结束结算 → 换边 → 对方回合开始结算。
## 成功返回 true；非法返回 false 且不改动任何状态。
func try_move(from: Vector2i, to: Vector2i) -> bool:
	if not can_move(from, to):
		return false
	var mover: PieceInfo = state[from]
	state.erase(from)
	state[to] = mover  # 目标格若有敌方棋子，这一步就是吃子
	settle(current_camp)                       # 回合结束结算
	current_camp = Rules.opponent_of(current_camp)
	settle(current_camp)                       # 对方回合开始结算
	return true


## 结算 camp 一方的攻击，返回被击杀的格子。
func settle(camp: PieceInfo.Camp) -> Array[Vector2i]:
	var killed: Array[Vector2i] = Rules.resolve_kills(state, board_size, camp)
	for cell in killed:
		state.erase(cell)
	return killed


# --- 序列化 ---

## 打包成可直接上网的紧凑结构：[棋盘边长, 当前回合, [[x, y, 兵种, 阵营], ...]]
func to_snapshot() -> Array:
	var cells := []
	for cell in state.keys():
		var info: PieceInfo = state[cell]
		cells.append([cell.x, cell.y, info.kind, info.camp])
	# 排序让快照内容稳定，便于测试与比对
	cells.sort_custom(func(a, b): return a[1] < b[1] if a[1] != b[1] else a[0] < b[0])
	return [board_size, current_camp, cells]


## 从快照还原出一个 Session（客户端用它构造本地局面）。
static func from_snapshot(snapshot: Array) -> Session:
	var session := Session.new(snapshot[0])
	session.current_camp = snapshot[1]
	session.state = state_from_snapshot(snapshot)
	return session


## 只还原局面字典，供不需要完整 Session 的地方使用。
static func state_from_snapshot(snapshot: Array) -> Dictionary:
	var result := {}
	for entry in snapshot[2]:
		result[Vector2i(entry[0], entry[1])] = PieceInfo.new(entry[2], entry[3])
	return result
