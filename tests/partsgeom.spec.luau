--!nocheck
-- Geometry of the Parts renderer on its own (run with tools/test.sh):
-- the two-wedge triangle construction, flat snow as single boxes, smooth triangle surfaces for
-- slopes/curves/prints that follow the snow closely, and minimal Part updates.
local T = require("./testlib")
local R = require("./rbxmock")
local SnowField = require("./mods/SnowField")
local ChunkParts = require("./mods/ChunkParts")
local Shapes = require("./mods/Shapes")
local V = R.Vector3

local params = {
	cellSize = 0.25,
	chunkCells = 64,
	edgeFalloff = 0,
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
local SMOOTH = 0.03
local style = {
	color = R.Color3.new(1, 1, 1),
	packedTint = R.Color3.new(0.8, 0.85, 0.9),
	material = "Enum.Material.Snow",
	materialVariant = "",
	studsPerTile = 8,
	castShadow = true,
	parent = folder,
	smoothness = SMOOTH,
}
local function noYield() end

-- one chunk (cx = cz = 0, covering x,z in [0, 16]) on an analytic ground, snow depth 1
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

local function surfaceAt(r, x, z)
	local best
	for _, p in r.folder:GetChildren() do
		local y
		if p.ClassName == "WedgePart" then
			y = R.triHeight(R.wedgeTop(p), x, z)
		else
			local c, s = p.CFrame.Position, p.Size
			if math.abs(x - c.X) <= s.X / 2 + 1e-9 and math.abs(z - c.Z) <= s.Z / 2 + 1e-9 then
				y = c.Y + s.Y / 2
			end
		end
		if y and (not best or y > best) then
			best = y
		end
	end
	return best
end

-- worst difference between the drawn surface and the snow at many points
local function worstError(r, snowTop, n)
	local worst, missing = 0, 0
	for k = 1, n do
		local x = 0.05 + (k * 7.31 % 15.9)
		local z = 0.05 + (k * 3.77 % 15.9)
		local y = surfaceAt(r, x, z)
		if not y then
			missing += 1
		else
			worst = math.max(worst, math.abs(y - snowTop(x, z)))
		end
	end
	return worst, missing
end

T.describe("two wedges draw exactly one triangle", function()
	local tris = {
		{ V.new(0, 0, 0), V.new(2, 0, 0), V.new(1, 0, 1) },
		{ V.new(0, 1, 0), V.new(0.5, 0.2, 0), V.new(0.1, 0.7, 0.5) },
		{ V.new(3, 2, 1), V.new(3.25, 1.4, 1), V.new(3, 1.9, 1.25) },
		{ V.new(-1, 5, -1), V.new(4, 6, 0), V.new(0, 4, 3) },
	}
	for n, t in tris do
		local a, b, c = t[1], t[2], t[3]
		local s1, c1, s2, c2 = ChunkParts.wedgeFrames(a, b, c)
		local f1 = R.wedgeTop({ CFrame = c1, Size = s1 })
		local f2 = R.wedgeTop({ CFrame = c2, Size = s2 })
		for _, v in { a, b, c } do
			local found = false
			for _, f in { f1, f2 } do
				for _, q in f do
					if (q - v).Magnitude < 1e-6 then
						found = true
					end
				end
			end
			T.ok(found, `triangle {n}: corner {tostring(v)} drawn`)
		end
		local normal = (c - a):Cross(b - a)
		local area = normal.Magnitude / 2
		local nu = normal.Unit
		local sum = 0
		for _, f in { f1, f2 } do
			sum += ((f[2] - f[1]):Cross(f[3] - f[1])).Magnitude / 2
			for _, q in f do
				T.ok(math.abs((q - a):Dot(nu)) < 1e-6, `triangle {n}: top face in the triangle's plane`)
			end
		end
		T.near(sum, area, 1e-6, `triangle {n}: no overlap, no gap`)
	end
end)

local flat = function(_x, _z)
	return 5
end

T.describe("flat untouched snow", function()
	for _, step in { 1, 2, 4, 8 } do
		local r = build(flat, step)
		T.eq(#r.folder:GetChildren(), 1, `step {step}: one single Part`)
		T.near(surfaceAt(r, 8, 8), 6, 1e-6, `step {step}: at part top + depth`)
		T.near(surfaceAt(r, 0.01, 15.99), 6, 1e-6, `step {step}: covers the corners`)
		r:destroy()
	end
end)

T.describe("planar diagonal slope is a few big triangles", function()
	local slope = function(x, z)
		return 5 + (x + z) * math.tan(math.rad(30)) / math.sqrt(2)
	end
	local top = function(x, z)
		return slope(x, z) + 1
	end
	for _, step in { 1, 2, 4, 8 } do
		local r = build(slope, step)
		local count = #r.folder:GetChildren()
		T.ok(count <= 64, `step {step}: {count} Parts`)
		local worst, missing = worstError(r, top, 200)
		T.eq(missing, 0, `step {step}: no holes`)
		T.ok(worst <= 0.011, `step {step}: follows the slope ({worst})`)
		r:destroy()
	end
end)

T.describe("curved snow (dome) stays within the smoothness tolerance", function()
	local dome = function(x, z)
		return 5 + math.sqrt(30 * 30 - (x - 8) ^ 2 - (z - 8) ^ 2) - 30
	end
	local top = function(x, z)
		return dome(x, z) + 1
	end
	local r = build(dome, 1)
	local worst, missing = worstError(r, top, 300)
	T.eq(missing, 0, "no holes")
	T.ok(worst <= SMOOTH + 0.02, `close to the true surface ({worst})`)
	T.ok(#r.folder:GetChildren() <= 1200, `bounded Part count ({#r.folder:GetChildren()})`)
	r:destroy()
end)

T.describe("a footprint is a smooth dent", function()
	local r, field, chunk = build(flat, 1)
	local foot = Shapes.new()
	Shapes.set(foot, Shapes.BOX, 8, 5.2, 8, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0.4, 1.2)
	field:stamp(foot, 0, 0, nil, nil)
	r:applyDirty(field, chunk, chunk.dirty, false, style.packedTint)
	chunk.dirty, chunk.dirtyCount = {}, 0
	T.near(surfaceAt(r, 8, 8), 5.06, 0.011, "print floor")
	T.near(surfaceAt(r, 3, 3), 6, 1e-6, "untouched snow around")
	local wedges = 0
	for _, p in r.folder:GetChildren() do
		if p.ClassName == "WedgePart" then
			wedges += 1
		end
	end
	T.ok(wedges > 0, `the print is drawn with triangles ({wedges} wedges)`)
	T.ok(#r.folder:GetChildren() <= 400, `reasonable Part count ({#r.folder:GetChildren()})`)
	local mid = surfaceAt(r, 7.4, 8)
	T.ok(mid ~= nil and mid > 5.06 and mid < 6.2, `the dent wall is a slope ({mid})`)
	T.eq(r.partCount, #r.folder:GetChildren(), "part count bookkeeping")

	-- one regrow tick moves every pressed column by 0.0004 studs: almost nothing is redrawn
	R.snowWrites = 0
	local active = chunk.full.activeCount
	field:regrow(chunk, 0.025)
	r:applyDirty(field, chunk, chunk.dirty, false, style.packedTint)
	chunk.dirty, chunk.dirtyCount = {}, 0
	T.ok(
		R.snowWrites * 4 < active,
		`invisible changes cause (almost) no Part updates ({R.snowWrites} writes, {active} columns)`
	)

	field:regrow(chunk, 300)
	r:applyDirty(field, chunk, chunk.dirty, false, style.packedTint)
	T.eq(#r.folder:GetChildren(), 1, "merges back into a single Part")
	T.eq(r.partCount, 1, "part count after merging")
	r:destroy()
end)

T.describe("edge of the snow", function()
	local half = function(x, _z)
		if x <= 10.1 then
			return 5
		end
		return nil
	end
	local r = build(half, 1)
	T.near(surfaceAt(r, 9.9, 4), 6, 1e-6, "snow up to the last sample")
	T.eq(surfaceAt(r, 10.3, 4), nil, "nothing past the part edge")
	-- boxes merge per 4x4-stud tile: 2 full tiles + 1 partial tile per row of 4
	T.ok(#r.folder:GetChildren() <= 12, `level edge is a few boxes ({#r.folder:GetChildren()})`)
	r:destroy()
end)

T.describe("pool bookkeeping", function()
	T.eq(ChunkParts.liveCount, 0, "every Part returned to the pool after destroy")
end)

return T.finish("partsgeom")
