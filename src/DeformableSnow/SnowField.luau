--!strict
--[[
	SnowField
	The snow simulation itself: a sparse, chunked, world-aligned heightfield.

	* Columns sit on a global grid (column gx is at world X = gx * CellSize).
	* A chunk owns columns [cx*C, cx*C + C] on each axis (the last row/column is shared with the
	  next chunk so every chunk can be meshed on its own).
	* Each column stores:
	    base - the top of the snow part under it (the "ground")
	    rest - where the untouched snow surface is (base + snow depth, thinned near edges/slopes)
	    cur  - where the snow surface is right now (pushed down by feet, pushed up into rims)
	    hit  - last time something pressed on it (snow only regrows after RegrowDelay)

	No Roblox APIs are used here: surface sampling is injected as a function so this module can be
	unit-tested with the plain `luau` CLI.
]]

local Shapes = require(script.Parent.Shapes)

type Shape = Shapes.Shape

local readf32 = buffer.readf32
local writef32 = buffer.writef32
local lowestAt = Shapes.lowestAt
local footprintDistance = Shapes.footprintDistance

local NO_SNOW = -1e30
local NO_SNOW_LIMIT = -1e29
local EPS = 1e-3
local CONTACT_EPS = 0.05
local INF = 1e9
local SQRT2 = math.sqrt(2)

local SnowField = {}
SnowField.__index = SnowField

SnowField.NO_SNOW = NO_SNOW
SnowField.NO_SNOW_LIMIT = NO_SNOW_LIMIT

export type Params = {
	cellSize: number,
	chunkCells: number,
	edgeFalloff: number,
	minThickness: number,
	cliffHeight: number,
	maxSlopeCos: number,
	rimRatio: number,
	rimWidth: number,
	regrowDelay: number,
	regrowSpeed: number,
	maxPendingPerChunk: number,
	-- queued prints older than this (seconds) have regrown and are dropped (nil = keep)
	maxPendingAge: number?,
}

-- (x, z) -> surfaceY (nil = no snow part here), surface normal Y, snow depth for that part
export type Sampler = (x: number, z: number) -> (number?, number, number)

export type Grid = {
	step: number,
	n: number,
	base: buffer,
	rest: buffer,
	minY: number,
	maxY: number,
	snowCount: number,
}

export type Full = {
	step: number,
	n: number,
	base: buffer,
	rest: buffer,
	cur: buffer,
	hit: buffer,
	minY: number,
	maxY: number,
	snowCount: number,
	active: { [number]: boolean },
	activeCount: number,
	lastRegrow: number,
}

export type Pending = {
	shape: Shape,
	hitTime: number,
}

export type Chunk = {
	cx: number,
	cz: number,
	key: number,
	refs: number,
	full: Full?,
	coarse: { [number]: Grid },
	gridVersion: number,
	dirty: { [number]: number },
	dirtyCount: number,
	version: number,
	stale: boolean,
	pending: { Pending }?,
	lastNeeded: number,
	render: any,
}

export type Stats = {
	volume: number,
	maxPen: number,
	sumX: number,
	sumY: number,
	sumZ: number,
	count: number,
}

export type SnowField = typeof(setmetatable(
	{} :: {
		params: Params,
		chunks: { [number]: Chunk },
		chunkCount: number,
		-- prints for chunks that do not exist (yet): their snow parts have not streamed in
		orphans: { [number]: { Pending } },
	},
	SnowField
))

local function smoothstep(e0: number, e1: number, x: number): number
	if e1 <= e0 then
		return if x >= e0 then 1 else 0
	end
	local t = (x - e0) / (e1 - e0)
	if t <= 0 then
		return 0
	elseif t >= 1 then
		return 1
	end
	return t * t * (3 - 2 * t)
end
SnowField.smoothstep = smoothstep

function SnowField.chunkKey(cx: number, cz: number): number
	return (cx + 32768) * 65536 + (cz + 32768)
end

function SnowField.newStats(): Stats
	return { volume = 0, maxPen = 0, sumX = 0, sumY = 0, sumZ = 0, count = 0 }
end

function SnowField.resetStats(st: Stats)
	st.volume, st.maxPen, st.sumX, st.sumY, st.sumZ, st.count = 0, 0, 0, 0, 0, 0
end

function SnowField.new(params: Params): SnowField
	assert(params.chunkCells % 8 == 0, "ChunkCells must be a multiple of 8")
	local self = setmetatable({
		params = params,
		chunks = {},
		chunkCount = 0,
		orphans = {},
	}, SnowField)
	return self
