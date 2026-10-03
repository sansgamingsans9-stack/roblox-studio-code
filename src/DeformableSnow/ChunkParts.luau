--!strict
--[[
	ChunkParts
	Draws one SnowField chunk with ordinary Parts. No EditableMesh, so it works in every
	published game with no ID verification and no special experience setting.

	* Every snow column is a square cell. Neighbouring cells with the same (quantized) height and
	  tint are merged into one box ("greedy meshing"), so flat untouched snow costs almost nothing:
	  a fully untouched chunk is a single Part.
	* Where something pressed the snow, the cells split up into small boxes: footprints get
	  crisp, steep walls and a flat floor, like real prints in deep snow.
	* A chunk is split into 16x16-cell tiles; a change only rebuilds the tiles it touched, and a
	  box that did not change is not touched at all (no property writes).
	* Parts are pooled and reused instead of being created/destroyed all the time.
]]

local SnowField = require(script.Parent.SnowField)

local readf32 = buffer.readf32
local NO_SNOW_LIMIT = SnowField.NO_SNOW_LIMIT

local TILE = 16 -- cells per tile side
local SINK = 0.1 -- boxes reach this far below the part surface so their sides look solid
local MIN_HEIGHT = 0.05
local POOL_MAX = 4000

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
}

type Tile = {
	parts: { Part },
	sig: { number },
	size: { Vector3 },
	cf: { CFrame },
	level: { number },
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
		ox: number,
		oz: number,
		cellW: number,
		heightStep: number,
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

-- Merge key of a cell: quantized surface height * 4 + tint level (0..3).
local function cellKey(base: number, rest: number, cur: number, q: number): number
	local h = math.floor(cur / q + 0.5)
	local level = 0
	if cur < rest - 1e-3 then
		local depth = rest - base
		if depth < 0.05 then
			depth = 0.05
		end
		level = math.clamp(math.ceil((rest - cur) / depth * 1.6 * 3), 1, 3)
	end
	return h * 4 + level
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
local function boxFor(self: ChunkParts, ci: number, cj: number, rw: number, rh: number, key: number, minBase: number): (Vector3, CFrame, number)
	local level = key % 4
	local top = ((key - level) // 4) * self.heightStep
	local bottom = minBase - SINK
	if top - bottom < MIN_HEIGHT then
		bottom = top - MIN_HEIGHT
	end
	local cw = self.cellW
	local sx, sz = rw * cw, rh * cw
	local x0 = self.ox + ci * cw
	local z0 = self.oz + cj * cw
	return Vector3.new(sx, top - bottom, sz), CFrame.new(x0 + sx * 0.5, (top + bottom) * 0.5, z0 + sz * 0.5), level
end

local function emptyTile(): Tile
	return { parts = {}, sig = {}, size = {}, cf = {}, level = {} }
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

-- Reads one tile's cells into the scratch buffers. Returns w, h.
local function gather(self: ChunkParts, src: Source, ti: number, tj: number): (number, number)
	local i0, j0 = ti * TILE, tj * TILE
	local w = math.min(TILE, self.nSide - i0)
	local h = math.min(TILE, self.nSide - j0)
	local q = self.heightStep
	local stride, n = src.stride, src.n
	for j = 0, h - 1 do
		local rowO = (j0 + j) * stride * n
		for i = 0, w - 1 do
			local o = (rowO + (i0 + i) * stride) * 4
			local idx = j * w + i + 1
			local b = readf32(src.base, o)
			if b > NO_SNOW_LIMIT then
				keys[idx] = cellKey(b, readf32(src.rest, o), readf32(src.cur, o), q)
				bases[idx] = b
			else
				keys[idx] = false
			end
		end
	end
	return w, h
end

local function rebuildTile(self: ChunkParts, src: Source, ti: number, tj: number)
	local w, h = gather(self, src, ti, tj)
	local count = greedy(w, h)
	local tileIndex = tj * self.tilesPerSide + ti
	local tile = self.tiles[tileIndex]
	if not tile then
		tile = emptyTile()
		self.tiles[tileIndex] = tile
	end

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
		if oldCF ~= cf then
			p.CFrame = cf
		end
		if oldLevel ~= level then
			p.Color = colors[level + 1]
		end
		if oldSize == nil then
			p.Parent = folder
		end
		local idx = r + 1
		newParts[idx], newSize[idx], newCF[idx], newLevel[idx] = p, size, cf, level
		newSig[idx] = ri + rj * 32 + rw * 1024 + rh * 32768
	end
	for _, k in free do
		releasePart(tile.parts[k])
	end

	tile.parts, tile.sig, tile.size, tile.cf, tile.level = newParts, newSig, newSize, newCF, newLevel
end

-- If every cell of the chunk has snow at the same height/tint, returns that key and min base.
local function uniformKey(self: ChunkParts, src: Source): (number?, number)
	local q = self.heightStep
	local stride, n = src.stride, src.n
	local key: number? = nil
	local minB = math.huge
	for j = 0, self.nSide - 1 do
		local rowO = j * stride * n
		for i = 0, self.nSide - 1 do
			local o = (rowO + i * stride) * 4
			local b = readf32(src.base, o)
			if b <= NO_SNOW_LIMIT then
				return nil, 0
			end
			local k = cellKey(b, readf32(src.rest, o), readf32(src.cur, o), q)
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
	local size, cf, level = boxFor(self, 0, 0, self.nSide, self.nSide, key, minB)
	local p = self.solid
	if not p then
		p = takePart(self.style)
		self.solid = p
		self.solidSize, self.solidCF, self.solidLevel = nil, nil, -1
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
	part.Parent = self.folder
end

local function clearSolid(self: ChunkParts)
	local p = self.solid
	if p then
		releasePart(p)
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

	-- any snow at all?
	local any = false
	for j = 0, nSide - 1 do
		local rowO = j * src.stride * src.n
		for i = 0, nSide - 1 do
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

	-- cell (i, j) covers columns [i*step, (i+1)*step) of the chunk, each column being a
	-- CellSize square centred on its grid point; neighbouring chunks tile without gaps
	local self = setmetatable({
		step = step,
		nSide = nSide,
		tilesPerSide = math.ceil(nSide / TILE),
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
		ox = chunk.cx * C * S - S * 0.5,
		oz = chunk.cz * C * S - S * 0.5,
		cellW = step * S,
		heightStep = math.max(0.005, style.heightStep),
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

	local changed = false
	if dirty then
		local n = full.n
		local C = n - 1
		local step = self.step
		local tps = self.tilesPerSide
		local marked: { [number]: boolean } = {}
		local any = false
		for i, flag in dirty do
			if flag == 1 then
				local lx, lz = i % n, i // n
				-- column C belongs to the next chunk; at coarse detail only aligned columns are drawn
				if lx < C and lz < C and lx % step == 0 and lz % step == 0 then
					marked[((lz // step) // TILE) * tps + (lx // step) // TILE] = true
					any = true
				end
			end
		end
		if any then
			changed = true
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
	if changed and full.activeCount == 0 and not self.solid then
		local key, minB = uniformKey(self, src)
		if key then
			setSolid(self, key, minB)
		end
	end
end

return ChunkParts
