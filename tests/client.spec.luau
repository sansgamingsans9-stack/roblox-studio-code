--!nocheck
-- End-to-end run of the real client code against the engine mock (run with tools/test.sh).
local T = require("./testlib")
local R = require("./rbxmock")
local StampCodec = require("./mods/StampCodec")
local Config = require("./mods/Config")

-- smaller world/settings so the test runs fast (must be set before SnowClient is required)
Config.SnowDepth = 0.8
Config.ChunkCells = 32
Config.LodDistances = { 24, 48, 96 }
Config.MaxRenderDistance = 200
Config.SimulationDistance = 100
Config.FrameBudgetMs = 50
Config.RegrowSpeed = 0
Config.FootstepSoundId = "rbxassetid://1"

local SnowClient = require("./mods/SnowClient")
local V, CF, I = R.Vector3, R.CFrame, R.Instance

local function part(name, size, pos, parent, props)
	local p = I.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = pos
	for k, v in props or {} do
		p[k] = v
	end
	p.Parent = parent
	return p
end

-- world --------------------------------------------------------------------
local folder = I.new("Folder")
folder.Name = "SnowParts"
folder.Parent = R.Workspace
part("Ground", V.new(40, 2, 40), CF.new(0, -1, 0), folder, { Anchored = true })
local pile = I.new("Part")
pile.Name = "Pile"
pile.Size = V.new(4, 2, 4)
pile.CFrame = CF.new(10, 1, 10)
pile.CanCollide = false
pile.CanQuery = false
pile:SetAttribute("SnowDepth", 0.5)
pile.Parent = folder

-- non-collidable and floating over nothing: must become walkable (local collider)
local ledge = I.new("Part")
ledge.Name = "Ledge"
ledge.Size = V.new(6, 1, 6)
ledge.CFrame = CF.new(-50, 20, -50)
ledge.CanCollide = false
ledge.Parent = folder

R.camera.CFrame = CF.new(0, 8, 12)

local char = I.new("Model")
char.Name = "Hero"
local hum = I.new("Humanoid")
hum.Parent = char
part("HumanoidRootPart", V.new(2, 2, 1), CF.new(0, 3, 0), char)
local leftFoot = part("LeftFoot", V.new(1, 0.4, 1.2), CF.new(-0.6, 0.2, 0), char)
part("RightFoot", V.new(1, 0.4, 1.2), CF.new(0.6, 0.2, 0), char)
R.localPlayer.Character = char
char.Parent = R.Workspace

local remotes = I.new("Folder")
remotes.Name = "DeformableSnowRemotes"
local ev = I.new("RemoteEvent")
ev.Name = "Footprints"
ev.Parent = remotes
remotes.Parent = R.ReplicatedStorage

part("Ball", V.new(2, 2, 2), CF.new(5, 1, 5), R.Workspace, { Shape = "Enum.PartType.Ball" })

-- run ----------------------------------------------------------------------
SnowClient.start()
R.run(3)

