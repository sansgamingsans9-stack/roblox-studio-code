--!strict
--[[
	ChunkParts
	Draws one SnowField chunk with ordinary Parts. No EditableMesh, so it works in every
	published game with no ID verification and no special experience setting.

	* Every snow sample is a square cell centred on it. Neighbouring cells with the same (rounded)
	  height and tint are merged into one box ("greedy meshing"), so flat untouched snow costs
	  almost nothing: a fully untouched chunk is a single Part.
	* Where something pressed the snow, the cells split up into small boxes: footprints get
	  crisp, steep walls and a flat floor, like real prints in deep snow.
	* A chunk covers exactly its own area (the first and last row/column of cells are half
	  cells), so chunks drawn at different detail levels tile without gaps or overlaps.
	* A chunk is split into 16x16-cell tiles. A change only rebuilds the tiles whose visible cells
	  changed, a box that did not change is not touched at all, moved boxes are batched through
	  Workspace:BulkMoveTo, and Parts are pooled and reused.
	* A tile that would need too many boxes (snow on a steep or diagonal slope) rounds its
	  untouched snow more coarsely (wider terraces) until it fits a budget.
]]

local Workspace = game:GetService("Workspace")

local SnowField = require(script.Parent.SnowField)

local readf32 = buffer.readf32
local NO_SNOW_LIMIT = SnowField.NO_SNOW_LIMIT

local TILE = 16 -- cells per tile side
local SINK = 0.02 -- boxes reach this far below the ground so their sides look solid
-- the cell lattice is shifted by this tiny amount so box sides never line up exactly with the
-- sides of the snow parts (which sit on round coordinates) and flicker
local NUDGE = 0.0013
local CLEAR = 0.03 -- the snow top is always at least this far above the ground (no z-fighting)
local MIN_HEIGHT = 0.05
local POOL_MAX = 4000
local MAX_RECTS = 40 -- boxes per tile before untouched snow gets rounded/merged more coarsely
local MAX_MULT = 16 -- coarsest terrace height: restHeightStep * 16
local MAX_BLOCK = 4 -- coarsest merge of untouched snow on slopes: 4x4 cells
local NO_KEY = math.huge -- key cache value for cells without snow

local ChunkParts = {}
ChunkParts.__index = ChunkParts

-- number of snow Parts currently in use by all chunks (the client uses it as a safety cap)
ChunkParts.liveCount = 0

export type Style = {
	color: Color3,
	packedTint: Color3,
	material: Enum.Material,
	materialVariant: string,
	studsPerTile: number,
	castShadow: boolean,
	parent: Instance,
	heightStep: number,
	restHeightStep: number,
}

type Tile = {
	parts: { Part },
	sig: { number },
	size: { Vector3 },
	cf: { CFrame },
	level: { number },
	mult: number,
	block: number,
}

type Source = {
	base: buffer,
	rest: buffer,
	cur: buffer,
	n: number,
	stride: number,
}

export type ChunkParts = typeof(setmetatable(
	{} :: {
		step: number,
		nSide: number,
		nCells: number,
		tilesPerSide: number,
		usesFull: boolean,
		gridVersion: number,
		version: number,
		destroyed: boolean,
		folder: Folder,
		solid: Part?,
		solidSize: Vector3?,
		solidCF: CFrame?,
		solidLevel: number,
		tiles: { [number]: Tile },
		keyCache: { number },
		partCount: number,
		ox: number,
		oz: number,
		cellW: number,
		heightStep: number,
		restStep: number,
		slopeLimit: number,
		colors: { Color3 },
		style: Style,
	},
	ChunkParts
))

------------------------------------------------------------------ part pool
local pool: { Part } = {}

local function takePart(style: Style): Part
	ChunkParts.liveCount += 1
	local pooled = table.remove(pool)
	if pooled then
		return pooled
	end
	local p = Instance.new("Part")
	p.Name = "Snow"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	-- Instance.new parts default to studded top / inlet bottom surfaces
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = style.material
	if style.materialVariant ~= "" then
		p.MaterialVariant = style.materialVariant
	end
	p.CastShadow = style.castShadow
	p.Locked = true
	return p
end

