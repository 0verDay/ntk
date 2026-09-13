class_name Rules
extends RefCounted

## 棋规：与场景节点、渲染、网络都无关的纯逻辑。
##
## 「局面」统一用 Dictionary 表示：{Vector2i 格子坐标: PieceInfo}。
## 这里的函数只读取 PieceInfo 的 kind / camp，不会修改传入的局面。
## 因此服务端与客户端可以原封不动地共用这一份规则。

## 八个方向：上下左右 + 四个斜向。
const DIRECTIONS: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]

## 王的 2x2 活动区域边长。
const KING_AREA_SIZE := 2


# --- 基础 ---

static func is_inside(cell: Vector2i, board_size: int) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < board_size and cell.y < board_size


## 格子所属阵营：反对角线左上方为红，右下方为绿。
static func camp_of(cell: Vector2i, board_size: int) -> PieceInfo.Camp:
	return PieceInfo.Camp.RED if cell.x + cell.y < board_size - 1 else PieceInfo.Camp.GREEN


static func opponent_of(camp: PieceInfo.Camp) -> PieceInfo.Camp:
	return PieceInfo.Camp.GREEN if camp == PieceInfo.Camp.RED else PieceInfo.Camp.RED


## 王的活动区域（4 个格子）。
static func king_area(camp: PieceInfo.Camp, board_size: int) -> Array[Vector2i]:
	var low := 0 if camp == PieceInfo.Camp.RED else board_size - KING_AREA_SIZE
	var cells: Array[Vector2i] = []
	for row in range(low, low + KING_AREA_SIZE):
		for col in range(low, low + KING_AREA_SIZE):
			cells.append(Vector2i(col, row))
	return cells


# --- 移动可达性 ---

## 棋子从 from 出发能走到的全部格子（不含 from 自身）。
static func reachable_cells(board: Dictionary, from: Vector2i, board_size: int) -> Array[Vector2i]:
	var piece: PieceInfo = board.get(from)
	if piece == null:
		return []
	match piece.kind:
		PieceInfo.Kind.KING:
			var area := king_area(piece.camp, board_size)
			var cells: Array[Vector2i] = []
			for cell in _step_targets(board, from, board_size, true):
				if cell in area:
					cells.append(cell)
			return cells
		PieceInfo.Kind.KNIGHT:
			return _knight_reachable(board, from, board_size)
		_:
			return _step_targets(board, from, board_size, false)


## 八方向走一格。allow_capture 为 true 时可以走进敌方棋子所在的格子（王的吃子）。
static func _step_targets(board: Dictionary, from: Vector2i, board_size: int, allow_capture: bool) -> Array[Vector2i]:
	var piece: PieceInfo = board.get(from)
	if piece == null:
		return []
	var result: Array[Vector2i] = []
	for dir in DIRECTIONS:
		var cell := from + dir
		if not is_inside(cell, board_size):
			continue
		var occupant: PieceInfo = board.get(cell)
		if occupant == null:
			result.append(cell)
		elif allow_capture and occupant.camp != piece.camp:
			result.append(cell)
	return result


## 骑：基础八向走一格，外加「越过相邻单位落到其后空格」的连跳。
static func _knight_reachable(board: Dictionary, from: Vector2i, board_size: int) -> Array[Vector2i]:
	var result := _step_targets(board, from, board_size, false)
	var reached := {}
	# 跳跃图是静态的（被越过的单位不会移动），直接 BFS
	var queue: Array[Vector2i] = [from]
	while not queue.is_empty():
		var current: Vector2i = queue.pop_back()
		for dir in DIRECTIONS:
			var over := current + dir
			var landing := current + dir * 2
			if not is_inside(landing, board_size):
				continue
			if board.get(over) == null:
				continue  # 必须越过一个单位
			if board.get(landing) != null:
				continue  # 落点必须是空格
			if reached.has(landing):
				continue
			reached[landing] = true
			queue.append(landing)
	for cell in reached.keys():
		if not (cell in result):
			result.append(cell)
	return result


# --- 结算 ---

## 求出 camp 一方在本次结算中能击杀的所有格子。
##
## 采用「迭代到不动点」：每一轮都基于当前棋盘快照算出所有击杀并同时生效，
## 只要还有击杀就再算一轮，直到某一轮无人死亡。
## 这样既不会因为「先算出的击杀让别人失去支援」而使击杀失效（同一轮内同时生效），
## 也能让「击杀削弱敌方支援链，从而使另一枚棋子满足条件」的连锁反应传播开。
## 每轮至少移除一个棋子，所以必然终止。
static func resolve_kills(board: Dictionary, board_size: int, camp: PieceInfo.Camp) -> Array[Vector2i]:
	var working := board.duplicate()
	var killed := {}
	while true:
		var round_targets: Array[Vector2i] = _collect_targets(working, board_size, camp)
		if round_targets.is_empty():
			break
		for cell in round_targets:
			killed[cell] = true
			working.erase(cell)
	var result: Array[Vector2i] = []
	for cell in killed.keys():
		result.append(cell)
	return result


