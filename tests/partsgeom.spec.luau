--!nocheck
-- Geometry of the Parts renderer on its own (run with tools/test.sh):
-- tiling at every detail level, no gaps on slopes, bounded Part counts on diagonal slopes,
-- and no Part updates when the snow changes less than one height step.
local T = require("./testlib")
local R = require("./rbxmock")
local SnowField = require("./mods/SnowField")
local ChunkParts = require("./mods/ChunkParts")
local Shapes = require("./mods/Shapes")

local params = {
	cellSize = 0.25,
	chunkCells = 64,
	edgeFalloff = 1.5,
	minThickness = 0.06,
	cliffHeight = 3,
	maxSlopeCos = math.cos(math.rad(60)),
	rimRatio = 0.22,
	rimWidth = 0.6,
	regrowDelay = 0,
	regrowSpeed = 0.015,
	maxPendingPerChunk = 100,
}
local folder = R.Instance.new("Folder")
folder.Parent = R.Workspace
local style = {
	color = R.Color3.new(1, 1, 1),
	packedTint = R.Color3.new(0.8, 0.85, 0.9),
	material = "Enum.Material.Snow",
	materialVariant = "",
	studsPerTile = 8,
	castShadow = true,
	parent = folder,
	heightStep = 0.04,
	restHeightStep = 0.2,
}
local function noYield() end

-- builds one chunk (cx = cz = 0, covering x,z in [0, 16]) on top of an analytic ground
local function build(ground, step)
	local field = SnowField.new(params)
	field:addRegion(-8, 24, -8, 24)
	local chunk = field:getChunk(0, 0)
	local function sampler(x, z)
		local y = ground(x, z)
		if y then
			return y, 1, 1
		end
		return nil, 0, 0
	end
	field:attachFull(chunk, field:sampleGrid(chunk, 1, sampler, noYield), 0)
	local r = ChunkParts.build(field, chunk, step, style, noYield)
	return r, field, chunk
end

local function boxes(r)
	local out = {}
	for _, p in r.folder:GetChildren() do
		local c, s = p.CFrame.Position, p.Size
		table.insert(out, {
			x0 = c.X - s.X / 2,
			x1 = c.X + s.X / 2,
			z0 = c.Z - s.Z / 2,
			z1 = c.Z + s.Z / 2,
			top = c.Y + s.Y / 2,
			bottom = c.Y - s.Y / 2,
		})
	end
	return out
end

local function coverage(list)
	local area, overlaps = 0, 0
	for a = 1, #list do
		local A = list[a]
		area += (A.x1 - A.x0) * (A.z1 - A.z0)
		for b = a + 1, #list do
			local B = list[b]
			local ox = math.min(A.x1, B.x1) - math.max(A.x0, B.x0)
			local oz = math.min(A.z1, B.z1) - math.max(A.z0, B.z0)
			if ox > 1e-6 and oz > 1e-6 then
				overlaps += 1
			end
		end
	end
	return area, overlaps
end

-- worst vertical gap between two boxes that touch side by side
local function worstGap(list)
	local worst = 0
	for a = 1, #list do
		local A = list[a]
		for b = 1, #list do
			local B = list[b]
			if a ~= b and A.bottom > B.top then
				local touchX = math.abs(A.x0 - B.x1) < 1e-6 or math.abs(A.x1 - B.x0) < 1e-6
				local touchZ = math.abs(A.z0 - B.z1) < 1e-6 or math.abs(A.z1 - B.z0) < 1e-6
				local ox = math.min(A.x1, B.x1) - math.max(A.x0, B.x0)
				local oz = math.min(A.z1, B.z1) - math.max(A.z0, B.z0)
				if (touchX and oz > 1e-6) or (touchZ and ox > 1e-6) then
					worst = math.max(worst, A.bottom - B.top)
				end
			end
		end
	end
	return worst
end

local flat = function(_x, _z)
	return 5
end