local function releasePart(p: Part)
	ChunkParts.liveCount -= 1
	if #pool < POOL_MAX then
		p.Parent = nil
		table.insert(pool, p)
	else
		p:Destroy()
	end
end

-- CFrame changes of already placed boxes, applied in one BulkMoveTo call
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

local function flushMoves()
	local count = #moveParts
	if count == 0 then
		return
	end
	local ok = count >= 8
		and pcall(Workspace.BulkMoveTo, Workspace, moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	if not ok then
		for k = 1, count do
			moveParts[k].CFrame = moveCFrames[k]
		end
	end
	table.clear(moveParts)
	table.clear(moveCFrames)
end

------------------------------------------------------------------ helpers
local function sourceFor(chunk: SnowField.Chunk, step: number): Source?
	local full = chunk.full
	if full then
		return { base = full.base, rest = full.rest, cur = full.cur, n = full.n, stride = step }
	end
	local g = chunk.coarse[step]
	if g then
		return { base = g.base, rest = g.rest, cur = g.rest, n = g.n, stride = 1 }
	end
	return nil
end

-- 4 shades: fresh snow, then three steps towards fully packed snow
local function makeColors(style: Style): { Color3 }
	local c, t = style.color, style.packedTint
	local packed = Color3.new(c.R * t.R, c.G * t.G, c.B * t.B)
	return { c, c:Lerp(packed, 1 / 3), c:Lerp(packed, 2 / 3), packed }
end

--[[
	Merge key of a cell: surface height (in units of q) * 4 + tint level (0..3).
	Untouched snow is rounded to the coarser `restStep` (a multiple of q) so gentle slopes and the
	thinning edges merge into a few wide terraces; pressed snow and rims keep the fine step.
	The drawn top never ends up at or below the ground.
]]
local function cellKey(base: number, rest: number, cur: number, q: number, restStep: number): number
	local restH = math.floor(rest / restStep + 0.5) * restStep
	local level = 0
	local hgt
	if cur < rest - 1e-3 then
		local depth = rest - base
		if depth < 0.05 then
			depth = 0.05
		end
		level = math.clamp(math.ceil((rest - cur) / depth * 1.6 * 3), 1, 3)
		hgt = math.min(math.floor(cur / q + 0.5) * q, restH)
	elseif cur > rest + 1e-3 then
		hgt = math.max(math.floor(cur / q + 0.5) * q, restH)
	else
		hgt = restH
	end
	local lowest = math.ceil((base + CLEAR) / q) * q
	if hgt < lowest then
		hgt = lowest
	end
	return math.floor(hgt / q + 0.5) * 4 + level
end

--[[
	Key of cell (ci, cj). Untouched snow in a coarsened tile (block > 1) takes the highest snow of
	its block x block group of cells, so slopes become bigger steps without the ground poking out.
]]
local function keyAt(
	self: ChunkParts,
	src: Source,
	ci: number,
	cj: number,
	o: number,
	b: number,
	mult: number,
	block: number
): number
	local rest = readf32(src.rest, o)
	local cur = readf32(src.cur, o)
	local q, rq = self.heightStep, self.restStep * mult
	if block > 1 and math.abs(cur - rest) <= 1e-3 then
		local stride, n, last = src.stride, src.n, self.nSide
		local bi, bj = ci - ci % block, cj - cj % block
		local top = rest
		for j = bj, math.min(last, bj + block - 1) do
			for i = bi, math.min(last, bi + block - 1) do
				local o2 = (j * stride * n + i * stride) * 4
				if readf32(src.base, o2) > NO_SNOW_LIMIT then
					local r2 = readf32(src.rest, o2)
					if r2 > top then
						top = r2
					end
				end
			end
		end
		return cellKey(b, top, top, q, rq)
	end
	return cellKey(b, rest, cur, q, rq)
end

-- scratch buffers reused by every tile rebuild (one tile at a time, no yields inside)
local keys: { number | boolean } = table.create(TILE * TILE, false)
local bases: { number } = table.create(TILE * TILE, 0)
local visited: { boolean } = table.create(TILE * TILE, false)
local rects: { number } = {} -- flat: i, j, w, h, key, minBase per rect

--[[
	Greedy rectangle merge over a w x h grid of keys (false = no snow).
	Fills `rects` and returns the number of rectangles.
]]
local function greedy(w: number, h: number): number
	local count = 0
	for idx = 1, w * h do
		visited[idx] = false
	end
	for j = 0, h - 1 do
		for i = 0, w - 1 do
			local idx = j * w + i + 1
			local k = keys[idx]
			if k ~= false and not visited[idx] then
				local rw = 1
				while i + rw < w do
					local n = idx + rw
					if keys[n] == k and not visited[n] then
						rw += 1
					else
						break
					end
				end
				local rh = 1
				while j + rh < h do
					local row = (j + rh) * w + i + 1
					local ok = true
					for t = 0, rw - 1 do
						if keys[row + t] ~= k or visited[row + t] then
							ok = false
							break
						end
					end
					if not ok then
						break
					end
					rh += 1
				end
				local minB = math.huge
				for jj = 0, rh - 1 do
					local row = (j + jj) * w + i + 1
					for t = 0, rw - 1 do
						visited[row + t] = true
						local b = bases[row + t]
						if b < minB then
							minB = b
						end
					end
				end
				local o = count * 6
				rects[o + 1], rects[o + 2], rects[o + 3], rects[o + 4], rects[o + 5], rects[o + 6] =
					i, j, rw, rh, k :: number, minB
				count += 1
			end
		end
	end
	return count
end

------------------------------------------------------------------ boxes
-- Box for cells [ci, ci+rw) x [cj, cj+rh). Cell i is centred on sample i; the first and last
-- cells of a chunk are half cells so the chunk covers exactly its own area.
local function boxFor(
	self: ChunkParts,
	ci: number,
	cj: number,
	rw: number,
	rh: number,
	key: number,
	minBase: number
): (Vector3, CFrame, number)
	local level = key % 4
	local top = ((key - level) // 4) * self.heightStep
	local bottom = minBase - SINK
	if top - bottom < MIN_HEIGHT then
		bottom = top - MIN_HEIGHT
	end
	local cw, last = self.cellW, self.nSide
	local x0 = math.max(0, ci - 0.5) * cw
	local x1 = math.min(last, ci + rw - 0.5) * cw
	local z0 = math.max(0, cj - 0.5) * cw
	local z1 = math.min(last, cj + rh - 0.5) * cw
	return Vector3.new(x1 - x0, top - bottom, z1 - z0),
		CFrame.new(self.ox + (x0 + x1) * 0.5, (top + bottom) * 0.5, self.oz + (z0 + z1) * 0.5),
		level
end

local function releaseTile(tile: Tile)
	for _, p in tile.parts do
		releasePart(p)
	end
	table.clear(tile.parts)
	table.clear(tile.sig)
	table.clear(tile.size)
	table.clear(tile.cf)
	table.clear(tile.level)
end

--[[
	Reads one tile's cells into the scratch buffers (and the key cache). Returns w, h.
	The base stored per cell is the lowest ground among the cell and its neighbours (unless a
	neighbour is a cliff), so on slopes every box reaches down to its lower neighbour: no gaps.
]]
local function gather(
	self: ChunkParts,
	src: Source,
	ti: number,
	tj: number,
	mult: number,
	block: number
): (number, number, boolean)
	local i0, j0 = ti * TILE, tj * TILE
	local nCells, last = self.nCells, self.nSide
	local w = math.min(TILE, nCells - i0)
	local h = math.min(TILE, nCells - j0)
	local stride, n = src.stride, src.n
	local baseB = src.base
	local cache = self.keyCache
	local limit = self.slopeLimit
	local restLo, restHi = math.huge, -math.huge
	for j = 0, h - 1 do
		local cj = j0 + j
		local rowO = cj * stride * n
		local cacheRow = cj * nCells + i0 + 1
		for i = 0, w - 1 do
			local ci = i0 + i
			local o = (rowO + ci * stride) * 4
			local idx = j * w + i + 1
			local b = readf32(baseB, o)
			if b > NO_SNOW_LIMIT then
				local k = keyAt(self, src, ci, cj, o, b, mult, block)
				keys[idx] = k
				if k % 4 == 0 then
					if k < restLo then
						restLo = k
					end
					if k > restHi then
						restHi = k
					end
				end
				cache[cacheRow + i] = k
				local low = b
				if ci > 0 then
					local nb = readf32(baseB, o - stride * 4)
					if nb > NO_SNOW_LIMIT and nb < low and b - nb <= limit then
						low = nb
					end
				end
				if ci < last then
					local nb = readf32(baseB, o + stride * 4)
					if nb > NO_SNOW_LIMIT and nb < low and b - nb <= limit then
						low = nb
					end
				end
				if cj > 0 then
					local nb = readf32(baseB, o - stride * n * 4)
					if nb > NO_SNOW_LIMIT and nb < low and b - nb <= limit then
						low = nb
					end
				end
				if cj < last then
					local nb = readf32(baseB, o + stride * n * 4)
					if nb > NO_SNOW_LIMIT and nb < low and b - nb <= limit then
						low = nb
					end
				end
				bases[idx] = low
			else
				keys[idx] = false
				cache[cacheRow + i] = NO_KEY
			end
		end
	end
	-- coarser rounding/merging can only help where untouched snow is not one flat level
	return w, h, restHi > restLo
end

local function rebuildTile(self: ChunkParts, src: Source, ti: number, tj: number)
	local mult, block = 1, 1
	local w, h, varies = gather(self, src, ti, tj, mult, block)
	local count = greedy(w, h)
	-- too many boxes (steep / diagonal / curved snow): first round untouched snow to taller
	-- terraces, then merge it in bigger blocks. Prints keep full detail. Flat snow with many
	-- prints is left alone (coarser rounding would not change anything there).
	while count > MAX_RECTS and varies do
		if mult < MAX_MULT then
			mult *= 2
		elseif block < MAX_BLOCK then
			block *= 2
		else
			break
		end
		w, h, varies = gather(self, src, ti, tj, mult, block)
		count = greedy(w, h)
	end

	local tileIndex = tj * self.tilesPerSide + ti
	local tile = self.tiles[tileIndex]
	if not tile then
		tile = { parts = {}, sig = {}, size = {}, cf = {}, level = {}, mult = mult, block = block }
		self.tiles[tileIndex] = tile
	end
	tile.mult, tile.block = mult, block

	-- keep parts whose rectangle did not move; hand the rest out to the new rectangles
	local bySig: { [number]: number } = {}
	for k, s in tile.sig do
		bySig[s] = k
	end
	local claimed: { [number]: boolean } = {}
	local assign: { number } = table.create(count, 0)
	for r = 0, count - 1 do
		local o = r * 6
		local sig = rects[o + 1] + rects[o + 2] * 32 + rects[o + 3] * 1024 + rects[o + 4] * 32768
		local k = bySig[sig]
		if k and not claimed[k] then
			claimed[k] = true
			assign[r + 1] = k
		end
	end
	local free: { number } = {}
	for k = 1, #tile.parts do
		if not claimed[k] then
			table.insert(free, k)
		end
	end

	local newParts: { Part } = table.create(count)
	local newSig: { number } = table.create(count, 0)
	local newSize: { Vector3 } = table.create(count)
	local newCF: { CFrame } = table.create(count)
	local newLevel: { number } = table.create(count, -1)
	local style, folder, colors = self.style, self.folder, self.colors
	local ci0, cj0 = ti * TILE, tj * TILE

	for r = 0, count - 1 do
		local o = r * 6
		local ri, rj, rw, rh = rects[o + 1], rects[o + 2], rects[o + 3], rects[o + 4]
		local size, cf, level = boxFor(self, ci0 + ri, cj0 + rj, rw, rh, rects[o + 5], rects[o + 6])
		local k = assign[r + 1]
		local p: Part, oldSize: Vector3?, oldCF: CFrame?, oldLevel: number
		if k ~= 0 then
			p, oldSize, oldCF, oldLevel = tile.parts[k], tile.size[k], tile.cf[k], tile.level[k]
		else
			local fk = table.remove(free)
			if fk then
				p, oldSize, oldCF, oldLevel = tile.parts[fk], tile.size[fk], tile.cf[fk], tile.level[fk]
			else
				p, oldSize, oldCF, oldLevel = takePart(style), nil, nil, -1
			end
		end
		if oldSize ~= size then
			p.Size = size
		end
		if oldLevel ~= level then
			p.Color = colors[level + 1]
		end
		if oldSize == nil then
			-- fresh from the pool: place it, then show it
			p.CFrame = cf
			p.Parent = folder
		elseif oldCF ~= cf then
			table.insert(moveParts, p)
			table.insert(moveCFrames, cf)
		end
		local idx = r + 1
		newParts[idx], newSize[idx], newCF[idx], newLevel[idx] = p, size, cf, level
		newSig[idx] = ri + rj * 32 + rw * 1024 + rh * 32768
	end
	flushMoves()
	for _, k in free do
		releasePart(tile.parts[k])
	end
	self.partCount += count - #tile.parts

	tile.parts, tile.sig, tile.size, tile.cf, tile.level = newParts, newSig, newSize, newCF, newLevel
end

-- If every cell of the chunk has snow at the same height/tint, returns that key and min base.
local function uniformKey(self: ChunkParts, src: Source): (number?, number)
	local q, rq = self.heightStep, self.restStep
	local stride, n = src.stride, src.n
	local cache, nCells = self.keyCache, self.nCells
	local key: number? = nil
	local minB = math.huge
	for j = 0, nCells - 1 do
		local rowO = j * stride * n
		for i = 0, nCells - 1 do
			local o = (rowO + i * stride) * 4
			local b = readf32(src.base, o)
			if b <= NO_SNOW_LIMIT then
				cache[j * nCells + i + 1] = NO_KEY
				return nil, 0
			end
			local k = cellKey(b, readf32(src.rest, o), readf32(src.cur, o), q, rq)
			cache[j * nCells + i + 1] = k
			if key == nil then
				key = k
			elseif k ~= key then
				return nil, 0
			end
			if b < minB then
				minB = b
			end
		end
	end
	return key, minB
end

local function setSolid(self: ChunkParts, key: number, minB: number)
	for _, tile in self.tiles do
		releaseTile(tile)
	end
	table.clear(self.tiles)
	self.partCount = 1
	local size, cf, level = boxFor(self, 0, 0, self.nCells, self.nCells, key, minB)
	local p = self.solid
	local fresh = false
	if not p then
		p = takePart(self.style)
		self.solid = p
		self.solidSize, self.solidCF, self.solidLevel = nil, nil, -1
		fresh = true
	end
	local part = p :: Part
	if self.solidSize ~= size then
		part.Size = size
		self.solidSize = size
	end
	if self.solidCF ~= cf then
		part.CFrame = cf
		self.solidCF = cf
	end
	if self.solidLevel ~= level then
		part.Color = self.colors[level + 1]
		self.solidLevel = level
	end
	if fresh then
		part.Parent = self.folder
	end
end

local function clearSolid(self: ChunkParts)
	local p = self.solid
	if p then
		releasePart(p)
		self.partCount -= 1
		self.solid = nil
		self.solidSize, self.solidCF, self.solidLevel = nil, nil, -1
	end
end

local function rebuildAll(self: ChunkParts, src: Source, budget: (() -> ())?)
	local key, minB = uniformKey(self, src)
	if key then
		setSolid(self, key, minB)
		return
	end
	clearSolid(self)
	for tj = 0, self.tilesPerSide - 1 do
		for ti = 0, self.tilesPerSide - 1 do
			rebuildTile(self, src, ti, tj)
			if budget then
				budget()
			end
		end
	end
end

------------------------------------------------------------------ public API (same shape as ChunkMesh)

--[[
	Builds the Parts for a chunk. May yield (calls `budget`).
	Returns nil + "nodata" when the grid is not sampled, nil + "empty" when there is no snow.
]]
function ChunkParts.build(
	field: SnowField.SnowField,
	chunk: SnowField.Chunk,
	step: number,
	style: Style,
	budget: () -> ()
): (ChunkParts?, string?)
	local src = sourceFor(chunk, step)
	if not src then
		return nil, "nodata"
	end
	local p = field.params
	local C, S = p.chunkCells, p.cellSize
	local nSide = C // step
	local nCells = nSide + 1

	-- any snow at all?
	local any = false
	for j = 0, nSide do
		local rowO = j * src.stride * src.n
		for i = 0, nSide do
			if readf32(src.base, (rowO + i * src.stride) * 4) > NO_SNOW_LIMIT then
				any = true
				break
			end
		end
		if any then
			break
		end
	end
	if not any then
		return nil, "empty"
	end

	local folder = Instance.new("Folder")
	folder.Name = `SnowChunk_{chunk.cx}_{chunk.cz}`
	local q = math.max(0.005, style.heightStep)
	local cellW = step * S

	local self = setmetatable({
		step = step,
		nSide = nSide,
		nCells = nCells,
		tilesPerSide = math.ceil(nCells / TILE),
		usesFull = chunk.full ~= nil,
		gridVersion = chunk.gridVersion,
		version = chunk.version,
		destroyed = false,
		folder = folder,
		solid = nil,
		solidSize = nil,
		solidCF = nil,
		solidLevel = -1,
		tiles = {},
		keyCache = table.create(nCells * nCells, NO_KEY),
		partCount = 0,
		ox = chunk.cx * C * S + NUDGE,
		oz = chunk.cz * C * S + NUDGE,
		cellW = cellW,
		heightStep = q,
		restStep = q * math.max(1, math.floor(style.restHeightStep / q + 0.5)),
		-- neighbours lower than this are cliffs, not slope (about 63 degrees over one cell)
		slopeLimit = cellW * 2,
		colors = makeColors(style),
		style = style,
	}, ChunkParts)

	rebuildAll(self, src, budget)
	folder.Parent = style.parent
	return self, nil
end

function ChunkParts.destroy(self: ChunkParts)
	if self.destroyed then
		return
	end
	self.destroyed = true
	clearSolid(self)
	for _, tile in self.tiles do
		releaseTile(tile)
	end
	table.clear(self.tiles)
	self.folder:Destroy()
end

--[[
	Brings the Parts in line with the simulation after columns changed.
	dirty: full-grid column index -> 1 (height changed) | 2 (shading only; ignored here)
	all:   rebuild everything
]]
function ChunkParts.applyDirty(
	self: ChunkParts,
	_field: SnowField.SnowField,
	chunk: SnowField.Chunk,
	dirty: { [number]: number }?,
	all: boolean?,
	_tint: Color3
)
	if self.destroyed then
		return
	end
	local full = chunk.full
	if not full then
		return
	end
	local src: Source = { base = full.base, rest = full.rest, cur = full.cur, n = full.n, stride = self.step }

	if all then
		rebuildAll(self, src, nil)
		return
	end

	local sawChange = false
	if dirty then
		local n = full.n
		local step = self.step
		local tps = self.tilesPerSide
		local nCells = self.nCells
		local cache = self.keyCache
		local marked: { [number]: boolean } = {}
		local any = false
		for i, flag in dirty do
			if flag == 1 then
				sawChange = true
				local lx, lz = i % n, i // n
				-- at lower detail only every step-th column is drawn
				if lx % step == 0 and lz % step == 0 then
					local ci, cj = lx // step, lz // step
					local tileIndex = (cj // TILE) * tps + ci // TILE
					local tile = self.tiles[tileIndex]
					local o = i * 4
					local b = readf32(full.base, o)
					local k = if b > NO_SNOW_LIMIT
						then keyAt(self, src, ci, cj, o, b, if tile then tile.mult else 1, if tile then tile.block else 1)
						else NO_KEY
					local c = cj * nCells + ci + 1
					-- only cells whose visible height or tint changed need their tile rebuilt
					if cache[c] ~= k then
						cache[c] = k
						marked[tileIndex] = true
						any = true
					end
				end
			end
		end
		if any then
			if self.solid then
				-- the chunk was one flat box: split it into tiles
				clearSolid(self)
				for tj = 0, tps - 1 do
					for ti = 0, tps - 1 do
						rebuildTile(self, src, ti, tj)
					end
				end
			else
				for idx in marked do
					rebuildTile(self, src, idx % tps, idx // tps)
				end
			end
		end
	end

	-- everything back to rest: collapse into a single box again if possible
	if sawChange and full.activeCount == 0 and not self.solid then
		local key, minB = uniformKey(self, src)
		if key then
			setSolid(self, key, minB)
		end
	end
end

return ChunkParts