end

-- Chunk index range [c0, c1] whose columns touch the world interval [a, b].
function SnowField.chunkRange(self: SnowField, a: number, b: number): (number, number)
	local span = self.params.chunkCells * self.params.cellSize
	return math.ceil(a / span) - 1, math.floor(b / span)
end

function SnowField.getChunk(self: SnowField, cx: number, cz: number): Chunk?
	return self.chunks[SnowField.chunkKey(cx, cz)]
end

-- World-space centre (x, z) of a chunk.
function SnowField.chunkCenter(self: SnowField, chunk: Chunk): (number, number)
	local p = self.params
	local half = p.chunkCells * 0.5
	return (chunk.cx * p.chunkCells + half) * p.cellSize, (chunk.cz * p.chunkCells + half) * p.cellSize
end

--[[
	Region bookkeeping: each snow part references the chunks under its bounding box.
	Returns the keys so the caller can release them later.
]]
function SnowField.addRegion(self: SnowField, minX: number, maxX: number, minZ: number, maxZ: number): { number }
	local keys = {}
	local cx0, cx1 = self:chunkRange(minX, maxX)
	local cz0, cz1 = self:chunkRange(minZ, maxZ)
	for cz = cz0, cz1 do
		for cx = cx0, cx1 do
			local key = SnowField.chunkKey(cx, cz)
			local chunk = self.chunks[key]
			if not chunk then
				chunk = {
					cx = cx,
					cz = cz,
					key = key,
					refs = 0,
					full = nil,
					coarse = {},
					gridVersion = 0,
					dirty = {},
					dirtyCount = 0,
					version = 0,
					stale = false,
					-- prints that arrived before this chunk's snow part did
					pending = self.orphans[key],
					lastNeeded = -math.huge,
					render = nil,
				}
				self.orphans[key] = nil
				self.chunks[key] = chunk
				self.chunkCount += 1
			end
			chunk.refs += 1
			table.insert(keys, key)
		end
	end
	return keys
end

-- Releases keys from addRegion. Returns chunks that no longer have any snow part over them.
function SnowField.removeRegion(self: SnowField, keys: { number }): { Chunk }
	local removed = {}
	for _, key in keys do
		local chunk = self.chunks[key]
		if chunk then
			chunk.refs -= 1
			if chunk.refs <= 0 then
				self.chunks[key] = nil
				self.chunkCount -= 1
				table.insert(removed, chunk)
			end
		end
	end
	return removed
end

-- Flags every existing chunk near a world rectangle for re-sampling (a snow part moved/changed).
function SnowField.markStale(self: SnowField, minX: number, maxX: number, minZ: number, maxZ: number)
	local m = self.params.edgeFalloff + self.params.cellSize * 2
	local cx0, cx1 = self:chunkRange(minX - m, maxX + m)
	local cz0, cz1 = self:chunkRange(minZ - m, maxZ + m)
	for cz = cz0, cz1 do
		for cx = cx0, cx1 do
			local chunk = self.chunks[SnowField.chunkKey(cx, cz)]
			if chunk then
				chunk.stale = true
			end
		end
	end
end

