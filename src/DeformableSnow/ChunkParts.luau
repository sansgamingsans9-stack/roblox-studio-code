--!strict
--[[
	ChunkParts
	Draws one SnowField chunk with ordinary Parts and WedgeParts. No EditableMesh, so it works in
	every published game without ID verification or any special setting.

	* Untouched, level snow is drawn with boxes, merged as much as possible: a fully untouched
	  chunk is ONE Part.
	* Everything else (footprints, trails, rims, slopes) is drawn as a real triangle surface, just
	  like a mesh:
	    - a right-triangulated irregular network (RTIN, the "Martini" algorithm) picks big
	      triangles where the snow is flat and small ones only where the shape needs them;
	    - every triangle is drawn with two WedgeParts.
	  Prints are smooth dents, not pixels.
	* A chunk is split into 16x16-cell tiles. A change only rebuilds the tiles whose samples
	  visibly changed, and triangles/boxes that did not change are not touched at all.
	* Parts are pooled and reused; moved Parts are batched through Workspace:BulkMoveTo.
]]

local Workspace = game:GetService("Workspace")

local SnowField = require(script.Parent.SnowField)

local readf32 = buffer.readf32
local NO_SNOW_LIMIT = SnowField.NO_SNOW_LIMIT

local TILE = 16 -- cells per tile side (a power of two, for the triangulation)
local Q = 0.01 -- drawn heights are rounded to this (also used to detect visible changes)
local SINK = 0.02 -- boxes reach this far below the ground so their sides look solid
local THICK = 0.12 -- wedge thickness, hidden below the surface (covers hairline cracks)
local NUDGE = 0.0013 -- keeps box sides off the (round) coordinates of part sides: no flicker
local MIN_HEIGHT = 0.05
local REST_EPS = 1e-3
-- untouched tiles with at most this many flat snow levels (snow on parts at different heights) are
-- drawn with boxes, the steps between levels become clean vertical edges, instead of a strip of
-- triangles along every edge; more levels means a slope: triangles
local MAX_LEVELS = 4 -- (a tile where four parts of different heights meet)
local LEVELS = 6 -- shades between fresh and fully packed snow
local POOL_MAX = 6000
local NO_KEY = math.huge

local ChunkParts = {}
ChunkParts.__index = ChunkParts

-- number of snow Parts currently in use by all chunks (the client uses it for its budget)
ChunkParts.liveCount = 0
ChunkParts.Q = Q

export type Style = {
	color: Color3,
	packedTint: Color3,
	material: Enum.Material,
	materialVariant: string,
	studsPerTile: number,
	castShadow: boolean,
	parent: Instance,
	smoothness: number,
}

type TriRec = {
	w1: WedgePart,
	w2: WedgePart,
	ka: number,
	kb: number,
	kc: number,
	level: number,
}

type Tile = {
	kind: number, -- 0 = nothing, 1 = boxes, 2 = triangles
	boxes: { Part },
	boxSig: { number },
	boxSize: { Vector3 },
	boxCF: { CFrame },
	tris: { [number]: TriRec },
	triCount: number,
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
		tileCells: number,
		tilesPerSide: number,
		usesFull: boolean,
		gridVersion: number,
		version: number,
		destroyed: boolean,
		folder: Folder,
		solid: Part?,
		solidSize: Vector3?,
		solidCF: CFrame?,
		tiles: { [number]: Tile },
		sampleKey: { number },
		sampleRest: { boolean }, -- per sample: untouched (cur == rest)? decides boxes vs triangles
		partCount: number,
		wedgeCount: number, -- of partCount, how many are triangle WedgeParts
		ox: number,
		oz: number,
		cellW: number,
		maxError: number,
		cliff: number,
		colors: { Color3 },
		style: Style,
	},
	ChunkParts
))

------------------------------------------------------------------ part pools
local boxPool: { Part } = {}
local wedgePool: { WedgePart } = {}

local function setupPart(p: BasePart, style: Style)
	p.Name = "Snow"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	-- parts made with Instance.new default to studded/inlet top and bottom surfaces
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = style.material
	if style.materialVariant ~= "" then
		p.MaterialVariant = style.materialVariant
	end
	p.CastShadow = style.castShadow
	p.Locked = true
end

local function takeBox(style: Style): Part
	ChunkParts.liveCount += 1
	local pooled = table.remove(boxPool)
	if pooled then
		-- the quality level may have turned shadows on/off since it was pooled
		if pooled.CastShadow ~= style.castShadow then
			pooled.CastShadow = style.castShadow
		end
		return pooled
	end
	local p = Instance.new("Part")
	setupPart(p, style)
	return p
end