T.describe("meshes are built", function()
	T.ok(#R.meshParts() > 0, "chunk meshes exist")
	T.ok(R.raycasts > 0, "surface sampled with raycasts")
	T.ok(pile.CanQuery == true, "non-queryable snow part made queryable locally")
	local down = 0
	R.eachFace(function(n)
		if n.Y < -1e-6 then
			down += 1
		end
	end)
	T.eq(down, 0, "no triangle faces downwards (winding)")
end)

T.describe("untouched snow sits on top of the parts", function()
	T.near(R.surfaceY(-5, -5), 0.8, 1e-4, "ground: top + SnowDepth")
	T.near(R.surfaceY(10, 10), 2.5, 1e-4, "pile: its own SnowDepth attribute")
	T.near(R.surfaceY(-20, -5), 0.06, 1e-4, "thin at the outer edge")
	T.ok(R.surfaceY(-19.5, -5) < 0.5, "and thickening inwards")
end)

T.describe("non-collidable snow parts", function()
	local render = R.Workspace:FindFirstChild("DeformableSnowRender")
	local colliders = {}
	for _, c in render:GetChildren() do
		if c.Name == "SnowCollider" then
			table.insert(colliders, c)
		end
	end
	T.eq(#colliders, 1, "only the floating one gets a collider (the pile has ground under it)")
	T.ok(colliders[1] and colliders[1].CanCollide and colliders[1].Transparency == 1, "invisible & collidable")
	T.ok(colliders[1] and colliders[1].CFrame == ledge.CFrame, "same place as the part")
	T.ok(pile.CanCollide == false, "the user's part itself is untouched")
end)

T.describe("feet press the snow down and push up a rim", function()
	T.near(R.surfaceY(-0.5, 0), 0.06, 1e-4, "left foot print")
	T.near(R.surfaceY(0.5, 0), 0.06, 1e-4, "right foot print")
	T.ok(R.surfaceY(-1.5, 0) > 0.81, `rim beside the print ({R.surfaceY(-1.5, 0)})`)
	T.ok((R.emitted or 0) > 0, "snow puffs emitted")
	T.ok((R.played or 0) > 0, "crunch sound played")
	T.near(hum.WalkSpeed, 16, 1e-6, "walk speed restored after standing still")
end)

T.describe("unanchored ball presses the snow", function()
	T.near(R.surfaceY(5, 5), 0.06, 1e-4, "ball dent")
end)

T.describe("walking leaves a trail", function()
	local slowest = math.huge
	for i = 1, 30 do
		leftFoot.CFrame = CF.new(-0.6, 0.2, i * 0.1)
		R.frame(1 / 60)
		slowest = math.min(slowest, hum.WalkSpeed)
	end
	T.ok(slowest < 13, `wading through fresh snow slows you down (min WalkSpeed {slowest})`)
	R.run(0.5)
	T.near(R.surfaceY(-0.5, 2.5), 0.06, 1e-4, "new print")
	T.near(R.surfaceY(-0.5, 0), 0.06, 1e-4, "old print still there")
end)

T.describe("prints are reported to the server", function()
	local hello, packets = false, 0
	for _, p in R.sentToServer do
		if p == "hello" then
			hello = true
		elseif type(p) == "buffer" then
			packets += 1
			T.ok(StampCodec.decodeClient(p, 1, 0) ~= nil, "packet decodes")
		end
	end
	T.ok(hello, "asked for history")
	T.ok(packets > 0, "sent footprint packets")
end)

T.describe("history from the server is replayed", function()
	local s = {
		kind = 1,
		px = -8,
		py = 0.3,
		pz = -8,
		r00 = 1,
		r01 = 0,
		r02 = 0,
		r10 = 0,
		r11 = 1,
		r12 = 0,
		r20 = 0,
		r21 = 0,
		r22 = 1,
		sx = 1,
		sy = 0.4,
		sz = 1.2,
		userId = 2002,
		time = R.Workspace:GetServerTimeNow() - 1,
	}
	ev.OnClientEvent:Fire("history", StampCodec.encodeRelay({ s }))
	R.camera.CFrame = CF.new(-8, 6, -4)
	R.run(2)
	T.near(R.surfaceY(-8, -8), 0.1, 1e-4, "print from before we joined")
end)

T.describe("removing a snow part removes its snow", function()
	pile.Parent = nil
	R.run(2)
	T.near(R.surfaceY(10, 10), 0.8, 1e-4, "only the ground's snow is left")
end)

T.describe("moving a snow part keeps nearby prints", function()
	local ground = folder:FindFirstChild("Ground")
	ground.CFrame = CF.new(0, -0.5, 0) -- 0.5 studs up
	R.camera.CFrame = CF.new(0, 8, 12)
	R.run(2)
	T.near(R.surfaceY(-5, -5), 1.3, 1e-4, "snow follows the part")
end)

T.describe("level of detail when far away", function()
	local before = #R.meshParts()
	R.camera.CFrame = CF.new(0, 10, 150)
	R.run(3)
	local after = #R.meshParts()
	T.ok(after > 0 and after <= before, `still drawn at lower detail ({before} -> {after})`)
	T.near(R.surfaceY(-5, -5), 1.3, 1e-4, "coarse mesh at the right height")
	R.camera.CFrame = CF.new(0, 8, 12)
	R.run(3)
	T.near(R.surfaceY(-0.5, 0), 0.56, 1e-4, "print still there after coming back")
end)

T.describe("no warnings", function()
	T.eq(#R.warnings, 0, "warnings: " .. table.concat(R.warnings, " | "))
end)

return T.finish("client")