--[[
	Samples the rest surface of a chunk at a given LOD step (1 = every column).
	`sampler` is called for every column plus an apron around the chunk (so edge thinning is
	identical on both sides of a chunk border). `budget` is called once per row and may yield.
]]
function SnowField.sampleGrid(self: SnowField, chunk: Chunk, step: number, sampler: Sampler, budget: () -> ()): Grid
	local p = self.params
	local C, S = p.chunkCells, p.cellSize
	local n = C // step + 1
	local cellW = S * step
	local A = if p.edgeFalloff > 0 then math.ceil(p.edgeFalloff / cellW) + 1 else 1
	local W = n + 2 * A
	local ox, oz = chunk.cx * C, chunk.cz * C
	local maxSlopeCos = p.maxSlopeCos

	local baseE: { number } = table.create(W * W, NO_SNOW)
	local thickE: { number } = table.create(W * W, 0)

	for ez = 0, W - 1 do
		local wz = (oz + (ez - A) * step) * S
		local row = ez * W
		for ex = 0, W - 1 do
			local wx = (ox + (ex - A) * step) * S
			local y, ny, depth = sampler(wx, wz)
			if y and depth > 0 then
				local slope = smoothstep(maxSlopeCos, maxSlopeCos + 0.12, ny)
				if slope > 0 then
					baseE[row + ex + 1] = y
					thickE[row + ex + 1] = depth * slope
				end
			end
		end
		budget()
	end

	-- Distance (in cells) to the nearest edge of the snow: empty columns or tall cliffs.
	local dist: { number } = table.create(W * W, INF)
	local cliff = p.cliffHeight
	for ez = 0, W - 1 do
		local row = ez * W
		for ex = 0, W - 1 do
			local e = row + ex + 1
			local b = baseE[e]
			if b <= NO_SNOW_LIMIT then
				dist[e] = 0
			else
				local seed = false
				if ex > 0 then
					local nb = baseE[e - 1]
					seed = nb <= NO_SNOW_LIMIT or math.abs(nb - b) > cliff
				end
				if not seed and ex < W - 1 then
					local nb = baseE[e + 1]
					seed = nb <= NO_SNOW_LIMIT or math.abs(nb - b) > cliff
				end
				if not seed and ez > 0 then
					local nb = baseE[e - W]
					seed = nb <= NO_SNOW_LIMIT or math.abs(nb - b) > cliff
				end
				if not seed and ez < W - 1 then
					local nb = baseE[e + W]
					seed = nb <= NO_SNOW_LIMIT or math.abs(nb - b) > cliff
				end
				if seed then
					dist[e] = 0.5
				end
			end
		end
	end
	-- two-pass chamfer distance transform
	for ez = 0, W - 1 do
		local row = ez * W
		for ex = 0, W - 1 do
			local e = row + ex + 1
			local d = dist[e]
			if d > 0 then
				if ex > 0 and dist[e - 1] + 1 < d then
					d = dist[e - 1] + 1
				end
				if ez > 0 then
					if dist[e - W] + 1 < d then
						d = dist[e - W] + 1
					end
					if ex > 0 and dist[e - W - 1] + SQRT2 < d then
						d = dist[e - W - 1] + SQRT2
					end
					if ex < W - 1 and dist[e - W + 1] + SQRT2 < d then
						d = dist[e - W + 1] + SQRT2
					end
				end
				dist[e] = d
			end
		end
	end
	for ez = W - 1, 0, -1 do
		local row = ez * W
		for ex = W - 1, 0, -1 do
			local e = row + ex + 1
			local d = dist[e]
			if d > 0 then
				if ex < W - 1 and dist[e + 1] + 1 < d then
					d = dist[e + 1] + 1
				end
				if ez < W - 1 then
					if dist[e + W] + 1 < d then
						d = dist[e + W] + 1
					end
					if ex < W - 1 and dist[e + W + 1] + SQRT2 < d then
						d = dist[e + W + 1] + SQRT2
					end
					if ex > 0 and dist[e + W - 1] + SQRT2 < d then
						d = dist[e + W - 1] + SQRT2
					end
				end
				dist[e] = d
			end
		end
	end

	local base = buffer.create(n * n * 4)
	local rest = buffer.create(n * n * 4)
	local minY, maxY, count = math.huge, -math.huge, 0
	local falloff = p.edgeFalloff
	local minT = p.minThickness
	local rimRatio = p.rimRatio
	for lz = 0, n - 1 do
		for lx = 0, n - 1 do
			local e = (lz + A) * W + (lx + A) + 1
			local o = (lz * n + lx) * 4
			local b = baseE[e]
			if b > NO_SNOW_LIMIT then
				local taper = if falloff > 0 then smoothstep(0, falloff, (dist[e] - 0.5) * cellW) else 1
				local th = math.max(minT, thickE[e] * taper)
				writef32(base, o, b)
				writef32(rest, o, b + th)
				count += 1
				if b < minY then
					minY = b
				end
				local top = b + th * (1 + rimRatio)
				if top > maxY then
					maxY = top
				end
			else
				writef32(base, o, NO_SNOW)
				writef32(rest, o, NO_SNOW)
			end
		end
	end
	if count == 0 then
		minY, maxY = 0, 0
	end

	return {
		step = step,
		n = n,
		base = base,
		rest = rest,
		minY = minY,
		maxY = maxY,
		snowCount = count,
	}
end

local function markDirty(chunk: Chunk, i: number)
	if chunk.dirty[i] ~= 1 then
		if chunk.dirty[i] == nil then
			chunk.dirtyCount += 1
		end
		chunk.dirty[i] = 1
	end
	chunk.version += 1
end
SnowField.markDirty = markDirty

