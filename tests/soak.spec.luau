--!nocheck
-- Stress test (run with tools/test.sh): several players walking around for minutes while snow
-- parts are added, moved and removed, the camera teleports, a character respawns, physics
-- produces garbage values and the quality tier changes. Afterwards everything must be
-- consistent: every snow Part accounted for, no broken Parts, no errors, trails regrown and the
-- snow merged back into plain boxes.
local T = require("./testlib")
local R = require("./rbxmock")
local Config = require("./mods/Config")

Config.CellSize = 0.5
Config.SnowDepth = 1
Config.ChunkCells = 32 -- 16-stud chunks
Config.LodDistances = { 24, 48, 96 }
Config.MaxRenderDistance = 160
Config.SimulationDistance = 120
Config.RegrowDelay = 1
Config.RegrowSpeed = 0.6
Config.SyncFootprints = false
Config.MaxSnowParts = 4000

local SnowClient = require("./mods/SnowClient")
local ChunkParts = require("./mods/ChunkParts")
local V, CF, I = R.Vector3, R.CFrame, R.Instance

-- deterministic random numbers
local seed = 12345
local function rand()
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end

local folder = I.new("Folder")
folder.Name = "SnowParts"
local function snowPart(name, size, cf, props)
	local p = I.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	for k, v in props or {} do
		p[k] = v
	end
	p.Parent = folder
	return p
end
-- snow top is at y = 1 everywhere on the ground (part top 0 + depth 1)
snowPart("Ground", V.new(64, 2, 64), CF.new(0, -1, 0))
local moving = snowPart("Platform", V.new(8, 1, 8), CF.new(-20, 2.5, 20)) -- top 3, snow top 4
local doomed = snowPart("Doomed", V.new(6, 1, 6), CF.new(20, 2.5, -20))
snowPart("Pile", V.new(6, 2, 6), CF.new(20, 1, 20), { CanCollide = false }) -- wade-through pile
folder.Parent = R.Workspace
R.camera.CFrame = CF.new(0, 12, 20)

-- walkers ------------------------------------------------------------------------------------
local walkers = {}
local function makeWalker(k)
	local model = I.new("Model")
	model.Name = "Walker" .. k
	local hum = I.new("Humanoid")
	hum.WalkSpeed = 16
	hum.Parent = model
	local function limb(name, size)
		local p = I.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = CF.new(0, 50, 0)
		p.Parent = model
		return p
	end
	local w = {
		model = model,
		hum = hum,
		root = limb("HumanoidRootPart", V.new(2, 2, 1)),
		left = limb("LeftFoot", V.new(1, 0.4, 1.2)),
		right = limb("RightFoot", V.new(1, 0.4, 1.2)),
		cx = (rand() - 0.5) * 30,
		cz = (rand() - 0.5) * 30,
		r = 4 + rand() * 8,
		phase = rand() * 6.28,
		speed = 0.3 + rand() * 0.4,
	}
	model.Parent = R.Workspace
	walkers[k] = w
	return w
end
for k = 1, 4 do
	makeWalker(k)
end
R.localPlayer.Character = walkers[1].model

local clock = 0
local walking = true
local function moveWalkers(dt)
	clock += dt
	for _, w in walkers do
		if walking then
			local a = w.phase + clock * w.speed
			local x, z = w.cx + math.cos(a) * w.r, w.cz + math.sin(a) * w.r
			local step = math.floor(clock / 0.3) % 2 == 0
			w.root.CFrame = CF.new(x, 3, z)
			w.left.CFrame = CF.new(x - 0.6, if step then 0.2 else 1.6, z)
			w.right.CFrame = CF.new(x + 0.6, if step then 1.6 else 0.2, z)
		else
			-- standing far outside the snow
			w.root.CFrame = CF.new(200, 3, 200)
			w.left.CFrame = CF.new(199.4, 0.2, 200)
			w.right.CFrame = CF.new(200.6, 0.2, 200)
		end
	end
end

-- a ball rolling over the snow
local ball = I.new("Part")
ball.Name = "Ball"
ball.Shape = "Enum.PartType.Ball"
ball.Size = V.new(2, 2, 2)
ball.Anchored = false
ball.CFrame = CF.new(-10, 1, -10)
ball.Parent = R.Workspace

-- checks -------------------------------------------------------------------------------------
local function finite(n)
	return n == n and math.abs(n) < 1e6
end

local problems = {}
local function problem(msg)
	if #problems < 10 then
		table.insert(problems, msg)
	end
end

local function check(label)
	local boxes = R.snowBoxes()
	if ChunkParts.liveCount ~= #boxes then
		problem(`{label}: liveCount {ChunkParts.liveCount} vs {#boxes} snow Parts`)
	end
	for _, p in boxes do
		local s, c = p.Size, p.CFrame.Position
		if not (finite(s.X) and finite(s.Y) and finite(s.Z) and s.X > 0 and s.Y > 0 and s.Z > 0) then
			problem(`{label}: bad Size {s.X} {s.Y} {s.Z}`)
		end
		if not (finite(c.X) and finite(c.Y) and finite(c.Z)) then
			problem(`{label}: bad CFrame {c.X} {c.Y} {c.Z}`)
		end
		if c.Y < -3 or c.Y > 6 then
			problem(`{label}: snow Part at a strange height {c.Y}`)
		end
	end
