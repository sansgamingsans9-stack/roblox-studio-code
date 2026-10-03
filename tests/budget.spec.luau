--!nocheck
-- EditableMesh renderer on a device that runs out of EditableMesh memory: everything must move
-- over to the Parts renderer together, so no seams between chunks (run with tools/test.sh).
local T = require("./testlib")
local R = require("./rbxmock")
local Config = require("./mods/Config")

R.meshBudget = 3
Config.Renderer = "EditableMesh"
Config.CellSize = 0.5
Config.ChunkCells = 16
Config.LodDistances = { 16, 32, 64 }
Config.MaxRenderDistance = 120
Config.SyncFootprints = false

local SnowClient = require("./mods/SnowClient")
local V, CF, I = R.Vector3, R.CFrame, R.Instance

local folder = I.new("Folder")
folder.Name = "SnowParts"
local ground = I.new("Part")
ground.Size = V.new(30, 2, 30)
ground.CFrame = CF.new(0, 9, 0)
ground.Anchored = true
ground.Parent = folder
folder.Parent = R.Workspace
R.camera.CFrame = CF.new(0, 16, 6)

SnowClient.start()
R.run(4)

T.describe("running out of EditableMesh memory", function()
	T.ok(#R.meshes <= 3, "never more meshes than the budget")
	local warned = false
	for _, w in R.warnings do
		if w:find("ran out of EditableMesh memory") and w:find("Parts renderer") then
			warned = true
		end
	end
	T.ok(warned, "warned once and switched to Parts")
	T.eq(#R.meshParts(), 0, "no leftover mesh chunks (renderers are never mixed)")
	T.ok(#R.snowBoxes() > 0, "snow drawn with Parts")
	T.near(R.boxTopY(-10, -10), 11, 1e-6, "snow on top of the part")
	T.eq(R.boxOverlaps(), 0, "no overlaps")
end)

return T.finish("budget")
