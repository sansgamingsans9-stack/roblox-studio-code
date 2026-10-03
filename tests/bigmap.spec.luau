--!nocheck
-- Big maps (run with tools/test.sh): a 1024-stud baseplate in SnowParts must not make every plan
-- walk all of its thousands of chunks, and a still camera over snow that needs more Parts than the
-- budget allows must not keep rebuilding chunks back and forth.
local T = require("./testlib")
local R = require("./rbxmock")
local Config = require("./mods/Config")

Config.CellSize = 0.5
Config.ChunkCells = 32 -- 16-stud chunks: 64 x 64 of them on the baseplate
Config.MaxRenderDistance = 160
Config.SyncFootprints = false
Config.MaxSnowParts = 900

local SnowField = require("./mods/SnowField")
local ChunkParts = require("./mods/ChunkParts")
local SnowClient = require("./mods/SnowClient")
local V, CF, I = R.Vector3, R.CFrame, R.Instance

-- count the work done by plans and by the loader
local visits = 0
local chunkCenter = SnowField.chunkCenter
SnowField.chunkCenter = function(...)
	visits += 1
	return chunkCenter(...)
end
local builds = 0
local build = ChunkParts.build
ChunkParts.build = function(...)
	builds += 1
	return build(...)
end

local folder = I.new("Folder")
folder.Name = "SnowParts"
local base = I.new("Part")
base.Size = V.new(1024, 2, 1024)
base.CFrame = CF.new(0, -1, 0)
base.Anchored = true
base.Parent = folder
-- a field of steps near the middle: snow at many heights (triangles at coarse detail)
local seed = 7
for gz = -6, 5 do
	for gx = -6, 5 do
		seed = (seed * 1103515245 + 12345) % 2147483648
		local h = 0.3 + (seed % 1000) / 1000 * 2.4
		local p = I.new("Part")
		p.Size = V.new(6, h, 6)
		p.CFrame = CF.new(gx * 6 + 3, h / 2, gz * 6 + 3)
		p.Anchored = true
		p.Parent = folder
	end
end
folder.Parent = R.Workspace
R.camera.CFrame = CF.new(0, 30, 50)

SnowClient.start()
R.run(10)

T.describe("plans only look at the snow around the camera", function()
	local before = visits
	R.run(2) -- 8 plans
	local perPlan = (visits - before) / 8
	-- (within 160 studs + a chunk: about 22 x 22 chunks)
	T.ok(perPlan < 700, `chunks looked at per plan: {math.floor(perPlan)} (the baseplate has 4096)`)
	T.ok(R.boxTopY(0, -50) ~= nil, "snow in range drawn")
	T.eq(R.boxTopY(450, 450), nil, "snow far out of range not drawn")
end)

T.describe("a still camera over the Parts budget settles", function()
	R.run(10)
	local before = builds
	R.run(10)
	T.ok(builds - before <= 4, `chunks rebuilt while nothing moved: {builds - before}`)
	T.eq(ChunkParts.liveCount, #R.snowBoxes(), "Part bookkeeping")
end)

T.describe("moving away and back", function()
	R.camera.CFrame = CF.new(480, 30, 480)
	R.run(3)
	T.eq(R.boxTopY(0, 0), nil, "the old area is released")
	R.camera.CFrame = CF.new(0, 30, 50)
	R.run(5)
	T.ok(R.boxTopY(0, -50) ~= nil, "drawn again")
	T.eq(ChunkParts.liveCount, #R.snowBoxes(), "Part bookkeeping")
end)

return T.finish("bigmap")