static func _collect_targets(board: Dictionary, board_size: int, camp: PieceInfo.Camp) -> Array[Vector2i]:
	var targets := {}
	for cell in board.keys():
		var piece: PieceInfo = board[cell]
		if piece.camp != camp:
			continue
		for target in attack_targets(board, cell, piece, board_size):
			var victim: PieceInfo = board.get(target)
			if victim != null and victim.camp != camp:
				targets[target] = true
	# Dictionary.keys() 是无类型 Array，必须显式拷进 Array[Vector2i]
	var result: Array[Vector2i] = []
	for cell in targets.keys():
		result.append(cell)
	return result


## 单枚棋子的攻击目标。
static func attack_targets(board: Dictionary, cell: Vector2i, piece: PieceInfo, board_size: int) -> Array[Vector2i]:
	match piece.kind:
		PieceInfo.Kind.PAWN:
			return _pawn_targets(board, cell, piece, board_size)
		PieceInfo.Kind.ARCHER:
			return _archer_targets(board, cell, piece, board_size)
		PieceInfo.Kind.KNIGHT:
			return _knight_targets(board, cell, piece, board_size)
		_:
			# 王靠移动吃子，盾没有攻击逻辑
			return []


## 盾的抵抗：沿攻击方向越过盾之后的紧邻一格若站着同阵营友军，则这次攻击被抵抗。
static func is_shield_resisted(board: Dictionary, shield_cell: Vector2i, attack_dir: Vector2i, board_size: int) -> bool:
	var shield: PieceInfo = board.get(shield_cell)
	if shield == null or shield.kind != PieceInfo.Kind.SHIELD:
		return false
	var behind := shield_cell + attack_dir
	if not is_inside(behind, board_size):
		return false
	var behind_piece: PieceInfo = board.get(behind)
	return behind_piece != null and behind_piece.camp == shield.camp


## 从 start 沿 dir 数连续的同阵营棋子数量（不含 start 自身）。
static func chain_length(board: Dictionary, start: Vector2i, dir: Vector2i, camp: PieceInfo.Camp, board_size: int) -> int:
	var count := 0
	var cursor := start + dir
	while is_inside(cursor, board_size):
		var piece: PieceInfo = board.get(cursor)
		if piece == null or piece.camp != camp:
			break
		count += 1
		cursor += dir
	return count


## 步：3x3 内的每个敌人单独判定。
## 沿「本棋子 → 敌人」方向，比较各自背后连续友军的数量，多的一方获胜（相等则不触发）。
## 满足条件的敌人全部击杀（一回合可杀多个）。
static func _pawn_targets(board: Dictionary, cell: Vector2i, piece: PieceInfo, board_size: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for dir in DIRECTIONS:
		var enemy_cell := cell + dir
		if not is_inside(enemy_cell, board_size):
			continue
		var enemy: PieceInfo = board.get(enemy_cell)
		if enemy == null or enemy.camp == piece.camp:
			continue
		if is_shield_resisted(board, enemy_cell, dir, board_size):
			continue
		var own_support := chain_length(board, cell, -dir, piece.camp, board_size)
		var enemy_support := chain_length(board, enemy_cell, dir, enemy.camp, board_size)
		if own_support > enemy_support:
			result.append(enemy_cell)
	return result


## 弓：3x3 内每个相邻友军提供一个射击方向，沿「弓 → 友军」的延长线射击。
## 正交方向射程 2 格，斜向射程 1 格（都不含那个友军）。
## 射程内的敌人都会被击杀；只有敌方的盾会挡住它后面的格子。
static func _archer_targets(board: Dictionary, cell: Vector2i, piece: PieceInfo, board_size: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for dir in DIRECTIONS:
		var friend_cell := cell + dir
		var friend: PieceInfo = board.get(friend_cell)
		if friend == null or friend.camp != piece.camp:
			continue
		var reach := 2 if (dir.x == 0 or dir.y == 0) else 1
		for step in range(1, reach + 1):
			var target := friend_cell + dir * step
			if not is_inside(target, board_size):
				break
			var hit: PieceInfo = board.get(target)
			if hit == null or hit.camp == piece.camp:
				continue  # 空格与友军都不阻挡
			if hit.kind == PieceInfo.Kind.SHIELD:
				# 盾会挡住它后面的所有格子；它自己能否被击杀取决于是否被抵抗
				if not is_shield_resisted(board, target, dir, board_size):
					result.append(target)
				break
			result.append(target)
	return result


## 骑：3x3 内的敌人，若「骑 → 敌人」延长线上的后一格站着友军，则击杀该敌人。
static func _knight_targets(board: Dictionary, cell: Vector2i, piece: PieceInfo, board_size: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for dir in DIRECTIONS:
		var enemy_cell := cell + dir
		if not is_inside(enemy_cell, board_size):
			continue
		var enemy: PieceInfo = board.get(enemy_cell)
		if enemy == null or enemy.camp == piece.camp:
			continue
		var behind := enemy_cell + dir
		if not is_inside(behind, board_size):
			continue
		var behind_piece: PieceInfo = board.get(behind)
		if behind_piece == null or behind_piece.camp != piece.camp:
			continue
		if is_shield_resisted(board, enemy_cell, dir, board_size):
			continue
		result.append(enemy_cell)
	return result
