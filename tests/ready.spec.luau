--!nocheck
-- The SnowReady attribute a loading screen can wait for (run with tools/test.sh): only once the
-- player has spawned and the snow around them is drawn, after snow parts stop streaming in, and
-- never later than a deadline.
local T = require("./testlib")
local R = require("./rbxmock")
local Config = require("./mods/Config")

Config.CellSize = 0.5
Config.ChunkCells = 32
Config.SyncFootprints = false
Config.PreloadSeconds = 4 -- deadline: 4 + 10 s after the snow parts are found

local SnowClient = require("./mods/SnowClient")
local V, CF, I = R.Vector3, R.CFrame, R.Instance

local folder = I.new("Folder")
folder.Name = "SnowParts"
local function snowPart(size, cf)
	local p = I.new("Part")
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.Parent = folder
	return p
end
snowPart(V.new(40, 2, 40), CF.new(300, -1, 300))
folder.Parent = R.Workspace
R.camera.CFrame = CF.new(0, 20, 20) -- the default camera, far from the snow

SnowClient.start()
local render = R.Workspace:FindFirstChild("DeformableSnowRender")
local function ready()
	return render:GetAttribute("SnowReady")
end

T.describe("not ready before the player spawns", function()
	R.run(3)
	T.eq(ready(), false, "no character yet")
end)

T.describe("ready once the snow around the player is drawn", function()
	local char = I.new("Model")
	local hum = I.new("Humanoid")
	hum.Parent = char
	local root = I.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = V.new(2, 2, 1)
	root.CFrame = CF.new(300, 3, 300)
	root.Parent = char
	R.localPlayer.Character = char
	char.Parent = R.Workspace
	R.run(0.3)
	T.eq(ready(), false, "camera not at the character yet")
	R.camera.CFrame = CF.new(300, 10, 312)
	-- more snow parts stream in around the player
	for k = 1, 4 do
		snowPart(V.new(10, 1, 10), CF.new(300 + k * 12, 0.5, 330))
		R.run(0.25)
		T.eq(ready(), false, `snow parts still arriving ({k})`)
	end
	R.run(2)
	T.eq(ready(), true, "ready")
	T.ok(R.boxTopY(300, 300) ~= nil and R.boxTopY(312, 330) ~= nil, "the snow there is drawn")
end)

return T.finish("ready")
