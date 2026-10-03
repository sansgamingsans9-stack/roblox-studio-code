--!nocheck
-- Client on an engine without the EditableMesh Batch* API and with a tiny memory budget,
-- plus regrowing snow (run with tools/test.sh).
local T = require("./testlib")
local R = require("./rbxmock")
local Config = require("./mods/Config")

R.disableBatch = true
R.meshBudget = 3
Config.Renderer = "EditableMesh"
Config.CellSize = 0.5
Config.SnowDepth = 1
Config.ChunkCells = 16
Config.LodDistances = { 16, 32, 64 }
Config.MaxRenderDistance = 120
Config.RegrowDelay = 1
Config.RegrowSpeed = 0.5
Config.SyncFootprints = false

local SnowClient = require("./mods/SnowClient")
local V, CF, I = R.Vector3, R.CFrame, R.Instance

local folder = I.new("Folder")
folder.Name = "SnowParts"
local ground = I.new("MeshPart")
ground.Name = "Rock"
ground.Size = V.new(30, 4, 30)
ground.CFrame = CF.new(0, 8, 0) -- top at y = 10
ground.Anchored = true
ground.Parent = folder
-- added after the client started: must still be picked up
R.camera.CFrame = CF.new(0, 16, 6)

local crate = I.new("Part")
crate.Name = "Crate"
crate.Size = V.new(2, 2, 2)
crate.CFrame = CF.yaw(3, 10.6, 3, 0.4) -- 0.6 deep into 1 stud of snow, rotated
crate.Parent = R.Workspace

SnowClient.start()
R.run(0.5)
folder.Parent = R.Workspace -- folder appears late (e.g. streaming)
R.run(3)

T.describe("works without the batch API", function()
	T.ok(#R.meshParts() > 0, "meshes built with per-element calls")
	local down = 0
	R.eachFace(function(n)
		if n.Y < -1e-6 then
			down += 1
		end
	end)
	T.eq(down, 0, "winding")
	T.near(R.surfaceY(-10, -10), 11, 1e-4, "snow on the MeshPart top")
end)

T.describe("memory budget exhaustion is handled", function()
	T.ok(#R.meshes <= 3, "never more than the budget")
	local warned = false
	for _, w in R.warnings do
		if w:find("ran out of EditableMesh memory") then
			warned = true
		end
	end
	T.ok(warned, "warned once about the budget")
end)

T.describe("a rotated crate dents the snow, then the dent regrows when it leaves", function()
	local y = R.surfaceY(3, 3)
	T.ok(y ~= nil and y < 10.5, `dent under the crate ({y})`)
	crate.Parent = nil
	R.run(4)
	T.near(R.surfaceY(3, 3), 11, 1e-4, "regrown to the rest surface")
end)

return T.finish("fallback")