local function takeWedge(style: Style): WedgePart
	ChunkParts.liveCount += 1
	local pooled = table.remove(wedgePool)
	if pooled then
		if pooled.CastShadow ~= style.castShadow then
			pooled.CastShadow = style.castShadow
		end
		return pooled
	end
	local p = Instance.new("WedgePart")
	setupPart(p, style)
	return p
end

local function releaseBox(p: Part)
	ChunkParts.liveCount -= 1
	if #boxPool < POOL_MAX then
		p.Parent = nil
		table.insert(boxPool, p)
	else
		p:Destroy()
	end
end

local function releaseWedge(p: WedgePart)
	ChunkParts.liveCount -= 1
	if #wedgePool < POOL_MAX then
		p.Parent = nil
		table.insert(wedgePool, p)
	else
		p:Destroy()
	end
end

--[[
	Creates Parts ahead of time (calls `budget`, which may yield, between batches) so that the
	first footprints never stall a frame creating Parts. Pooled Parts are not in the Workspace,
	so they cost nothing to render.
]]
function ChunkParts.prewarm(style: Style, boxes: number, wedges: number, budget: () -> ())
	local made = 0
	while #boxPool < boxes do
		local p = Instance.new("Part")
		setupPart(p, style)
		table.insert(boxPool, p)
		made += 1
		if made % 25 == 0 then
			budget()
		end
	end
	while #wedgePool < wedges do
		local p = Instance.new("WedgePart")
		setupPart(p, style)
		table.insert(wedgePool, p)
		made += 1
		if made % 25 == 0 then
			budget()
		end
	end
end

function ChunkParts.poolSize(): (number, number)
	return #boxPool, #wedgePool
end

-- CFrame changes of Parts that are already placed, applied in one BulkMoveTo call
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

local function place(p: BasePart, cf: CFrame, placed: boolean)
	if placed then
		table.insert(moveParts, p)
		table.insert(moveCFrames, cf)
	else
		p.CFrame = cf
	end
end

------------------------------------------------------------------ RTIN triangulation (Martini)
--[[
	For a (2^k + 1)^2 grid, every triangle of the right-triangle hierarchy is identified by its
	hypotenuse (a, b). Errors are accumulated bottom-up so that refining every triangle whose
	error is too big always gives a crack-free mesh inside the tile.
]]
type Rtin = { size: number, coords: { number }, numTriangles: number, numParent: number }
local rtinCache: { [number]: Rtin } = {}

local function rtinFor(size: number): Rtin
	local cached = rtinCache[size]
	if cached then
		return cached
	end
	local tileSize = size - 1
	local numTriangles = tileSize * tileSize * 2 - 2
	local numParent = numTriangles - tileSize * tileSize
	local coords: { number } = table.create(numTriangles * 4, 0)
	for i = 0, numTriangles - 1 do
		local id = i + 2
		local ax, ay, bx, by, cx, cy = 0, 0, 0, 0, 0, 0
		if id % 2 == 1 then
			bx, by, cx = tileSize, tileSize, tileSize -- bottom-left triangle
		else
			ax, ay, cy = tileSize, tileSize, tileSize -- top-right triangle
		end
		id //= 2
		while id > 1 do
			local mx, my = (ax + bx) // 2, (ay + by) // 2
			if id % 2 == 1 then -- left half
				bx, by = ax, ay
				ax, ay = cx, cy
			else -- right half
				ax, ay = bx, by
				bx, by = cx, cy
			end
			cx, cy = mx, my
			id //= 2
		end
		local k = i * 4
		coords[k + 1], coords[k + 2], coords[k + 3], coords[k + 4] = ax, ay, bx, by
	end
	local r: Rtin = { size = size, coords = coords, numTriangles = numTriangles, numParent = numParent }
	rtinCache[size] = r
	return r
end

-- scratch for one tile (max 17 x 17 samples); a tile is processed without yielding
local MAXG = (TILE + 1) * (TILE + 1)
local sH: { number } = table.create(MAXG, 0) -- drawn height (rounded cur)
local sKey: { number } = table.create(MAXG, 0) -- rounded height key
local sBase: { number } = table.create(MAXG, 0)
local sRest: { number } = table.create(MAXG, 0)
local sCur: { number } = table.create(MAXG, 0)
local sSnow: { boolean } = table.create(MAXG, false)
local errs: { number } = table.create(MAXG, 0)
local holes: { boolean } = table.create(MAXG, false)
local triOut: { number } = {} -- flat: ax, ay, bx, by, cx, cy
local triCount = 0