end

local function run(seconds, dt)
	dt = dt or 1 / 30
	local frames = math.floor(seconds / dt + 0.5)
	for f = 1, frames do
		moveWalkers(dt)
		ball.CFrame = CF.new(-10 + math.sin(clock * 0.5) * 8, 1, -10)
		R.frame(dt)
		if f % 30 == 0 then
			check(`t={math.floor(clock)}`)
		end
	end
end

-- the session ----------------------------------------------------------------------------------
SnowClient.start()
run(5)

T.describe("walking around", function()
	local pressed = 0
	for _, w in walkers do
		local p = w.left.CFrame.Position
		if p.Y < 1 then
			local top = R.boxTopY(p.X, p.Z)
			if top and top < 0.5 then
				pressed += 1
			end
		end
	end
	T.ok(pressed >= 2, `feet on the ground leave prints ({pressed})`)
end)

-- snow parts change while people walk
snowPart("NewPart", V.new(8, 1, 8), CF.new(0, 2.5, -24)) -- appears at runtime
run(3)
moving.CFrame = CF.new(-24, 2.5, 24) -- moved
run(3)
doomed:Destroy() -- removed
run(3)

T.describe("snow parts added, moved and removed at runtime", function()
	T.near(R.boxTopY(0, -24), 4, 1e-6, "snow on the new part")
	T.near(R.boxTopY(-25, 25), 4, 1e-6, "snow follows the moved part")
	T.near(R.boxTopY(-17, 17), 1, 1e-6, "old place of the moved part: ground snow again")
	T.near(R.boxTopY(20, -20), 1, 1e-6, "removed part: ground snow again")
end)

-- camera teleports far away and back
R.camera.CFrame = CF.new(400, 20, 400)
run(3)
R.camera.CFrame = CF.new(0, 12, 20)
run(3)

-- the local player respawns
walkers[1].model:Destroy()
run(0.5)
local respawned = makeWalker(1)
R.localPlayer.Character = respawned.model
run(3)

-- broken physics: a foot with NaN / far-away positions for a moment
local bad = walkers[2]
for _ = 1, 10 do
	bad.left.CFrame = CF.new(0 / 0, 0 / 0, 0 / 0)
	bad.right.CFrame = CF.new(1e9, 0.2, 0)
	R.frame(1 / 30)
end
run(2)

-- a slow stretch (the quality tier steps down), then smooth again (it climbs back)
run(20, 1 / 15)
local render = R.Workspace:FindFirstChild("DeformableSnowRender")
local lowered = render:GetAttribute("SnowQuality")
run(100, 1 / 60)

T.describe("everything stays consistent", function()
	T.ok(lowered ~= "High", `quality stepped down while slow ({lowered})`)
	T.eq(render:GetAttribute("SnowQuality"), "High", "and back up afterwards")
	check("end of the session")
	T.eq(#problems, 0, "no inconsistencies: " .. table.concat(problems, "; "))
	T.eq(R.boxOverlaps(), 0, "no overlapping boxes")
	local errors = {}
	for _, w in R.warnings do
		if w:find("error") or w:find("rror") then
			table.insert(errors, w)
		end
	end
	T.eq(#errors, 0, "no errors: " .. table.concat(errors, " | "))
end)

-- everyone leaves; the trails fill back in (seen from above the middle: fine detail everywhere)
walking = false
R.camera.CFrame = CF.new(0, 20, 0)
ball.CFrame = CF.new(300, 1, 300)
run(1)
ball:Destroy()
run(12)

T.describe("trails regrow and the snow becomes plain boxes again", function()
	-- raised parts: x, z, half size, snow top
	local raised = { { 20, 20, 3, 3 }, { -24, 24, 4, 4 }, { 0, -24, 4, 4 } }
	local worst, wedges = 0, 0
	for x = -30.3, 30, 1.7 do
		for z = -30.1, 30, 1.9 do
			local want, edge = 1, false
			for _, r in raised do
				local dx, dz = math.abs(x - r[1]), math.abs(z - r[2])
				-- (the step is drawn up to one cell past the part: 1 stud at half detail)
				if dx < r[3] + 1.1 and dz < r[3] + 1.1 then
					if dx < r[3] - 0.1 and dz < r[3] - 0.1 then
						want = r[4]
					else
						edge = true -- the step down from a raised part
					end
				end
			end
			if not edge then
				local top = R.boxTopY(x, z)
				worst = math.max(worst, if top then math.abs(top - want) else math.huge)
			end
		end
	end
	T.ok(worst < 0.02, `snow back at its rest height everywhere ({worst})`)
	for _, p in R.snowBoxes() do
		if p.ClassName == "WedgePart" then
			wedges += 1
		end
	end
	T.eq(wedges, 0, "untouched snow is boxes only, steps at raised parts included")
	T.eq(ChunkParts.liveCount, #R.snowBoxes(), "Part bookkeeping")
	local hum = respawned.hum
	T.eq(hum.WalkSpeed, 16, "walk speed back to normal out of the snow")
end)

return T.finish("soak")