-- Low-resolution rest surface used to draw far-away chunks that are not simulated.
function SnowField.attachCoarse(self: SnowField, chunk: Chunk, grid: Grid)
	chunk.coarse[grid.step] = grid
	if not chunk.full then
		chunk.gridVersion += 1
	end
end

--[[
	Makes a chunk deformable using a step-1 grid. If the chunk was already simulated (re-sample after
	a part moved) existing prints/rims are carried over relative to the new rest surface.
]]
function SnowField.attachFull(self: SnowField, chunk: Chunk, grid: Grid, now: number, budget: (() -> ())?)
	assert(grid.step == 1, "full grids must be sampled at step 1")
	local p = self.params
	local count = grid.n * grid.n
	local cur = buffer.create(count * 4)
	buffer.copy(cur, 0, grid.rest, 0, count * 4)
	local hit = buffer.create(count * 4)
	local full: Full = {
		step = 1,
		n = grid.n,
		base = grid.base,
		rest = grid.rest,
		cur = cur,
		hit = hit,
		minY = grid.minY,
		maxY = grid.maxY,
		snowCount = grid.snowCount,
		active = {},
		activeCount = 0,
		lastRegrow = now,
	}

	local old = chunk.full
	if old and old.n == full.n and old.activeCount > 0 then
		local minT = p.minThickness
		for i in old.active do
			local o = i * 4
			local nb = readf32(full.base, o)
			if nb > NO_SNOW_LIMIT then
				local delta = readf32(old.cur, o) - readf32(old.rest, o)
				local nr = readf32(full.rest, o)
				local v = nr + delta
				if v < nb + minT then
					v = nb + minT
				end
				local maxRim = nr + (nr - nb) * p.rimRatio
				if v > maxRim then
					v = maxRim
				end
				writef32(cur, o, v)
				writef32(hit, o, readf32(old.hit, o))
				if math.abs(v - nr) > EPS * 0.5 then
					full.active[i] = true
					full.activeCount += 1
				end
			end
		end
	end

	chunk.full = full
	chunk.gridVersion += 1
	chunk.version += 1

	local pending = chunk.pending
	if pending then
		chunk.pending = nil
		-- (other players' prints made while it was not simulated; `budget` may yield in between)
		local maxAge = p.maxPendingAge
		for k, item in pending do
			if not maxAge or now - item.hitTime <= maxAge then
				self:stampAged(item.shape, now, item.hitTime, chunk)
			end
			if budget and k % 32 == 0 then
				budget()
				if chunk.full ~= full then
					return -- dropped or re-sampled meanwhile
				end
			end
		end
	end
end

-- Forgets the simulation of a chunk (only call when it has nothing left to regrow).
function SnowField.dropFull(self: SnowField, chunk: Chunk)
	if chunk.full then
		chunk.full = nil
		chunk.gridVersion += 1
	end
end

function SnowField.clearGrids(self: SnowField, chunk: Chunk)
	chunk.coarse = {}
	chunk.gridVersion += 1
end

--[[
	Presses a shape into the snow.
	  raise    - lifts the result (used to replay old prints that have partially regrown)
	  hitTime  - the time stored as "last pressed"
	  only     - restrict to one chunk (used when replaying queued prints)
	Returns true if any column changed.
]]
function SnowField.stamp(
	self: SnowField,
	s: Shape,
	raise: number,
	hitTime: number,
	stats: Stats?,
	only: Chunk?
): boolean
	local p = self.params
	local S, C = p.cellSize, p.chunkCells
	local rimW = if p.rimRatio > 0 then p.rimWidth else 0
	local rimRatio = p.rimRatio
	local minT = p.minThickness

	local gx0 = math.ceil((s.minX - rimW) / S)
	local gx1 = math.floor((s.maxX + rimW) / S)
	local gz0 = math.ceil((s.minZ - rimW) / S)
	local gz1 = math.floor((s.maxZ + rimW) / S)
	if gx1 < gx0 or gz1 < gz0 then
		return false
	end

	local cx0, cx1, cz0, cz1
	if only then
		cx0, cx1, cz0, cz1 = only.cx, only.cx, only.cz, only.cz
	else
		cx0, cx1 = math.ceil(gx0 / C) - 1, math.floor(gx1 / C)
		cz0, cz1 = math.ceil(gz0 / C) - 1, math.floor(gz1 / C)
	end

	local changed = false
	local sMinY = s.minY
	local chunks = self.chunks

	for cz = cz0, cz1 do
		for cx = cx0, cx1 do
			local chunk = if only then only else chunks[SnowField.chunkKey(cx, cz)]
			local full = chunk and chunk.full
			if chunk and full and sMinY < full.maxY then
				local n = full.n
				local ox, oz = cx * C, cz * C
				local lx0, lx1 = math.max(0, gx0 - ox), math.min(C, gx1 - ox)
				local lz0, lz1 = math.max(0, gz0 - oz), math.min(C, gz1 - oz)
				local baseB, restB, curB, hitB = full.base, full.rest, full.cur, full.hit
				local active = full.active

				for lz = lz0, lz1 do
					local wz = (oz + lz) * S
					local row = lz * n
					for lx = lx0, lx1 do
						local i = row + lx
						local o = i * 4
						local base = readf32(baseB, o)
						if base > NO_SNOW_LIMIT then
							local wx = (ox + lx) * S
							local cur = readf32(curB, o)
							local y = lowestAt(s, wx, wz)
							local handled = false

							if y then
								local target = y + raise
								local floorY = base + minT
								if target < floorY then
									target = floorY
								end
								if target < cur - EPS then
									-- press the snow down
									writef32(curB, o, target)
									if hitTime > readf32(hitB, o) then
										writef32(hitB, o, hitTime)
									end
									if not active[i] then
										active[i] = true
										full.activeCount += 1
									end
									markDirty(chunk, i)
									changed = true
									handled = true
									if stats then
										local pen = cur - target
										stats.volume += pen
										if pen > stats.maxPen then
											stats.maxPen = pen
										end
										stats.sumX += wx
										stats.sumY += target
										stats.sumZ += wz
										stats.count += 1
									end
								elseif y <= cur + CONTACT_EPS then
									-- resting inside an existing print: keep it from regrowing
									if hitTime > readf32(hitB, o) then
										writef32(hitB, o, hitTime)
									end
									handled = true
								end
							end

							if not handled and rimRatio > 0 then
								-- push up a little lip of snow around the print
								local rest = readf32(restB, o)
								if cur >= rest - EPS then
									local pen = rest - sMinY
									if pen > 0 then
										local depth = rest - base
										if pen > depth then
											pen = depth
										end
										local d = footprintDistance(s, wx, wz)
										if d < 0 then
											d = 0
										end
										if d < rimW then
											local f = 1 - d / rimW
											local h = rimRatio * pen * f * f - raise
											if h > 0 then
												local target = rest + h
												if y and target > y + raise then
													target = y + raise
												end
												if target > cur + EPS then
													writef32(curB, o, target)
													if hitTime > readf32(hitB, o) then
														writef32(hitB, o, hitTime)
													end
													if not active[i] then
														active[i] = true
														full.activeCount += 1
													end
													markDirty(chunk, i)
													changed = true
												elseif target > cur - CONTACT_EPS and hitTime > readf32(hitB, o) then
													-- still being pushed up: keep the lip from settling
													writef32(hitB, o, hitTime)
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end
	return changed
end

-- Replays a print made at `hitTime` (in the local clock): older prints come back partially regrown.
function SnowField.stampAged(self: SnowField, s: Shape, now: number, hitTime: number, only: Chunk?): boolean
	local p = self.params
	local raise = 0
	if p.regrowSpeed > 0 then
		raise = math.max(0, now - hitTime - p.regrowDelay) * p.regrowSpeed
	end
	return self:stamp(s, raise, hitTime, nil, only)
end

--[[
	Queues a print for chunks that are not simulated yet (late-join history / far away players) and
	applies it right away where the chunk is simulated.
]]
-- Adds a queued print, dropping regrown (too old) ones and keeping at most maxPendingPerChunk.
local function pushPending(p: Params, list: { Pending }, item: Pending, now: number)
	table.insert(list, item)
	local n = #list
	if n <= p.maxPendingPerChunk and n % 64 ~= 0 then
		return
	end
	-- (in batches: never shift the whole list for every new print)
	local maxAge = p.maxPendingAge
	local drop = 0
	if maxAge then
		while drop < n and now - list[drop + 1].hitTime > maxAge do
			drop += 1
		end
	end
	if n - drop > p.maxPendingPerChunk then
		drop = n - p.maxPendingPerChunk + p.maxPendingPerChunk // 4
	end
	if drop > 0 then
		table.move(list, drop + 1, n, 1)
		for i = n - drop + 1, n do
			list[i] = nil
		end
	end
end

-- Forgets prints for chunks that never appeared once they have regrown anyway.
function SnowField.pruneOrphans(self: SnowField, now: number)
	local maxAge = self.params.maxPendingAge
	if not maxAge then
		return
	end
	for key, list in self.orphans do
		local last = list[#list]
		if not last or now - last.hitTime > maxAge then
			self.orphans[key] = nil
		end
	end
end

function SnowField.queueStamp(self: SnowField, s: Shape, now: number, hitTime: number)
	local p = self.params
	local rimW = p.rimWidth
	local cx0, cx1 = self:chunkRange(s.minX - rimW, s.maxX + rimW)
	local cz0, cz1 = self:chunkRange(s.minZ - rimW, s.maxZ + rimW)
	for cz = cz0, cz1 do
		for cx = cx0, cx1 do
			local key = SnowField.chunkKey(cx, cz)
			local chunk = self.chunks[key]
			if chunk and chunk.full then
				self:stampAged(s, now, hitTime, chunk)
			elseif chunk then
				local list: { Pending } = chunk.pending or {}
				chunk.pending = list
				pushPending(p, list, { shape = s, hitTime = hitTime }, now)
			else
				local list = self.orphans[key] or {}
				self.orphans[key] = list
				pushPending(p, list, { shape = s, hitTime = hitTime }, now)
			end
		end
	end
end

--[[
	Lets pressed snow slowly fill back in (and rims settle back down).
	Returns the number of columns still regrowing.
]]
function SnowField.regrow(self: SnowField, chunk: Chunk, now: number): number
	local full = chunk.full
	if not full then
		return 0
	end
	local dt = now - full.lastRegrow
	full.lastRegrow = now
	local p = self.params
	if full.activeCount == 0 or p.regrowSpeed <= 0 or dt <= 0 then
		return full.activeCount
	end
	local amount = p.regrowSpeed * dt
	local delay = p.regrowDelay
	local curB, restB, hitB = full.cur, full.rest, full.hit
	local active = full.active
	for i in active do
		local o = i * 4
		if now - readf32(hitB, o) >= delay then
			local cur = readf32(curB, o)
			local rest = readf32(restB, o)
			local v
			if cur < rest then
				v = cur + amount
				if v > rest then
					v = rest
				end
			else
				v = cur - amount
				if v < rest then
					v = rest
				end
			end
			writef32(curB, o, v)
			markDirty(chunk, i)
			if v == rest then
				active[i] = nil
				full.activeCount -= 1
			end
		end
	end
	return full.activeCount
end

--[[
	Current surface height of a global column, or nil if there is no snow / no data there.
	Falls back to a coarse grid when the chunk is not simulated.
]]
function SnowField.heightAt(self: SnowField, gx: number, gz: number): number?
	local C = self.params.chunkCells
	local cx, cz = gx // C, gz // C
	local chunk = self.chunks[SnowField.chunkKey(cx, cz)]
	if not chunk then
		return nil
	end
	local lx, lz = gx - cx * C, gz - cz * C
	local full = chunk.full
	if full then
		local o = (lz * full.n + lx) * 4
		if readf32(full.base, o) <= NO_SNOW_LIMIT then
			return nil
		end
		return readf32(full.cur, o)
	end
	for step, grid in chunk.coarse do
		if lx % step == 0 and lz % step == 0 then
			local o = ((lz // step) * grid.n + lx // step) * 4
			if readf32(grid.base, o) <= NO_SNOW_LIMIT then
				return nil
			end
			return readf32(grid.rest, o)
		end
	end
	return nil
end

-- Untouched snow depth info at a world point (nearest column): base, rest, cur.
function SnowField.columnAt(self: SnowField, x: number, z: number): (number?, number, number)
	local p = self.params
	local gx = math.floor(x / p.cellSize + 0.5)
	local gz = math.floor(z / p.cellSize + 0.5)
	local C = p.chunkCells
	local cx, cz = gx // C, gz // C
	local chunk = self.chunks[SnowField.chunkKey(cx, cz)]
	local full = chunk and chunk.full
	if not full then
		return nil, 0, 0
	end
	local o = ((gz - cz * C) * full.n + (gx - cx * C)) * 4
	local base = readf32(full.base, o)
	if base <= NO_SNOW_LIMIT then
		return nil, 0, 0
	end
	return base, readf32(full.rest, o), readf32(full.cur, o)
end

return SnowField