local function computeErrors(r: Rtin)
	local size = r.size
	local coords = r.coords
	for idx = 1, size * size do
		errs[idx] = 0
		holes[idx] = false
	end
	for i = r.numTriangles - 1, 0, -1 do
		local k = i * 4
		local ax, ay, bx, by = coords[k + 1], coords[k + 2], coords[k + 3], coords[k + 4]
		local mx, my = (ax + bx) // 2, (ay + by) // 2
		local cx, cy = mx + my - ay, my + ax - mx
		local ia, ib, ic, im = ay * size + ax + 1, by * size + bx + 1, cy * size + cx + 1, my * size + mx + 1
		local e = math.abs((sH[ia] + sH[ib]) * 0.5 - sH[im])
		if e > errs[im] then
			errs[im] = e
		end
		-- a triangle that touches "no snow" must be split down to the finest level
		if not (sSnow[ia] and sSnow[ib] and sSnow[ic] and sSnow[im]) then
			holes[im] = true
		end
		if i < r.numParent then
			local il = ((ay + cy) // 2) * size + (ax + cx) // 2 + 1
			local ir = ((by + cy) // 2) * size + (bx + cx) // 2 + 1
			if errs[il] > errs[im] then
				errs[im] = errs[il]
			end
			if errs[ir] > errs[im] then
				errs[im] = errs[ir]
			end
			if holes[il] or holes[ir] then
				holes[im] = true
			end
		end
	end
end

local function processTriangle(
	size: number,
	maxError: number,
	ax: number,
	ay: number,
	bx: number,
	by: number,
	cx: number,
	cy: number
)
	local mx, my = (ax + bx) // 2, (ay + by) // 2
	local im = my * size + mx + 1
	if math.abs(ax - cx) + math.abs(ay - cy) > 1 and (errs[im] > maxError or holes[im]) then
		processTriangle(size, maxError, cx, cy, ax, ay, mx, my)
		processTriangle(size, maxError, bx, by, cx, cy, mx, my)
	else
		local o = triCount * 6
		triOut[o + 1], triOut[o + 2], triOut[o + 3], triOut[o + 4], triOut[o + 5], triOut[o + 6] =
			ax, ay, bx, by, cx, cy
		triCount += 1
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

local function makeColors(style: Style): { Color3 }
	local c, t = style.color, style.packedTint
	local packedColor = Color3.new(c.R * t.R, c.G * t.G, c.B * t.B)
	local out = {}
	for l = 0, LEVELS - 1 do
		out[l + 1] = c:Lerp(packedColor, l / (LEVELS - 1))
	end
	return out
end

-- how pressed a sample is, 0 (fresh) .. 1 (packed)
local function packedAmount(base: number, rest: number, cur: number): number
	if cur >= rest - REST_EPS then
		return 0
	end
	local depth = rest - base
	if depth < 0.05 then
		depth = 0.05
	end
	return math.min(1, (rest - cur) / depth * 1.6)
end

local function triLevel(ia: number, ib: number, ic: number): number
	local p = (
		packedAmount(sBase[ia], sRest[ia], sCur[ia])
		+ packedAmount(sBase[ib], sRest[ib], sCur[ib])
		+ packedAmount(sBase[ic], sRest[ic], sCur[ic])
	) / 3
	return math.floor(p * (LEVELS - 1) + 0.5)
end

-- Two WedgeParts that together draw triangle (a, b, c), their top faces exactly on the triangle.
local function wedgeFrames(a: Vector3, b: Vector3, c: Vector3, thick: number?): (Vector3?, CFrame?, Vector3?, CFrame?)
	local t = thick or THICK
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	-- make bc the longest edge; a is then the corner opposite to it
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local normal = ac:Cross(ab)
	if normal.Magnitude < 1e-7 then
		return nil, nil, nil, nil
	end
	local right = normal.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	-- the wedges' thickness goes below the surface
	local down = (if right.Y >= 0 then right else -right) * (-t * 0.5)
	return Vector3.new(t, height, math.abs(ab:Dot(back))),
		CFrame.fromMatrix((a + b) * 0.5 + down, right, up, back),
		Vector3.new(t, height, math.abs(ac:Dot(back))),
		CFrame.fromMatrix((a + c) * 0.5 + down, -right, up, -back)
end
ChunkParts.wedgeFrames = wedgeFrames

------------------------------------------------------------------ tiles
local function newTile(): Tile
	return { kind = 0, boxes = {}, boxSig = {}, boxSize = {}, boxCF = {}, tris = {}, triCount = 0 }
end

local function releaseBoxes(self: ChunkParts, tile: Tile)
	for _, p in tile.boxes do
		releaseBox(p)
	end
	self.partCount -= #tile.boxes
	table.clear(tile.boxes)
	table.clear(tile.boxSig)
	table.clear(tile.boxSize)
	table.clear(tile.boxCF)
end

local function releaseTris(self: ChunkParts, tile: Tile)
	for _, rec in tile.tris do
		releaseWedge(rec.w1)
		releaseWedge(rec.w2)
	end
	self.partCount -= tile.triCount * 2
	self.wedgeCount -= tile.triCount * 2
	table.clear(tile.tris)
	tile.triCount = 0
end

--[[
	Reads the tile's samples into the scratch arrays. Returns the sample grid size and whether the
	tile has any snow, any pressed/raised snow, and only level untouched snow.
]]
--[[
	Reads one tile's samples into the scratch arrays. Returns the grid size, whether there is any
	snow, whether any of it is pressed, and how many snow levels it has (MAX_LEVELS + 1 = more).
]]
local levelKeys: { number } = {}
local function gather(self: ChunkParts, src: Source, ti: number, tj: number): (number, boolean, boolean, number)
	local g = self.tileCells + 1
	local i0, j0 = ti * self.tileCells, tj * self.tileCells
	local stride, n = src.stride, src.n
	local nS = self.nSide + 1
	local keyCache, restCache = self.sampleKey, self.sampleRest
	local any, deformed = false, false
	-- the distinct snow levels of the tile (rounded like drawn heights), up to MAX_LEVELS
	local nLevels = 0
	for y = 0, g - 1 do
		local cj = j0 + y
		local rowO = cj * stride * n
		for x = 0, g - 1 do
			local ci = i0 + x
			local o = (rowO + ci * stride) * 4
			local idx = y * g + x + 1
			local b = readf32(src.base, o)
			if b > NO_SNOW_LIMIT then
				local rest = readf32(src.rest, o)
				local cur = readf32(src.cur, o)
				local key = math.floor(cur / Q + 0.5)
				sSnow[idx] = true
				sBase[idx], sRest[idx], sCur[idx] = b, rest, cur
				sKey[idx] = key
				sH[idx] = key * Q
				keyCache[cj * nS + ci + 1] = key
				any = true
				local atRest = math.abs(cur - rest) <= REST_EPS
				restCache[cj * nS + ci + 1] = atRest
				if not atRest then
					deformed = true
				end
				if nLevels <= MAX_LEVELS then
					local rk = math.floor(rest / Q + 0.5)
					local known = false
					for k = 1, nLevels do
						if levelKeys[k] == rk then
							known = true
							break
						end
					end
					if not known then
						nLevels += 1
						levelKeys[nLevels] = rk
					end
				end
			else
				sSnow[idx] = false
				sH[idx] = 0
				keyCache[cj * nS + ci + 1] = NO_KEY
				restCache[cj * nS + ci + 1] = true
			end
		end
	end
	return g, any, deformed, nLevels
end

-- scratch for the box greedy merge
local cellKey: { number | boolean } = table.create(TILE * TILE, false)
local cellBase: { number } = table.create(TILE * TILE, 0)
local visited: { boolean } = table.create(TILE * TILE, false)
local rects: { number } = {}

-- Level, untouched snow: merge the snow cells (all four corners have snow) into boxes.
local sBySig: { [number]: number } = {}
local sClaimed: { [number]: boolean } = {}
local sAssign: { number } = {}
local sFree: { number } = {}
local sPendingSig: { number } = {}
local sPendingIdx: { number } = {}
local sSpare: { TriRec } = {}

local function buildBoxes(self: ChunkParts, tile: Tile, g: number, ti: number, tj: number)
	local w = g - 1
	for y = 0, w - 1 do
		for x = 0, w - 1 do
			local c = y * w + x + 1
			local i00 = y * g + x + 1
			local i10, i01, i11 = i00 + 1, i00 + g, i00 + g + 1
			if sSnow[i00] and sSnow[i10] and sSnow[i01] and sSnow[i11] then
				local hi = math.max(sKey[i00], sKey[i10], sKey[i01], sKey[i11])
				local lo = math.min(sKey[i00], sKey[i10], sKey[i01], sKey[i11])
				local bLo = math.min(sBase[i00], sBase[i10], sBase[i01], sBase[i11])
				local bHi = math.max(sBase[i00], sBase[i10], sBase[i01], sBase[i11])
				if bHi - bLo > self.cliff then
					cellKey[c] = false -- a cliff: never bridged (like the triangles)
				else
					-- a cell between two levels is drawn at the upper one (a clean step) and
					-- never merges with flat cells, whose boxes stay as shallow as their ground
					cellKey[c] = hi * 2 + (if hi ~= lo then 1 else 0)
					cellBase[c] = bLo
				end
			else
				cellKey[c] = false
			end
			visited[c] = false
		end
	end
	local count = 0
	for y = 0, w - 1 do
		for x = 0, w - 1 do
			local c = y * w + x + 1
			local k = cellKey[c]
			if k ~= false and not visited[c] then
				local rw = 1
				while x + rw < w and cellKey[c + rw] == k and not visited[c + rw] do
					rw += 1
				end
				local rh = 1
				while y + rh < w do
					local row = (y + rh) * w + x + 1
					local ok = true
					for t = 0, rw - 1 do
						if cellKey[row + t] ~= k or visited[row + t] then
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
				for yy = 0, rh - 1 do
					local row = (y + yy) * w + x + 1
					for t = 0, rw - 1 do
						visited[row + t] = true
						if cellBase[row + t] < minB then
							minB = cellBase[row + t]
						end
					end
				end
				local o = count * 6
				rects[o + 1], rects[o + 2], rects[o + 3], rects[o + 4], rects[o + 5], rects[o + 6] =
					x, y, rw, rh, k :: number, minB
				count += 1
			end
		end
	end

	-- keep boxes whose rectangle did not move, reuse the others
	-- (module-level scratch tables: a rebuild never yields, so they can be reused)
	local bySig = sBySig
	table.clear(bySig)
	for k, s in tile.boxSig do
		bySig[s] = k
	end
	local claimed = sClaimed
	table.clear(claimed)
	local assign = sAssign
	table.clear(assign)
	for r = 0, count - 1 do
		local o = r * 6
		local sig = rects[o + 1] + rects[o + 2] * 32 + rects[o + 3] * 1024 + rects[o + 4] * 32768
		local k = bySig[sig]
		if k and not claimed[k] then
			claimed[k] = true
			assign[r + 1] = k
		end
	end
	local free = sFree
	table.clear(free)
	for k = 1, #tile.boxes do
		if not claimed[k] then
			table.insert(free, k)
		end
	end
	local newBoxes: { Part } = table.create(count)
	local newSig: { number } = table.create(count, 0)
	local newSize: { Vector3 } = table.create(count)
	local newCF: { CFrame } = table.create(count)
	local cw = self.cellW
	local x0w, z0w = self.ox + ti * self.tileCells * cw, self.oz + tj * self.tileCells * cw
	for r = 0, count - 1 do
		local o = r * 6
		local rx, ry, rw, rh, key, minB =
			rects[o + 1], rects[o + 2], rects[o + 3], rects[o + 4], rects[o + 5], rects[o + 6]
		local top = (key // 2) * Q
		local bottom = minB - SINK
		if top - bottom < MIN_HEIGHT then
			bottom = top - MIN_HEIGHT
		end
		local sx, sz = rw * cw, rh * cw
		local size = Vector3.new(sx, top - bottom, sz)
		local cf = CFrame.new(x0w + rx * cw + sx * 0.5, (top + bottom) * 0.5, z0w + ry * cw + sz * 0.5)
		local k = assign[r + 1] or 0
		if k == 0 then
			k = table.remove(free) or 0
		end
		local p: Part, oldSize: Vector3?, oldCF: CFrame?
		if k ~= 0 then
			p, oldSize, oldCF = tile.boxes[k], tile.boxSize[k], tile.boxCF[k]
		else
			p = takeBox(self.style)
			p.Color = self.colors[1]
			self.partCount += 1
		end
		if oldSize ~= size then
			p.Size = size
		end
		if oldCF ~= cf then
			place(p, cf, oldCF ~= nil)
		end
		if oldCF == nil then
			p.Parent = self.folder
		end
		newBoxes[r + 1], newSize[r + 1], newCF[r + 1] = p, size, cf
		newSig[r + 1] = rx + ry * 32 + rw * 1024 + rh * 32768
	end
	flushMoves()
	for _, k in free do
		releaseBox(tile.boxes[k])
		self.partCount -= 1
	end
	tile.boxes, tile.boxSig, tile.boxSize, tile.boxCF = newBoxes, newSig, newSize, newCF
end

-- Anything that is not level untouched snow: a smooth triangle surface made of wedges.
local function buildTriangles(self: ChunkParts, tile: Tile, g: number, ti: number, tj: number)
	local r = rtinFor(g)
	computeErrors(r)
	triCount = 0
	local last = g - 1
	processTriangle(g, self.maxError, 0, 0, last, last, last, 0)
	processTriangle(g, self.maxError, last, last, 0, 0, 0, last)

	local cw = self.cellW
	local x0w, z0w = self.ox + ti * self.tileCells * cw, self.oz + tj * self.tileCells * cw
	local cliff = self.cliff
	local old = tile.tris
	local new: { [number]: TriRec } = {}
	local newCount = 0
	local pendingSig = sPendingSig
	table.clear(pendingSig)
	local pendingIdx = sPendingIdx
	table.clear(pendingIdx)
	local style, folder, colors = self.style, self.folder, self.colors

	local function vertex(x: number, y: number): Vector3
		return Vector3.new(x0w + x * cw, sH[y * g + x + 1], z0w + y * cw)
	end

	-- Near-flat triangles hang a slab down to the ground, so the snow has solid sides at its edges
	-- and at chunk borders, like the boxes. Steep ones (the walls of prints) stay thin.
	local function slab(ia: number, ib: number, ic: number, a: Vector3, b: Vector3, c: Vector3): number
		local n = (b - a):Cross(c - a)
		local len = n.Magnitude
		if len < 1e-9 then
			return THICK
		end
		local nY = math.abs(n.Y) / len
		if nY < 0.8 then
			return THICK
		end
		local depth = math.min(a.Y, b.Y, c.Y) - math.min(sBase[ia], sBase[ib], sBase[ic]) + SINK
		return math.max(THICK, depth * nY)
	end

	-- 1) keep triangles that still exist (only touched if a corner moved)
	for t = 0, triCount - 1 do
		local o = t * 6
		local ax, ay, bx, by, cx, cy =
			triOut[o + 1], triOut[o + 2], triOut[o + 3], triOut[o + 4], triOut[o + 5], triOut[o + 6]
		local ia, ib, ic = ay * g + ax + 1, by * g + bx + 1, cy * g + cx + 1
		if sSnow[ia] and sSnow[ib] and sSnow[ic] then
			-- skip triangles that bridge a cliff (a height jump of more than CliffHeight between
			-- neighbouring samples); big triangles on an even slope are fine
			local bl = math.min(sBase[ia], sBase[ib], sBase[ic])
			local bh = math.max(sBase[ia], sBase[ib], sBase[ic])
			local span = math.max(math.abs(ax - bx), math.abs(ay - by), math.abs(ax - cx), math.abs(ay - cy))
			if bh - bl <= cliff * span then
				local sig = ax + ay * 17 + bx * 289 + by * 4913 + cx * 83521 + cy * 1419857
				local rec = old[sig]
				if rec then
					old[sig] = nil
					local ka, kb, kc = sKey[ia], sKey[ib], sKey[ic]
					if rec.ka ~= ka or rec.kb ~= kb or rec.kc ~= kc then
						local va, vb, vc = vertex(ax, ay), vertex(bx, by), vertex(cx, cy)
						local s1, c1, s2, c2 = wedgeFrames(va, vb, vc, slab(ia, ib, ic, va, vb, vc))
						if s1 and c1 and s2 and c2 then
							rec.w1.Size, rec.w2.Size = s1, s2
							place(rec.w1, c1, true)
							place(rec.w2, c2, true)
						end
						rec.ka, rec.kb, rec.kc = ka, kb, kc
					end
					local level = triLevel(ia, ib, ic)
					if rec.level ~= level then
						rec.w1.Color, rec.w2.Color = colors[level + 1], colors[level + 1]
						rec.level = level
					end
					new[sig] = rec
					newCount += 1
				else
					table.insert(pendingSig, sig)
					table.insert(pendingIdx, t)
				end
			end
		end
	end

	-- 2) wedges of triangles that disappeared are reused for the new ones
	local spare = sSpare
	table.clear(spare)
	for _, rec in old do
		table.insert(spare, rec)
	end
	for k, sig in pendingSig do
		local o = pendingIdx[k] * 6
		local ax, ay, bx, by, cx, cy =
			triOut[o + 1], triOut[o + 2], triOut[o + 3], triOut[o + 4], triOut[o + 5], triOut[o + 6]
		local ia, ib, ic = ay * g + ax + 1, by * g + bx + 1, cy * g + cx + 1
		local va, vb, vc = vertex(ax, ay), vertex(bx, by), vertex(cx, cy)
		local s1, c1, s2, c2 = wedgeFrames(va, vb, vc, slab(ia, ib, ic, va, vb, vc))
		if s1 and c1 and s2 and c2 then
			local level = triLevel(ia, ib, ic)
			local rec = table.remove(spare)
			if rec then
				rec.w1.Size, rec.w2.Size = s1, s2
				place(rec.w1, c1, true)
				place(rec.w2, c2, true)
				if rec.level ~= level then
					rec.w1.Color, rec.w2.Color = colors[level + 1], colors[level + 1]
				end
			else
				local w1, w2 = takeWedge(style), takeWedge(style)
				self.partCount += 2
				self.wedgeCount += 2
				w1.Size, w2.Size = s1, s2
				w1.CFrame, w2.CFrame = c1, c2
				w1.Color, w2.Color = colors[level + 1], colors[level + 1]
				w1.Parent, w2.Parent = folder, folder
				rec = { w1 = w1, w2 = w2, ka = 0, kb = 0, kc = 0, level = level }
			end
			local done = rec :: TriRec
			done.ka, done.kb, done.kc, done.level = sKey[ia], sKey[ib], sKey[ic], level
			new[sig] = done
			newCount += 1
		end
	end
	flushMoves()
	for _, rec in spare do
		releaseWedge(rec.w1)
		releaseWedge(rec.w2)
		self.partCount -= 2
		self.wedgeCount -= 2
	end
	tile.tris = new
	tile.triCount = newCount
end

local function rebuildTile(self: ChunkParts, src: Source, ti: number, tj: number)
	local index = tj * self.tilesPerSide + ti
	local tile = self.tiles[index]
	if not tile then
		tile = newTile()
		self.tiles[index] = tile
	end
	local g, any, deformed, levels = gather(self, src, ti, tj)
	if not any then
		releaseBoxes(self, tile)
		releaseTris(self, tile)
		tile.kind = 0
	elseif not deformed and (levels <= 1 or (levels <= MAX_LEVELS and self.step <= 2)) then
		-- untouched snow: boxes. Steps between levels are drawn up to one cell past the higher
		-- part's edge, so only at fine detail (at coarse detail that would show)
		releaseTris(self, tile)
		tile.kind = 1
		buildBoxes(self, tile, g, ti, tj)
	else
		releaseBoxes(self, tile)
		tile.kind = 2
		buildTriangles(self, tile, g, ti, tj)
	end
end

------------------------------------------------------------------ whole chunk = one box
-- If every sample of the chunk is untouched snow at one level, returns its drawn height key and
-- the lowest ground. Also refreshes the sample key cache while scanning.
local function uniformChunk(self: ChunkParts, src: Source): (number?, number)
	local stride, n = src.stride, src.n
	local nS = self.nSide + 1
	local keyCache = self.sampleKey
	local key: number? = nil
	local restRef = 0
	local minB = math.huge
	for j = 0, self.nSide do
		local rowO = j * stride * n
		for i = 0, self.nSide do
			local o = (rowO + i * stride) * 4
			local b = readf32(src.base, o)
			if b <= NO_SNOW_LIMIT then
				return nil, 0
			end
			local rest, cur = readf32(src.rest, o), readf32(src.cur, o)
			if math.abs(cur - rest) > REST_EPS then
				return nil, 0
			end
			local k = math.floor(cur / Q + 0.5)
			keyCache[j * nS + i + 1] = k
			self.sampleRest[j * nS + i + 1] = true
			if key == nil then
				key, restRef = k, rest
			elseif math.abs(rest - restRef) > REST_EPS then
				return nil, 0
			end
			if b < minB then
				minB = b
			end
		end
	end
	return key, minB
end

local function clearSolid(self: ChunkParts)
	local p = self.solid
	if p then
		releaseBox(p)
		self.partCount -= 1
		self.solid = nil
		self.solidSize, self.solidCF = nil, nil
	end
end

local function setSolid(self: ChunkParts, key: number, minB: number)
	for _, tile in self.tiles do
		releaseBoxes(self, tile)
		releaseTris(self, tile)
	end
	table.clear(self.tiles)
	local top = key * Q
	local bottom = minB - SINK
	if top - bottom < MIN_HEIGHT then
		bottom = top - MIN_HEIGHT
	end
	local span = self.nSide * self.cellW
	local size = Vector3.new(span, top - bottom, span)
	local cf = CFrame.new(self.ox + span * 0.5, (top + bottom) * 0.5, self.oz + span * 0.5)
	local p = self.solid
	if not p then
		local np = takeBox(self.style)
		np.Color = self.colors[1]
		np.Size = size
		np.CFrame = cf
		np.Parent = self.folder
		self.solid, self.solidSize, self.solidCF = np, size, cf
		self.partCount += 1
		return
	end
	if self.solidSize ~= size then
		p.Size = size
		self.solidSize = size
	end
	if self.solidCF ~= cf then
		p.CFrame = cf
		self.solidCF = cf
	end
end

local function rebuildAll(self: ChunkParts, src: Source, budget: (() -> ())?)
	local key, minB = uniformChunk(self, src)
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
				if self.destroyed then
					return -- (destroyed while waiting for the next frame)
				end
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
	local tileCells = math.min(TILE, nSide)

	local self = setmetatable({
		step = step,
		nSide = nSide,
		tileCells = tileCells,
		tilesPerSide = nSide // tileCells,
		usesFull = chunk.full ~= nil,
		gridVersion = chunk.gridVersion,
		version = chunk.version,
		destroyed = false,
		folder = folder,
		solid = nil,
		solidSize = nil,
		solidCF = nil,
		tiles = {},
		sampleKey = table.create((nSide + 1) * (nSide + 1), NO_KEY),
		sampleRest = table.create((nSide + 1) * (nSide + 1), true),
		partCount = 0,
		wedgeCount = 0,
		ox = chunk.cx * C * S + NUDGE,
		oz = chunk.cz * C * S + NUDGE,
		cellW = step * S,
		-- lower detail levels tolerate a little more error
		maxError = math.max(0.005, style.smoothness) * math.sqrt(step),
		-- a jump between neighbouring samples is a cliff when it is taller than CliffHeight and
		-- steeper than snow can lie (coarse samples are far apart: a slope there is not a cliff)
		cliff = math.max(
			p.cliffHeight,
			step * S * math.sqrt(math.max(0, 1 - p.maxSlopeCos * p.maxSlopeCos)) / math.max(p.maxSlopeCos, 1e-3)
		),
		colors = makeColors(style),
		style = style,
	}, ChunkParts)

	rebuildAll(self, src, budget)
	folder.Parent = style.parent
	return self, nil
end

--[[
	New smoothness (the quality level changed): re-triangulates the triangle tiles in place.
	Boxes, and triangles that come out the same, are not touched; a chunk without triangles costs
	nothing. `budget` may yield between tiles.
]]
function ChunkParts.restyle(self: ChunkParts, chunk: SnowField.Chunk, smoothness: number, budget: (() -> ())?)
	local maxError = math.max(0.005, smoothness) * math.sqrt(self.step)
	if self.destroyed or maxError == self.maxError then
		return
	end
	self.maxError = maxError
	if self.wedgeCount == 0 then
		return
	end
	local src = sourceFor(chunk, self.step)
	if not src then
		return
	end
	local tps = self.tilesPerSide
	local list = {}
	for index, tile in self.tiles do
		if tile.kind == 2 then
			table.insert(list, index)
		end
	end
	for _, index in list do
		if self.destroyed then
			return
		end
		rebuildTile(self, src, index % tps, index // tps)
		if budget then
			budget()
		end
	end
end

-- Turns shadows on/off for every Part of this chunk.
function ChunkParts.setShadows(self: ChunkParts, on: boolean)
	if self.solid then
		self.solid.CastShadow = on
	end
	for _, tile in self.tiles do
		for _, p in tile.boxes do
			p.CastShadow = on
		end
		for _, rec in tile.tris do
			rec.w1.CastShadow = on
			rec.w2.CastShadow = on
		end
	end
end

function ChunkParts.destroy(self: ChunkParts)
	if self.destroyed then
		return
	end
	self.destroyed = true
	clearSolid(self)
	for _, tile in self.tiles do
		releaseBoxes(self, tile)
		releaseTris(self, tile)
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
	_tint: Color3,
	budget: (() -> ())?
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
		rebuildAll(self, src, budget)
		return
	end

	local sawChange = false
	if dirty then
		local n = full.n
		local step = self.step
		local tc, tps, nSide = self.tileCells, self.tilesPerSide, self.nSide
		local nS = nSide + 1
		local keyCache, restCache = self.sampleKey, self.sampleRest
		local marked: { [number]: boolean } = {}
		local any = false
		for i, flag in dirty do
			if flag == 1 then
				sawChange = true
				local lx, lz = i % n, i // n
				if lx % step == 0 and lz % step == 0 then
					local ci, cj = lx // step, lz // step
					local o = i * 4
					local key, atRest = NO_KEY, true
					if readf32(full.base, o) > NO_SNOW_LIMIT then
						local cur = readf32(full.cur, o)
						key = math.floor(cur / Q + 0.5)
						atRest = math.abs(cur - readf32(full.rest, o)) <= REST_EPS
					end
					local c = cj * nS + ci + 1
					-- only samples whose drawn height changed need their tiles rebuilt, or that
					-- became untouched again (the tile may turn back into boxes: the last bit of
					-- regrowing is too small to change the drawn height)
					if keyCache[c] ~= key or restCache[c] ~= atRest then
						keyCache[c] = key
						restCache[c] = atRest
						any = true
						-- a sample on a tile border belongs to up to four tiles
						local tiA, tjA = math.min(ci // tc, tps - 1), math.min(cj // tc, tps - 1)
						local tiB = if ci % tc == 0 and ci > 0 and ci < nSide then ci // tc - 1 else tiA
						local tjB = if cj % tc == 0 and cj > 0 and cj < nSide then cj // tc - 1 else tjA
						marked[tjA * tps + tiA] = true
						marked[tjA * tps + tiB] = true
						marked[tjB * tps + tiA] = true
						marked[tjB * tps + tiB] = true
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
		local key, minB = uniformChunk(self, src)
		if key then
			setSolid(self, key, minB)
		end
	end
end

return ChunkParts