T.describe("tiling at every level of detail", function()
	for _, step in { 1, 2, 4, 8 } do
		local r = build(flat, step)
		local list = boxes(r)
		local area, overlaps = coverage(list)
		T.near(area, 256, 1e-6, `step {step}: covers exactly the 16x16 chunk`)
		T.eq(overlaps, 0, `step {step}: no overlaps`)
		T.eq(#list, 1, `step {step}: flat untouched snow is a single Part`)
		for _, b in list do
			T.ok(b.top >= 5 + 0.02, `step {step}: snow top clear of the part top (no z-fighting)`)
			T.ok(math.abs(b.x0) > 1e-4 and math.abs(b.x1 - 16) > 1e-4, `step {step}: box sides not flush with part sides`)
		end
		r:destroy()
	end
end)

T.describe("diagonal slope", function()
	local slope = function(x, z)
		return 5 + (x + z) * math.tan(math.rad(30)) / math.sqrt(2)
	end
	for _, step in { 1, 2, 4, 8 } do
		local r = build(slope, step)
		local list = boxes(r)
		local area, overlaps = coverage(list)
		T.near(area, 256, 1e-6, `step {step}: covers the chunk`)
		T.eq(overlaps, 0, `step {step}: no overlaps`)
		T.ok(#list <= 25 * 64, `step {step}: bounded Part count ({#list})`)
		T.ok(worstGap(list) <= 1e-6, `step {step}: no gaps between terraces ({worstGap(list)})`)
		local below = 0
		for _, b in list do
			if b.top < slope((b.x0 + b.x1) / 2, (b.z0 + b.z1) / 2) - 0.2 * 16 then
				below += 1
			end
		end
		T.eq(below, 0, `step {step}: snow stays on the surface`)
		r:destroy()
	end
end)

T.describe("gentle slope along X", function()
	local ramp = function(x, _z)
		return 5 + x * math.tan(math.rad(10))
	end
	local r = build(ramp, 1)
	local list = boxes(r)
	T.ok(#list <= 120, `few wide terraces ({#list} Parts; one per cell would be 4225)`)
	T.eq(worstGap(list), 0, "no gaps")
	r:destroy()
end)

T.describe("prints and regrow", function()
	local r, field, chunk = build(flat, 1)
	local foot = Shapes.new()
	Shapes.set(foot, Shapes.BOX, 8, 5.2, 8, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0.4, 1.2)
	field:stamp(foot, 0, 0, nil, nil)
	r:applyDirty(field, chunk, chunk.dirty, false, style.packedTint)
	chunk.dirty, chunk.dirtyCount = {}, 0
	local list = boxes(r)
	T.ok(#list > 1, `split around the print ({#list} Parts)`)
	local _, overlaps = coverage(list)
	T.eq(overlaps, 0, "no overlaps with a print")

	-- one regrow tick moves every pressed column by 0.0004 studs: only the few cells that cross a
	-- rounding boundary may cause Part updates
	R.snowWrites = 0
	local active = chunk.full.activeCount
	field:regrow(chunk, 0.025)
	T.ok(chunk.dirtyCount >= active, "every regrowing column was marked dirty")
	r:applyDirty(field, chunk, chunk.dirty, false, style.packedTint)
	chunk.dirty, chunk.dirtyCount = {}, 0
	T.ok(R.snowWrites * 4 < active, `invisible changes cause (almost) no Part updates ({R.snowWrites} writes, {active} columns)`)

	-- fully regrown: back to one Part
	field:regrow(chunk, 200)
	r:applyDirty(field, chunk, chunk.dirty, false, style.packedTint)
	T.eq(#boxes(r), 1, "merges back into a single Part")
	T.eq(r.partCount, 1, "part count bookkeeping")
	r:destroy()
end)

T.describe("thin snow never sinks into the part", function()
	local r = build(function(x, _z)
		return 10 + x * 0.001
	end, 1)
	for _, b in boxes(r) do
		T.ok(b.top > 10 + (b.x0 + b.x1) / 2 * 0.001, "box top above the ground")
	end
	r:destroy()
end)

T.describe("pool bookkeeping", function()
	T.eq(ChunkParts.liveCount, 0, "every Part returned to the pool after destroy")
end)

return T.finish("partsgeom")
