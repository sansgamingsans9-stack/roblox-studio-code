--!nocheck
-- End-to-end on a phone (run with tools/test.sh): starts at the Low quality tier, preloads,
-- steps down when the frame rate drops, climbs back when it recovers, and the snow stays correct
-- through every quality change.
local T = require("./testlib")
local R = require("./rbxmock")
local Config = require("./mods/Config")

-- a touch-only device (phone / tablet), graphics quality on "Automatic"
R.UserInputService.TouchEnabled = true
R.UserInputService.KeyboardEnabled = false
R.UserInputService.MouseEnabled = false

Config.CellSize = 0.25 -- a phone uses at least 0.5
Config.SnowDepth = 1
Config.ChunkCells = 32
Config.MaxRenderDistance = 200
Config.SimulationDistance = 120
Config.RegrowDelay = 0.5
Config.RegrowSpeed = 1
Config.SyncFootprints = false
Config.FootstepSoundId = "rbxassetid://1"

local SnowClient = require("./mods/SnowClient")
local ChunkParts = require("./mods/ChunkParts")
local Quality = require("./mods/Quality")
local V, CF, I = R.Vector3, R.CFrame, R.Instance

local folder = I.new("Folder")
folder.Name = "SnowParts"
local ground = I.new("Part")
ground.Size = V.new(48, 2, 48)
ground.CFrame = CF.new(0, -1, 0)
ground.Anchored = true
ground.Parent = folder
folder.Parent = R.Workspace
R.camera.CFrame = CF.new(5, 8, 17)

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
limb("HumanoidRootPart", V.new(2, 2, 1), CF.new(5, 3, 5))
limb("LeftFoot", V.new(1, 0.4, 1.2), CF.new(4.4, 0.2, 5))
limb("RightFoot", V.new(1, 0.4, 1.2), CF.new(5.6, 0.2, 5))
R.localPlayer.Character = char
char.Parent = R.Workspace

local render
local function quality()
	return render:GetAttribute("SnowQuality")
end

-- the snow is drawn correctly and every Part is accounted for
local function healthy(label)
	T.near(R.boxTopY(4.5, 5), 0.06, 0.03, `{label}: left print`)
	T.near(R.boxTopY(5.5, 5.3), 0.06, 0.03, `{label}: right print`)
	T.near(R.boxTopY(-10, -10), 1, 1e-6, `{label}: untouched snow`)
	T.eq(ChunkParts.liveCount, #R.snowBoxes(), `{label}: Part bookkeeping`)
	T.eq(R.boxOverlaps(), 0, `{label}: no overlapping boxes`)
end

local function allShadows(on)
	for _, p in R.snowBoxes() do
		if p.CastShadow ~= on then
			return false
		end
	end
	return true
end

SnowClient.start()
render = R.Workspace:FindFirstChild("DeformableSnowRender")
R.run(2)

T.describe("a phone starts at Low quality", function()
	T.eq(quality(), "Low", "SnowQuality attribute")
	T.eq(render:GetAttribute("SnowReady"), true, "SnowReady once the nearby snow is built")
	T.ok(allShadows(false), "no snow shadows on Low")
	-- the grid is at least 0.5 studs: a 32-cell chunk is 16 studs wide
	local chunk = render:FindFirstChild("SnowChunk_-1_-1")
	local box = chunk and chunk:FindFirstChild("Snow")
	T.ok(box ~= nil and math.abs(box.Size.X - 16) < 0.01, `coarser grid on a phone ({box and box.Size.X})`)
	healthy("Low")
end)

T.describe("preloading", function()
	local emitters, sounds = 0, 0
	for _, inst in R.preloaded do
		if inst.ClassName == "ParticleEmitter" then
			emitters += 1
		elseif inst.ClassName == "Sound" then
			sounds += 1
		end
	end
	T.eq(emitters, 2, "particle textures preloaded")
	T.ok(sounds >= 1, "crunch sound preloaded")
	local boxes, wedges = ChunkParts.poolSize()
	local low = Quality.TIERS[2]
	T.ok(
		boxes + wedges + ChunkParts.liveCount >= low.poolBoxes + low.poolWedges,
		`Parts created ahead of time ({boxes} + {wedges} pooled, {ChunkParts.liveCount} live)`
	)
end)

T.describe("a slow phone steps down to Potato", function()
	R.run(14, 1 / 20)
	T.eq(quality(), "Potato", "SnowQuality attribute")
	R.run(1, 1 / 20)
	healthy("Potato")
end)

T.describe("climbs back when the frame rate recovers, never to High on a phone", function()
	R.run(36, 1 / 60)
	T.eq(quality(), "Low", "back to Low after ~20 smooth seconds")
	R.run(36, 1 / 60)
	T.eq(quality(), "Medium", "then Medium")
	T.ok(allShadows(true), "shadows come back on Medium")
	healthy("Medium")
	R.run(120, 1 / 60)
	T.eq(quality(), "Medium", "a phone never goes to High")
end)

T.describe("footprints after the quality changes", function()
	-- walk a few steps: new prints use the current quality
	local lf = char:FindFirstChild("LeftFoot")
	for i = 1, 30 do
		lf.CFrame = CF.new(4.4, 0.2, 5 - i * 0.1)
		R.frame(1 / 60)
	end
	R.run(0.3)
	T.near(R.boxTopY(4.5, 2.5), 0.06, 0.03, "new print drawn")
	T.eq(ChunkParts.liveCount, #R.snowBoxes(), "Part bookkeeping")
	local bad = 0
	for _, w in R.warnings do
		if w:find("error") then
			bad += 1
		end
	end
	T.eq(bad, 0, "no errors")
end)

return T.finish("lowend")
