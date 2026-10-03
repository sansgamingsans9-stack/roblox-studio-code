--!nocheck
-- End-to-end: the Parts renderer (no EditableMesh), including the automatic switch when
-- EditableMesh is blocked like in a published game without ID verification (run with tools/test.sh).
local T = require("./testlib")
local R = require("./rbxmock")
local Config = require("./mods/Config")

R.editableDisabled = true -- every CreateEditableMesh call errors
Config.Renderer = "EditableMesh" -- asks for meshes; must fall back to Parts by itself
Config.CellSize = 0.25
Config.SnowDepth = 0.8
Config.ChunkCells = 32 -- 8-stud chunks
Config.LodDistances = { 24, 48, 96 }
Config.MaxRenderDistance = 200
Config.SimulationDistance = 100
Config.FrameBudgetMs = 50
Config.RegrowDelay = 0.5
Config.RegrowSpeed = 1
Config.SyncFootprints = false

local SnowClient = require("./mods/SnowClient")
local ChunkParts = require("./mods/ChunkParts")
local V, CF, I = R.Vector3, R.CFrame, R.Instance

local folder = I.new("Folder")
folder.Name = "SnowParts"
local ground = I.new("Part")
ground.Name = "Part"
ground.Size = V.new(40, 2, 40)
ground.CFrame = CF.new(0, -1, 0)
ground.Anchored = true
ground.Parent = folder
folder.Parent = R.Workspace
R.camera.CFrame = CF.new(0, 8, 12)

local char = I.new("Model")
local hum = I.new("Humanoid")
hum.Parent = char
local function limb(name, size, pos)
	local p = I.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = pos
	p.Parent = char
	return p
end
limb("HumanoidRootPart", V.new(2, 2, 1), CF.new(0, 3, 0))
local lf = limb("LeftFoot", V.new(1, 0.4, 1.2), CF.new(-0.6, 0.2, 0))
local rf = limb("RightFoot", V.new(1, 0.4, 1.2), CF.new(0.6, 0.2, 0))
R.localPlayer.Character = char
char.Parent = R.Workspace

SnowClient.start()
R.run(4)

local function chunkParts(cx, cz)
	local render = R.Workspace:FindFirstChild("DeformableSnowRender")
	local f = render and render:FindFirstChild(`SnowChunk_{cx}_{cz}`)
	local n = 0
	if f then
		for _, p in f:GetChildren() do
			if p.Name == "Snow" then
				n += 1
			end
		end
	end
	return n, f ~= nil
end

T.describe("falls back to Parts when EditableMesh is blocked", function()
	local switched = false
	for _, w in R.warnings do
		if w:find("Switching to the Parts renderer") then
			switched = true
		end
	end
	T.ok(switched, "warned and switched")
	T.eq(#R.meshParts(), 0, "no mesh parts")
	T.ok(#R.snowBoxes() > 0, "snow drawn with Parts")
end)

T.describe("untouched snow", function()
	T.near(R.boxTopY(-5, -5), 0.8, 1e-6, "top = part top + SnowDepth")
	T.near(R.boxTopY(-12, -12), 0.8, 1e-6, "far interior too")
	local n, exists = chunkParts(-2, -2)
	T.ok(exists, "interior chunk drawn")
	T.eq(n, 1, "a fully untouched chunk is a single Part")
	T.ok((R.boxTopY(-19.9, -5) or 0) < 0.2, "thin at the outer edge")
end)

T.describe("footprints", function()
	T.near(R.boxTopY(-0.5, 0), 0.06, 0.03, "left print floor")
	T.near(R.boxTopY(0.5, 0.3), 0.06, 0.03, "right print floor")
	T.ok((R.boxTopY(-1.25, 0) or 0) > 0.8, "rim next to the print")
	local n = chunkParts(-1, -1)
	T.ok(n > 1, `chunk with a print is split up ({n} parts)`)
	T.eq(R.boxOverlaps(), 0, "boxes never overlap (no z-fighting)")
	T.ok(ChunkParts.liveCount == #R.snowBoxes(), `part bookkeeping ({ChunkParts.liveCount} vs {#R.snowBoxes()})`)
end)

T.describe("walking", function()
	local slowest = math.huge
	for i = 1, 40 do
		lf.CFrame = CF.new(-0.6, 0.2, i * 0.1)
		R.frame(1 / 60)
		slowest = math.min(slowest, hum.WalkSpeed)
	end
	R.run(0.2)
	T.near(R.boxTopY(-0.5, 3.5), 0.06, 0.03, "print along the way")
	T.ok(slowest < 13, `slowed down in fresh snow ({slowest})`)
	T.eq(R.boxOverlaps(), 0, "still no overlaps after many rebuilds")
end)

T.describe("trails fill back in and chunks merge back into one Part", function()
	lf.CFrame = CF.new(-0.6, 50, 0)
	rf.CFrame = CF.new(0.6, 50, 0)
	R.run(4)
	T.near(R.boxTopY(-0.5, 0), 0.8, 1e-6, "print regrown")
	T.near(R.boxTopY(-0.5, 3.5), 0.8, 1e-6, "trail regrown")
	local n = chunkParts(-1, -1)
	T.eq(n, 1, "back to a single Part")
	T.ok(ChunkParts.liveCount == #R.snowBoxes(), "bookkeeping after merging")
end)

T.describe("level of detail and back", function()
	R.camera.CFrame = CF.new(0, 10, 150)
	R.run(3)
	T.ok(#R.snowBoxes() > 0, "far snow still drawn")
	T.near(R.boxTopY(-5, -5), 0.8, 1e-6, "same height from far away")
	T.eq(R.boxOverlaps(), 0, "no overlaps at lower detail")
	R.camera.CFrame = CF.new(0, 8, 12)
	R.run(3)
	T.near(R.boxTopY(-5, -5), 0.8, 1e-6, "close again")
	T.ok(ChunkParts.liveCount == #R.snowBoxes(), "bookkeeping after LOD switches")
end)

return T.finish("parts")
