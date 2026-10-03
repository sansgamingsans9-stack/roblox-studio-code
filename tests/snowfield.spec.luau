--!strict
-- Unit tests for SnowField (run with tools/test.sh)
local T = require("./testlib")
local Shapes = require("./mods/Shapes")
local SnowField = require("./mods/SnowField")

local params: SnowField.Params = {
	cellSize = 0.5,
	chunkCells = 16,
	edgeFalloff = 1.5,
	minThickness = 0.06,
	cliffHeight = 3,
	maxSlopeCos = math.cos(math.rad(60)),
	rimRatio = 0.25,
	rimWidth = 0.75,
	regrowDelay = 2,
	regrowSpeed = 0.5,
	maxPendingPerChunk = 100,
}

-- One flat snow part: x,z in [0, 20], top at y = 10, snow depth 1
local function flatSampler(x: number, z: number): (number?, number, number)
	if x >= 0 and x <= 20 and z >= 0 and z <= 20 then
		return 10, 1, 1
	end
	return nil, 0, 0
end

local function noYield() end

local function buildField(): SnowField.SnowField
	local field = SnowField.new(params)
	field:addRegion(0, 20, 0, 20)
	for _, chunk in field.chunks do
		field:attachFull(chunk, field:sampleGrid(chunk, 1, flatSampler, noYield), 0)
	end
	return field
end

T.describe("sampling", function()
	local field = buildField()
	-- chunk span = 16 * 0.5 = 8 studs; region [0,20] touches chunks -1..2 on each axis
	T.eq(field.chunkCount, 16, "chunk count")
	local _, rest, cur = field:columnAt(10, 10)
	T.near(rest, 11, 1e-5, "interior rest = base + depth")
	T.near(cur, 11, 1e-5, "interior cur = rest")
	local base, edgeRest = field:columnAt(0, 10)
	T.near(base, 10, 1e-5, "edge base")
	T.near(edgeRest, 10.06, 1e-5, "edge thinned to min thickness")
	local _, midRest = field:columnAt(0.5, 10)
	T.ok(midRest > 10.06 and midRest < 11, "one cell in is partially thinned")
	local nothing = field:columnAt(-1, 10)
	T.eq(nothing, nil, "no snow outside the part")
end)

T.describe("stamping", function()
	local field = buildField()
	local foot = Shapes.new()
	-- 1 x 0.4 x 1.4 foot, bottom at y = 10.2 (0.8 deep into 1 stud of snow)
	Shapes.set(foot, Shapes.BOX, 10, 10.4, 10, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0.4, 1.4)
	local stats = SnowField.newStats()
	local changed = field:stamp(foot, 0, 1, stats)
	T.ok(changed, "stamp changed columns")
	local _, _, cur = field:columnAt(10, 10)
	T.near(cur, 10.2, 1e-5, "pressed to foot bottom")
	T.ok(stats.volume > 0 and stats.count > 0, "stats collected")
	T.near(stats.maxPen, 0.8, 1e-5, "max penetration")

	-- the lip next to the print rises above rest, but never more than rimRatio * depth
	local _, rest, rim = field:columnAt(10.5 + 0.5, 10)
	T.ok(rim > rest, `rim raised ({rim} > {rest})`)
	T.ok(rim <= rest + params.rimRatio * 1 + 1e-5, "rim bounded")

	-- standing still does not change anything any more
	T.ok(not field:stamp(foot, 0, 1.1, nil), "idempotent while standing still")

	-- a foot hovering above the snow does nothing
	local hover = Shapes.new()
	Shapes.set(hover, Shapes.BOX, 5, 12, 5, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0.4, 1.4)
	T.ok(not field:stamp(hover, 0, 1, nil), "hovering foot leaves no print")

	-- can never push below the part surface + min thickness
	local deep = Shapes.new()
	Shapes.set(deep, Shapes.BALL, 4, 9, 4, 1, 0, 0, 0, 1, 0, 0, 0, 1, 2, 2, 2)
	field:stamp(deep, 0, 1, nil)
	local _, _, floorCur = field:columnAt(4, 4)
	T.near(floorCur, 10.06, 1e-5, "clamped at minimum thickness")
end)

T.describe("chunk borders agree", function()
	local field = buildField()
	local ball = Shapes.new()
	-- straddles the border at x = 8 (between chunk 0 and chunk 1)
	Shapes.set(ball, Shapes.BALL, 8, 11.2, 4, 1, 0, 0, 0, 1, 0, 0, 0, 1, 2, 2, 2)
	field:stamp(ball, 0, 1, nil)
	local a = field:getChunk(0, 0) :: SnowField.Chunk
	local b = field:getChunk(1, 0) :: SnowField.Chunk
	local fa, fb = a.full :: SnowField.Full, b.full :: SnowField.Full
	local mismatches = 0
	for lz = 0, 16 do
		local va = buffer.readf32(fa.cur, (lz * fa.n + 16) * 4)
		local vb = buffer.readf32(fb.cur, (lz * fb.n + 0) * 4)
		if va ~= vb then
			mismatches += 1
		end
	end
	T.eq(mismatches, 0, "shared border column identical in both chunks")
	T.near(field:heightAt(16, 8) :: number, 10.2, 1e-5, "ball bottom on the border")
end)

