--!nocheck
-- MaxSnowParts: far snow loses detail / is skipped, snow near the camera is always drawn.
local T = require("./testlib")
local R = require("./rbxmock")
local Config = require("./mods/Config")

Config.CellSize = 0.5
Config.ChunkCells = 16 -- 8-stud chunks
Config.LodDistances = { 16, 32, 64 }
Config.MaxRenderDistance = 200
Config.MaxSnowParts = 30
Config.SyncFootprints = false

local SnowClient = require("./mods/SnowClient")
local ChunkParts = require("./mods/ChunkParts")
local V, CF, I = R.Vector3, R.CFrame, R.Instance

local folder = I.new("Folder")
folder.Name = "SnowParts"
local ground = I.new("Part")
ground.Size = V.new(160, 2, 160)
ground.CFrame = CF.new(0, -1, 0)
ground.Anchored = true
ground.Parent = folder
folder.Parent = R.Workspace
R.camera.CFrame = CF.new(0, 6, 0)

SnowClient.start()
R.run(6)

T.describe("Parts budget", function()
	T.ok(ChunkParts.liveCount <= Config.MaxSnowParts + 12, `stays near the budget ({ChunkParts.liveCount})`)
	T.near(R.boxTopY(0, 0), 1, 1e-6, "snow under the camera is drawn")
	T.near(R.boxTopY(6, -6), 1, 1e-6, "snow next to the camera is drawn")
	T.eq(R.boxTopY(70, 70), nil, "far corner skipped")
	local warned = false
	for _, w in R.warnings do
		if w:find("MaxSnowParts") then
			warned = true
		end
	end
	T.ok(warned, "warned once")
	T.eq(R.boxOverlaps(), 0, "no overlaps")
end)

return T.finish("partbudget")
