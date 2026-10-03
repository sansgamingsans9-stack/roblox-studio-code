--!nocheck
-- The snowy weather on its own (run with tools/test.sh): lighting and fog applied and restored,
-- snow that follows the camera and stops under roofs, the lens flare only when looking at an
-- unblocked sun, and the quality levels.
local T = require("./testlib")
local R = require("./rbxmock")
local Quality = require("./mods/Quality")
local SnowWeather = require("./mods/SnowWeather")
local V, CF, I = R.Vector3, R.CFrame, R.Instance

local L = R.Lighting
local before = { Brightness = L.Brightness, Ambient = L.Ambient, ExposureCompensation = L.ExposureCompensation }
R.camera.CFrame = CF.new(0, 10, 0)

local function find(parent, name)
	return parent:FindFirstChild(name)
end
local function emitter(name)
	local w = R.Workspace:FindFirstChild("DeformableSnowWeather")
	for _, d in w:GetDescendants() do
		if d.ClassName == "ParticleEmitter" and d.Name == name then
			return d
		end
	end
end

SnowWeather.start({ tier = Quality.TIERS[4], surfaceAt = function()
	return 0
end, exclude = {} })
R.run(3)

T.describe("winter light, fog and clouds", function()
	T.ok(L.Brightness ~= before.Brightness, "lighting changed")
	T.ok(find(L, "DeformableSnowAtmosphere") ~= nil, "fog (Atmosphere)")
	T.ok(find(R.Workspace.Terrain, "DeformableSnowClouds") ~= nil, "clouds")
	T.ok(find(L, "DeformableSnowGrade") and find(L, "DeformableSnowBloom") and find(L, "DeformableSnowSunRays"), "post effects on High")
	T.ok(find(L, "DeformableSnowDepth") ~= nil, "depth of field on High")
	T.ok(R.Workspace.GlobalWind.Magnitude > 0, "wind blows")
end)

T.describe("falling snow", function()
	for _, name in { "Flakes", "Fine", "Clumps", "Bokeh" } do
		local e = emitter(name)
		T.ok(e and e.Rate > 0, `{name} falling`)
		T.ok(e and e.LockedToPart == false and e.WindAffectsDrag == true, `{name} in world space, wind-driven`)
	end
	T.ok(emitter("Fine").Speed[1] > emitter("Clumps").Speed[2], "some flakes fall faster than others")
	R.camera.CFrame = CF.new(30, 10, 0)
	R.run(0.5)
	local box = R.Workspace.DeformableSnowWeather.SnowfallFar
	T.ok(math.abs(box.CFrame.Position.X - 30) < 45, "the snow follows the camera")
	local cleared = R.cleared or 0
	R.camera.CFrame = CF.new(500, 10, 0)
	R.frame(1 / 60)
	T.ok((R.cleared or 0) > cleared, "teleport: the air refills at once")
end)

T.describe("under a roof", function()
	local roof = I.new("Part")
	roof.Size = V.new(60, 1, 60)
	roof.CFrame = CF.new(500, 30, 0)
	roof.Anchored = true
	roof.Parent = R.Workspace
	R.run(3)
	T.ok(emitter("Flakes").Rate < 1, `no snow falls indoors ({emitter("Flakes").Rate})`)
	roof:Destroy()
	R.run(3)
	T.ok(emitter("Flakes").Rate > 1, "and it starts again outside")
end)

T.describe("lens flare", function()
	SnowWeather.pin(0, 1) -- light snow, sun out
	R.run(20)
	local sun = L:GetSunDirection()
	local pos = V.new(500, 10, 0)
	R.camera.CFrame = CF.lookAt(pos, pos + sun)
	R.run(0.5)
	local gui = R.playerGui:FindFirstChild("DeformableSnowLensFlare")
	T.ok(gui and gui.Enabled, "visible when looking at the sun")
	T.ok(emitter("Glints").Rate > 0, "flakes glint in the sun")
	R.camera.CFrame = CF.lookAt(pos, pos - sun)
	R.run(0.2)
	T.ok(not gui.Enabled, "gone when looking away")
	R.camera.CFrame = CF.lookAt(pos, pos + sun)
	local wall = I.new("Part")
	wall.Size = V.new(40, 40, 40)
	wall.CFrame = CF.new(pos + sun * 40)
	wall.Anchored = true
	wall.Parent = R.Workspace
	R.run(0.5)
	T.ok(not gui.Enabled, "gone when something hides the sun")
	wall:Destroy()
	SnowWeather.pin(1, 0) -- blizzard
	R.run(20)
	T.eq(emitter("Glints").Rate, 0, "no glints in a blizzard")
	T.ok(find(L, "DeformableSnowAtmosphere").Density > 0.5, "thick fog in a blizzard")
	SnowWeather.pin(nil, nil)
end)

T.describe("quality levels", function()
	local high = emitter("Flakes").Rate
	SnowWeather.setTier(Quality.TIERS[1])
	R.run(0.5)
	T.ok(emitter("Flakes").Rate < high * 0.5, "Potato: far fewer flakes")
	T.eq(emitter("Bokeh").Rate, 0, "Potato: no out-of-focus flakes")
	T.eq(find(L, "DeformableSnowDepth"), nil, "Potato: no depth of field")
	T.eq(find(L, "DeformableSnowSunRays"), nil, "Potato: no sun rays")
	SnowWeather.setTier(Quality.TIERS[4])
	R.run(0.5)
	T.ok(find(L, "DeformableSnowDepth") ~= nil, "back on High")
end)

T.describe("stop puts everything back", function()
	SnowWeather.stop()
	T.eq(L.Brightness, before.Brightness, "brightness restored")
	T.eq(L.Ambient, before.Ambient, "ambient restored")
	T.eq(L.ExposureCompensation, before.ExposureCompensation, "exposure restored")
	T.eq(find(L, "DeformableSnowAtmosphere"), nil, "our fog removed")
	T.eq(find(L, "DeformableSnowGrade"), nil, "our effects removed")
	T.eq(R.Workspace:FindFirstChild("DeformableSnowWeather"), nil, "snow removed")
	T.eq(R.Workspace.GlobalWind.Magnitude, 0, "wind restored")
	T.eq(#R.renderBindings, 0, "no per-frame work left")
end)

return T.finish("weather")