T.describe("regrow", function()
	local field = buildField()
	local foot = Shapes.new()
	Shapes.set(foot, Shapes.BOX, 10, 10.4, 10, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0.4, 1.4)
	field:stamp(foot, 0, 0, nil)
	local chunk = field:getChunk(1, 1) :: SnowField.Chunk
	field:regrow(chunk, 1) -- still inside the delay
	local _, _, cur = field:columnAt(10, 10)
	T.near(cur, 10.2, 1e-5, "no regrow during delay")
	field:regrow(chunk, 3) -- 2s later, 0.5 studs/s -> +1 stud max
	local _, rest, cur2 = field:columnAt(10, 10)
	T.near(cur2, rest, 1e-5, "fully regrown")
	-- the whole chunk returns to rest eventually
	field:regrow(chunk, 10)
	T.eq((chunk.full :: SnowField.Full).activeCount, 0, "nothing left regrowing")
end)

T.describe("queued history prints", function()
	local field = SnowField.new(params)
	field:addRegion(0, 20, 0, 20)
	local old = Shapes.new()
	Shapes.set(old, Shapes.BOX, 10, 10.4, 10, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0.4, 1.4)
	-- made 2.4s ago: 0.4s past the delay -> regrown by 0.2
	field:queueStamp(old, 100, 97.6)
	local chunk = field:getChunk(1, 1) :: SnowField.Chunk
	T.ok(chunk.pending ~= nil and #(chunk.pending :: { any }) == 1, "queued while not simulated")
	field:attachFull(chunk, field:sampleGrid(chunk, 1, flatSampler, noYield), 100)
	local _, _, cur = field:columnAt(10, 10)
	T.near(cur, 10.4, 1e-4, "replayed with partial regrow")
	T.eq(chunk.pending, nil, "queue consumed")
end)

T.describe("resample keeps prints", function()
	local field = buildField()
	local foot = Shapes.new()
	Shapes.set(foot, Shapes.BOX, 10, 10.4, 10, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0.4, 1.4)
	field:stamp(foot, 0, 5, nil)
	local chunk = field:getChunk(1, 1) :: SnowField.Chunk
	local raised = function(x: number, z: number): (number?, number, number)
		local y, ny, d = flatSampler(x, z)
		if y then
			return y + 2, ny, d
		end
		return nil, ny, d
	end
	field:attachFull(chunk, field:sampleGrid(chunk, 1, raised, noYield), 6)
	local _, rest, cur = field:columnAt(10, 10)
	T.near(rest, 13, 1e-5, "new rest")
	T.near(cur, 12.2, 1e-5, "print depth carried over")
end)

T.describe("cliffs and slopes", function()
	-- a 6-stud tall snow block on top of snowy ground: the block top must thin out at its edge
	local function blockSampler(x: number, z: number): (number?, number, number)
		if x >= 4 and x <= 8 and z >= 4 and z <= 8 then
			return 16, 1, 1
		end
		if x >= 0 and x <= 20 and z >= 0 and z <= 20 then
			return 10, 1, 1
		end
		return nil, 0, 0
	end
	local field = SnowField.new(params)
	field:addRegion(0, 20, 0, 20)
	for _, chunk in field.chunks do
		field:attachFull(chunk, field:sampleGrid(chunk, 1, blockSampler, noYield), 0)
	end
	local _, topEdge = field:columnAt(4, 6)
	T.near(topEdge, 16.06, 1e-5, "block top thins at the cliff edge")
	local _, topMid = field:columnAt(6, 6)
	T.near(topMid, 17, 1e-5, "block top centre full depth")

	local function steep(x: number, z: number): (number?, number, number)
		return 10, math.cos(math.rad(75)), 1
	end
	local f2 = SnowField.new(params)
	f2:addRegion(0, 4, 0, 4)
	for _, chunk in f2.chunks do
		local g = f2:sampleGrid(chunk, 1, steep, noYield)
		T.eq(g.snowCount, 0, "75 degree slope holds no snow")
	end
end)

T.describe("coarse grids", function()
	local field = SnowField.new(params)
	field:addRegion(0, 20, 0, 20)
	local chunk = field:getChunk(1, 1) :: SnowField.Chunk
	local g = field:sampleGrid(chunk, 4, flatSampler, noYield)
	T.eq(g.n, 5, "16 cells / step 4 + 1")
	field:attachCoarse(chunk, g)
	T.near(field:heightAt(20, 20) :: number, 11, 1e-5, "coarse height at aligned column")
	T.eq(field:heightAt(21, 20), nil, "unaligned column has no coarse data")
end)

return T.finish("snowfield")
