--!nocheck
-- MaxSnowParts: far snow loses detail, snow beyond the last detail ring is skipped, snow within
-- it is never hidden (that would look like holes), snow near the camera is always drawn.
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
	-- 8-stud chunks closer than 64 studs (the last detail ring) stay: about pi * 64^2 / 64 of them
	local within = 0
	for cz = -10, 9 do
		for cx = -10, 9 do
			local dx = math.max(math.abs(cx * 8 + 4) - 4, 0)
			local dz = math.max(math.abs(cz * 8 + 4) - 4, 0)
			if math.sqrt(dx * dx + 36 + dz * dz) < 64 then
				within += 1
			end
		end
	end
	T.ok(ChunkParts.liveCount <= within + 12, `only the snow within the last ring ({ChunkParts.liveCount} Parts, {within} chunks)`)
	T.near(R.boxTopY(0, 0), 1, 1e-6, "snow under the camera is drawn")
	T.near(R.boxTopY(6, -6), 1, 1e-6, "snow next to the camera is drawn")
	T.near(R.boxTopY(40, -20), 1, 1e-6, "snow farther away is still drawn (no holes)")
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
