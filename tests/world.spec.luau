--!nocheck
-- The world changing under the snow (run with tools/test.sh): snow parts streaming out and back
-- in (StreamingEnabled), the whole SnowParts folder replaced (a new map), tagged deformers that
-- leave the world or get new parts, and invisible hitboxes on characters.
local T = require("./testlib")
local R = require("./rbxmock")
local Config = require("./mods/Config")

Config.CellSize = 0.5
Config.ChunkCells = 32
Config.SyncFootprints = false
Config.MaxRenderDistance = 200

local SnowClient = require("./mods/SnowClient")
local ChunkParts = require("./mods/ChunkParts")
local V, CF, I = R.Vector3, R.CFrame, R.Instance

local function part(name, size, cf, parent, props)
	local p = I.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	for k, v in props or {} do
		p[k] = v
	end
	p.Parent = parent
	return p
end

local mapA = I.new("Folder")
mapA.Name = "SnowParts"
local groundA = part("Ground", V.new(48, 2, 48), CF.new(0, -1, 0), mapA)
-- non-collidable, floating over nothing: gets a local collider
part("Ledge", V.new(6, 1, 6), CF.new(-60, 20, -60), mapA, { CanCollide = false })
mapA.Parent = R.Workspace
R.camera.CFrame = CF.new(0, 10, 16)

local char = I.new("Model")
local hum = I.new("Humanoid")
hum.Parent = char
local root = part("HumanoidRootPart", V.new(2, 2, 1), CF.new(0, 3, 0), char, { Anchored = false, Transparency = 1 })
local foot = part("LeftFoot", V.new(1, 0.4, 1.2), CF.new(5, 0.2, 5), char, { Anchored = false })
local hitbox = part("Hitbox", V.new(4, 5, 4), CF.new(0, 2.5, 0), char, { Anchored = false, Transparency = 1 })
R.localPlayer.Character = char
char.Parent = R.Workspace

SnowClient.start()
R.run(2)

local function colliders()
	local n = 0
	local render = R.Workspace:FindFirstChild("DeformableSnowRender")
	for _, c in render:GetChildren() do
		if c.Name == "SnowCollider" then
			n += 1
		end
	end
	return n
end

T.describe("invisible hitboxes do not make prints", function()
	T.near(R.boxTopY(5, 5), 0.06, 0.03, "the foot does")
	T.near(R.boxTopY(-1.5, 0), 1, 1e-6, "the invisible 4x5x4 hitbox around the root does not")
	T.near(R.boxTopY(0, 0), 1, 1e-6, "neither does the root part")
	T.eq(colliders(), 1, "the floating non-collidable part has a collider")
end)

T.describe("a snow part streaming out and back in keeps its prints", function()
	foot.CFrame = CF.new(5, 50, 5) -- step away
	hitbox.CFrame = CF.new(0, 50, 0)
	R.run(0.5)
	T.near(R.boxTopY(5, 5), 0.06, 0.03, "print there")
	groundA.Parent = nil -- streamed out
	R.run(1)
	T.eq(R.boxTopY(5, 5), nil, "gone with its part")
	groundA.Parent = mapA -- streamed back in
	R.run(2)
	T.near(R.boxTopY(5, 5), 0.06, 0.05, "the print is back")
	T.near(R.boxTopY(-10, -10), 1, 1e-6, "untouched snow around it")
end)

T.describe("tagged deformers", function()
	local CS = R.CollectionService
	-- a tagged tool template in ReplicatedStorage must not dent the snow where it was authored
	local tool = I.new("Tool")
	local handle = part("Handle", V.new(1, 1, 1), CF.new(-10, 0.5, 5), tool)
	tool.Parent = R.ReplicatedStorage
	CS:AddTag(tool, Config.DeformerTag)
	CS:GetInstanceAddedSignal(Config.DeformerTag):Fire(tool)
	R.run(1.5)
	T.near(R.boxTopY(-10, 5), 1, 1e-6, "a tagged part outside Workspace makes no print")
	-- equipped: in the world, it presses
	tool.Parent = char
	R.run(0.5)
	T.near(R.boxTopY(-10, 5), 0.06, 0.03, "in the world it does")

	-- a tagged (anchored) plow whose blade is added after it was tagged
	local plow = I.new("Model")
	plow.Parent = R.Workspace
	CS:AddTag(plow, Config.DeformerTag)
	CS:GetInstanceAddedSignal(Config.DeformerTag):Fire(plow)
	R.run(0.2)
	part("Blade", V.new(3, 1, 1), CF.new(12, 0.5, -10), plow)
	R.run(0.5)
	T.near(R.boxTopY(12, -10), 0.06, 0.03, "a part added to a tagged model presses too")
	handle.Parent = nil
end)

T.describe("a new map: the SnowParts folder is replaced", function()
	mapA.Parent = nil
	R.run(1)
	T.eq(#R.snowBoxes(), 0, "the old map's snow is gone")
	T.eq(ChunkParts.liveCount, 0, "every snow Part returned")
	T.eq(colliders(), 0, "and its colliders")
	local mapB = I.new("Folder")
	mapB.Name = "SnowParts"
	part("Ground", V.new(40, 2, 40), CF.new(0, 3, 0), mapB) -- top at y = 4
	mapB.Parent = R.Workspace
	R.run(2)
	T.near(R.boxTopY(-5, -5), 5, 1e-6, "snow on the new map")
	T.near(R.boxTopY(5, 5), 5, 1e-6, "old prints do not carry over to the new map")
	T.eq(ChunkParts.liveCount, #R.snowBoxes(), "Part bookkeeping")
	local errors = 0
	for _, w in R.warnings do
		if w:find("rror") then
			errors += 1
		end
	end
	T.eq(errors, 0, "no errors")
end)

return T.finish("world")
