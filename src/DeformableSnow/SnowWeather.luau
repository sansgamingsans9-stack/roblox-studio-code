--!strict
--[[
	SnowWeather
	Snowy weather on this player's screen (nothing here is replicated, every client runs its own):
	  * falling snow in layers: fine fast flakes, ordinary flakes, slow tumbling clumps, a few big
	    soft out-of-focus flakes right in front of the camera, and flakes that glint in the sun.
	    They come from boxes that follow the camera (the flakes themselves stay where they are in
	    the world), drift with the wind and stop under roofs,
	  * fog (Atmosphere), clouds, cold winter light and colour grading that follow the weather:
	    heavier snow = thicker fog and flatter light, light snow = the sun breaks through,
	  * when the sun shows: a gentle lens flare, sun rays, glinting flakes and glittering snow,
	  * gusts of wind (Workspace.GlobalWind).
	Everything follows the quality level (Quality.luau) and is undone by SnowWeather.stop().
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.Config)
local Quality = require(script.Parent.Quality)
local WeatherModel = require(script.Parent.WeatherModel)

local SnowWeather = {}

local W = Config.Weather
local lerp, lerp3, approach = WeatherModel.lerp, WeatherModel.lerp3, WeatherModel.approach
local smoothstep = WeatherModel.smoothstep

------------------------------------------------------------------------ textures
-- built into every Roblox client (nothing to upload)
-- a soft white round dot (Gaussian alpha): flakes, clumps and out-of-focus flakes
local TEX_FLAKE = "rbxasset://textures/particles/explosion01_implosion_main.dds"
local TEX_SOFT = TEX_FLAKE
-- an 8-ray star with a soft core: glints
local TEX_STAR = "rbxasset://textures/particles/sparkles_main.dds"
-- for the screen lens flare (PNG files that ship with every player's client): a faint radial
-- glow around the sun, and plain discs for the ghosts
local TEX_GLOW = "rbxasset://textures/ui/InGameMenu/BackgroundGlow.png"
local TEX_GHOST = "rbxasset://textures/whiteCircle.png"

------------------------------------------------------------------------ the look
-- { light snowfall, blizzard } for the fog and sky; sunny values blend in with `sun`
local FOG_DENSITY = { 0.3, 0.6 }
local FOG_HAZE = { 1.4, 3.2 }
local FOG_OFFSET = { 0.22, 0.08 }
local FOG_COLOR = { { 0.80, 0.84, 0.90 }, { 0.84, 0.86, 0.90 } }
local FOG_DECAY = { { 0.53, 0.58, 0.68 }, { 0.70, 0.73, 0.79 } }

-- light: overcast vs sunny spell
local BRIGHTNESS = { overcast = 1.9, sunny = 2.8 }
local EXPOSURE = { overcast = 0.15, sunny = -0.1 }
local AMBIENT = { overcast = { 0.42, 0.45, 0.52 }, sunny = { 0.36, 0.39, 0.47 } }
local OUTDOOR_AMBIENT = { overcast = { 0.62, 0.66, 0.74 }, sunny = { 0.50, 0.54, 0.63 } }
local SHIFT_TOP = { overcast = { 0.78, 0.82, 0.90 }, sunny = { 1.0, 0.93, 0.84 } }
local SHIFT_BOTTOM = { overcast = { 0.30, 0.33, 0.40 }, sunny = { 0.24, 0.28, 0.38 } }
local SHADOW_SOFTNESS = { overcast = 0.9, sunny = 0.25 }
local TINT = { overcast = { 0.94, 0.97, 1.0 }, sunny = { 1.0, 0.99, 0.97 } }
local SATURATION = { overcast = -0.14, sunny = -0.03 }
local CONTRAST = { overcast = 0.04, sunny = 0.1 }

------------------------------------------------------------------------ falling snow
type LayerSpec = {
	name: string,
	near: boolean, -- emitted from the small box right around the camera
	count: number, -- flakes in the air at full snowfall on High quality
	size: { number }, -- min, max (studs)
	speed: { number }, -- fall speed range (studs/s)
	lifetime: { number },
	drag: number,
	spread: number, -- degrees
	rotSpeed: number,
	transparency: number, -- how faint at most
	lightEmission: number,
	brightness: number,
	texture: string,
	squash: number?, -- stretched along the fall (fast flakes look like short streaks)
	twinkle: boolean?,
	-- share of `count` at a given intensity (0..1) and sun (0..1)
	share: (intensity: number, sun: number) -> number,
}

local LAYERS: { LayerSpec } = {
	{
		-- the ordinary flakes
		name = "Flakes",
		near = false,
		count = 900,
		size = { 0.11, 0.2 },
		speed = { 3.5, 6.5 },
		lifetime = { 7, 9 },
		drag = 0.5,
		spread = 18,
		rotSpeed = 45,
		transparency = 0.08,
		lightEmission = 0.15,
		brightness = 1,
		texture = TEX_FLAKE,
		share = function(i: number, _sun: number): number
			return 0.12 + 0.88 * i
		end,
	},
	{
		-- small, hard, fast ones (they look like short streaks)
		name = "Fine",
		near = false,
		count = 700,
		size = { 0.05, 0.08 },
		speed = { 9, 15 },
		lifetime = { 3.2, 4.2 },
		drag = 0.25,
		spread = 8,
		rotSpeed = 0,
		transparency = 0.3,
		lightEmission = 0.2,
		brightness = 1,
		texture = TEX_FLAKE,
		squash = -0.6,
		share = function(i: number, _sun: number): number
			return 0.08 + 0.92 * i * i
		end,
	},
	{
		-- big, slow, tumbling clumps (mostly in heavy snowfall)
		name = "Clumps",
		near = false,
		count = 140,
		size = { 0.24, 0.4 },
		speed = { 1.8, 3.2 },
		lifetime = { 10, 13 },
		drag = 0.9,
		spread = 30,
		rotSpeed = 120,
		transparency = 0.05,
		lightEmission = 0.1,
		brightness = 1,
		texture = TEX_SOFT,
		share = function(i: number, _sun: number): number
			return 0.1 + 0.9 * smoothstep(0.25, 0.9, i)
		end,
	},
	{
		-- big soft flakes right in front of the lens, out of focus
		name = "Bokeh",
		near = true,
		count = 16,
		size = { 0.5, 1.1 },
		speed = { 1.2, 2.6 },
		lifetime = { 5, 7 },
		drag = 1.2,
		spread = 35,
		rotSpeed = 20,
		transparency = 0.8,
		lightEmission = 0.3,
		brightness = 1,
		texture = TEX_SOFT,
		share = function(i: number, _sun: number): number
			return 0.25 + 0.75 * i
		end,
	},
	{
		-- flakes that catch the sun and glint (a tiny, soft lens flare each)
		name = "Glints",
		near = false,
		count = 60,
		size = { 0.16, 0.3 },
		speed = { 3, 5.5 },
		lifetime = { 4.5, 6.5 },
		drag = 0.5,
		spread = 18,
		rotSpeed = 140,
		transparency = 0.25,
		lightEmission = 0.6,
		brightness = 2.2,
		texture = TEX_STAR,
		twinkle = true,
		share = function(i: number, sun: number): number
			if sun < 0.03 then
				return 0 -- (no sun to catch)
			end
			return sun * (0.4 + 0.6 * (1 - i))
		end,
	},
}

-- the boxes the flakes come from (studs): far = around and above the camera, near = in front of it
local FAR_RADIUS, FAR_HEIGHT = 46, 52
local NEAR_SIZE = 9

------------------------------------------------------------------------ state
type Layer = {
	spec: LayerSpec,
	emitter: ParticleEmitter,
	life: number, -- mean lifetime
}

local started = false
local tier: Quality.Tier = Quality.TIERS[4]
local surfaceAt: ((x: number, z: number) -> number?)? = nil
local excludeExtra: { Instance } = {}

local folder: Folder
local farBox: Part
local nearBox: Part
local layers: { Layer } = {}
local sparkleAttachment: Attachment?
local sparkleEmitter: ParticleEmitter?
local flareGui: ScreenGui?
local flareGhosts: { { image: ImageLabel, at: number, size: number, alpha: number } } = {}
local flareGlow: ImageLabel?

local atmosphere: Atmosphere?
local ownAtmosphere = false
local clouds: Clouds?
local ownClouds = false
local bloom: BloomEffect?
local grade: ColorCorrectionEffect?
local sunRays: SunRaysEffect?
local blur: DepthOfFieldEffect?

local saved: { [Instance]: { [string]: any } } = {}
local savedWind: Vector3? = nil

local settings: WeatherModel.Settings
local state: WeatherModel.State
local t0 = 0
local smooth = {
	intensity = 0.5,
	sun = 0,
	indoor = 0,
	occluded = 0,
}
local indoorTarget = 0
-- weather held by SnowWeather.pin (nil = follow the model)
local pinned: { intensity: number?, sun: number? } = {}
local lastCam: Vector3? = nil
local camVel = Vector3.zero
local slowTimer, rayTimer = 0, 0
local sparkleBudget = 0
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

------------------------------------------------------------------------ helpers
local function rgb(c: { number }): Color3
	return Color3.new(c[1], c[2], c[3])
end

-- Remembers a property's original value (once) so stop() can put it back.
local function remember(inst: Instance, prop: string)
	local t = saved[inst]
	if not t then
		t = {}
		saved[inst] = t
	end
	if t[prop] == nil then
		t[prop] = (inst :: any)[prop]
	end
end

-- Sets a property, remembering the original first; skips tiny changes (no needless updates).
local function set(inst: Instance, prop: string, value: any)
	remember(inst, prop)
	local cur = (inst :: any)[prop]
	if typeof(value) == "number" and typeof(cur) == "number" then
		if math.abs(cur - value) < 1e-3 then
			return
		end
	elseif typeof(value) == "Color3" and typeof(cur) == "Color3" then
		if math.abs(cur.R - value.R) + math.abs(cur.G - value.G) + math.abs(cur.B - value.B) < 2e-3 then
			return
		end
	elseif cur == value then
		return
	end
	(inst :: any)[prop] = value
end

local function camera(): Camera?
	return Workspace.CurrentCamera
end

local function excludeList(): { Instance }
	local list: { Instance } = { folder }
	for _, inst in excludeExtra do
		table.insert(list, inst)
	end
	local char = Players.LocalPlayer and Players.LocalPlayer.Character
	if char then
		table.insert(list, char)
	end
	return list
end

------------------------------------------------------------------------ building
local function newBox(name: string, size: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Locked = true
	p.Size = size
	p.Parent = folder
	return p
end

local function buildLayer(spec: LayerSpec): Layer
	local e = Instance.new("ParticleEmitter")
	e.Name = spec.name
	e.Texture = spec.texture
	e.Shape = Enum.ParticleEmitterShape.Box
	e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
	e.EmissionDirection = Enum.NormalId.Bottom
	e.LockedToPart = false -- flakes stay where they are in the world when the box moves
	e.Orientation = Enum.ParticleOrientation.FacingCamera
	e.Speed = NumberRange.new(spec.speed[1], spec.speed[2])
	e.SpreadAngle = Vector2.new(spec.spread, spec.spread)
	e.Lifetime = NumberRange.new(spec.lifetime[1], spec.lifetime[2])
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-spec.rotSpeed, spec.rotSpeed)
	e.Drag = spec.drag
	e.WindAffectsDrag = true
	-- gravity keeps them falling at their own speed while the drag makes them follow the wind
	local fall = (spec.speed[1] + spec.speed[2]) * 0.5
	e.Acceleration = Vector3.new(0, -fall * spec.drag, 0)
	local mid = (spec.size[1] + spec.size[2]) * 0.5
	local env = (spec.size[2] - spec.size[1]) * 0.5
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, mid, env),
		NumberSequenceKeypoint.new(1, mid, env),
	})
	local a = spec.transparency
	if spec.twinkle then
		-- glints sparkle twice on their way down, and are nearly invisible in between
		e.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.18, 0.95),
			NumberSequenceKeypoint.new(0.28, a),
			NumberSequenceKeypoint.new(0.38, 0.95),
			NumberSequenceKeypoint.new(0.62, 0.95),
			NumberSequenceKeypoint.new(0.72, a),
			NumberSequenceKeypoint.new(0.82, 0.95),
			NumberSequenceKeypoint.new(1, 1),
		})
	else
		-- fade in and out (no popping)
		e.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.08, a),
			NumberSequenceKeypoint.new(0.85, a),
			NumberSequenceKeypoint.new(1, 1),
		})
	end
	if spec.squash then
		e.Squash = NumberSequence.new(spec.squash)
	end
	e.Color = ColorSequence.new(Color3.new(0.96, 0.98, 1))
	e.LightEmission = spec.lightEmission
	e.LightInfluence = 0.75
	e.Brightness = spec.brightness
	e.Rate = 0
	e.Parent = if spec.near then nearBox else farBox
	return { spec = spec, emitter = e, life = (spec.lifetime[1] + spec.lifetime[2]) * 0.5 }
end

local function buildSparkles()
	local holder = newBox("SnowSparkles", Vector3.new(0.2, 0.2, 0.2))
	local att = Instance.new("Attachment")
	att.Parent = holder
	local e = Instance.new("ParticleEmitter")
	e.Name = "Sparkles"
	e.Texture = TEX_STAR
	e.Rate = 0
	e.Speed = NumberRange.new(0)
	e.Lifetime = NumberRange.new(0.25, 0.7)
	e.Rotation = NumberRange.new(0, 360)
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.02),
		NumberSequenceKeypoint.new(0.4, 0.12, 0.04),
		NumberSequenceKeypoint.new(1, 0.02),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.4, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.LightEmission = 0.7
	e.LightInfluence = 0
	e.Brightness = 2.5
	e.LockedToPart = false
	e.Parent = att
	sparkleAttachment = att
	sparkleEmitter = e
end

local function buildFlare(): ()
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "DeformableSnowLensFlare"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = -100 -- underneath the game's own interface
	gui.Enabled = false
	local function image(size: number, color: Color3, texture: string): ImageLabel
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Image = texture
		img.ImageColor3 = color
		img.ImageTransparency = 1
		img.Size = UDim2.fromOffset(size, size)
		img.Parent = gui
		return img
	end
	-- a soft halo around the sun, then faint ghosts along the line through the screen centre
	flareGlow = image(220, Color3.new(1, 0.96, 0.88), TEX_GLOW)
	table.clear(flareGhosts)
	for _, g in {
		{ at = 0.35, size = 0.07, alpha = 0.16, color = Color3.new(0.75, 0.9, 1) },
		{ at = 0.62, size = 0.04, alpha = 0.2, color = Color3.new(1, 0.85, 0.7) },
		{ at = 1.18, size = 0.12, alpha = 0.1, color = Color3.new(0.7, 1, 0.85) },
		{ at = 1.45, size = 0.05, alpha = 0.14, color = Color3.new(0.85, 0.8, 1) },
		{ at = 1.9, size = 0.18, alpha = 0.07, color = Color3.new(0.8, 0.9, 1) },
	} do
		table.insert(flareGhosts, { image = image(10, g.color, TEX_GHOST), at = g.at, size = g.size, alpha = g.alpha })
	end
	gui.Parent = pg
	flareGui = gui
end

------------------------------------------------------------------------ lighting
local function setupLighting()
	if not W.ChangeLighting then
		return
	end
	if W.Fog then
		local existing = Lighting:FindFirstChildOfClass("Atmosphere")
		if existing then
			atmosphere = existing
		else
			local a = Instance.new("Atmosphere")
			a.Name = "DeformableSnowAtmosphere"
			a.Parent = Lighting
			atmosphere = a
			ownAtmosphere = true
		end
	end
	if W.Clouds then
		local terrain = Workspace:FindFirstChildOfClass("Terrain")
		if terrain then
			local existing = terrain:FindFirstChildOfClass("Clouds")
			if existing then
				clouds = existing
			else
				local c = Instance.new("Clouds")
				c.Name = "DeformableSnowClouds"
				c.Parent = terrain
				clouds = c
				ownClouds = true
			end
		end
	end
	local g = Instance.new("ColorCorrectionEffect")
	g.Name = "DeformableSnowGrade"
	g.Parent = Lighting
	grade = g
	if not W.KeepTimeOfDay then
		-- a low winter sun: long, soft shadows
		set(Lighting, "GeographicLatitude", 52)
	end
end

-- Effects that depend on the quality level.
local function applyTierEffects()
	if not started or not W.ChangeLighting then
		return
	end
	local function toggle<T>(current: T?, want: boolean, make: () -> T): T?
		if want and not current then
			return make()
		elseif not want and current then
			(current :: any):Destroy()
			return nil
		end
		return current
	end
	bloom = toggle(bloom, tier.bloom, function(): BloomEffect
		local b = Instance.new("BloomEffect")
		b.Name = "DeformableSnowBloom"
		-- only the brightest things glow: sunlit snow, glints
		b.Intensity = 0.4
		b.Size = 28
		b.Threshold = 1.6
		b.Parent = Lighting
		return b
	end)
	sunRays = toggle(sunRays, tier.sunRays and W.LensFlares, function(): SunRaysEffect
		local r = Instance.new("SunRaysEffect")
		r.Name = "DeformableSnowSunRays"
		r.Intensity = 0
		r.Spread = 0.55
		r.Parent = Lighting
		return r
	end)
	local wantBlur = tier.depthOfField and W.DepthOfField and not Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	if blur then
		wantBlur = tier.depthOfField and W.DepthOfField
	end
	blur = toggle(blur, wantBlur, function(): DepthOfFieldEffect
		local d = Instance.new("DepthOfFieldEffect")
		d.Name = "DeformableSnowDepth"
		d.NearIntensity = 0
		d.FocusDistance = 40
		d.InFocusRadius = 70
		d.FarIntensity = 0
		d.Parent = Lighting
		return d
	end)
end

-- Moves the light, fog and colours a step towards what the weather looks like now.
local function updateLighting()
	if not W.ChangeLighting then
		return
	end
	local i, sun, indoor = smooth.intensity, smooth.sun, smooth.indoor
	if atmosphere then
		local a = atmosphere :: Atmosphere
		-- indoors the fog thins out (the air in a room is clear)
		set(a, "Density", lerp(FOG_DENSITY[1], FOG_DENSITY[2], i) * (1 - 0.5 * indoor))
		set(a, "Haze", lerp(FOG_HAZE[1], FOG_HAZE[2], i))
		set(a, "Offset", lerp(FOG_OFFSET[1], FOG_OFFSET[2], i))
		set(a, "Color", rgb(lerp3(FOG_COLOR[1], FOG_COLOR[2], i)))
		set(a, "Decay", rgb(lerp3(FOG_DECAY[1], FOG_DECAY[2], i)))
		set(a, "Glare", 0.6 * sun)
	end
	if clouds then
		local c = clouds :: Clouds
		set(c, "Cover", math.clamp(0.62 + 0.36 * i - 0.25 * sun, 0, 1))
		set(c, "Density", math.clamp(0.4 + 0.45 * i, 0, 1))
		set(c, "Color", Color3.new(0.9, 0.92, 0.95))
		set(c, "Enabled", true)
	end
	set(Lighting, "Brightness", lerp(BRIGHTNESS.overcast, BRIGHTNESS.sunny, sun))
	set(Lighting, "ExposureCompensation", lerp(EXPOSURE.overcast, EXPOSURE.sunny, sun))
	set(Lighting, "Ambient", rgb(lerp3(AMBIENT.overcast, AMBIENT.sunny, sun)))
	set(Lighting, "OutdoorAmbient", rgb(lerp3(OUTDOOR_AMBIENT.overcast, OUTDOOR_AMBIENT.sunny, sun)))
	set(Lighting, "ColorShift_Top", rgb(lerp3(SHIFT_TOP.overcast, SHIFT_TOP.sunny, sun)))
	set(Lighting, "ColorShift_Bottom", rgb(lerp3(SHIFT_BOTTOM.overcast, SHIFT_BOTTOM.sunny, sun)))
	set(Lighting, "ShadowSoftness", lerp(SHADOW_SOFTNESS.overcast, SHADOW_SOFTNESS.sunny, sun))
	set(Lighting, "EnvironmentDiffuseScale", 1)
	set(Lighting, "EnvironmentSpecularScale", 1)
	if grade then
		local g = grade :: ColorCorrectionEffect
		g.TintColor = rgb(lerp3(TINT.overcast, TINT.sunny, sun))
		g.Saturation = lerp(SATURATION.overcast, SATURATION.sunny, sun)
		g.Contrast = lerp(CONTRAST.overcast, CONTRAST.sunny, sun)
		g.Brightness = 0.02 * sun
	end
	if sunRays then
		-- a hint of god rays when the sun shows (not too intense)
		(sunRays :: SunRaysEffect).Intensity = 0.055 * sun * (1 - indoor)
	end
	if blur then
		(blur :: DepthOfFieldEffect).FarIntensity = 0.06 + 0.16 * i
	end
end

------------------------------------------------------------------------ per frame
local function setRates()
	local mult = tier.snowParticles * (1 - smooth.indoor)
	for _, layer in layers do
		local spec = layer.spec
		local on = true
		if spec.name == "Bokeh" then
			on = tier.bokeh
		elseif spec.name == "Glints" then
			on = tier.glints and W.LensFlares
		end
		local count = if on then spec.count * mult * spec.share(smooth.intensity, smooth.sun) else 0
		layer.emitter.Rate = count / layer.life
	end
end

-- Fills the air with flakes at once (start, teleport) instead of waiting for them to fall in.
local function fill()
	for _, layer in layers do
		local e = layer.emitter
		e:Clear()
		local n = math.floor(e.Rate * layer.life * 0.8)
		if n > 0 then
			e:Emit(n)
		end
	end
end

-- Is the camera under a roof? (snow and most of the fog stop there)
local function checkIndoor(camPos: Vector3)
	rayParams.FilterDescendantsInstances = excludeList()
	local hits = 0
	for _, o in { Vector3.zero, Vector3.new(5, 0, 3), Vector3.new(-4, 0, -5) } do
		if Workspace:Raycast(camPos + o, Vector3.new(0, 150, 0), rayParams) then
			hits += 1
		end
	end
	indoorTarget = if hits >= 2 then 1 else 0
end

-- Is the sun hidden behind something (for the lens flare)?
local function checkSunBlocked(camPos: Vector3): boolean
	local dir = Lighting:GetSunDirection()
	return Workspace:Raycast(camPos, dir * 3000, rayParams) ~= nil
end

local function updateFlare(cam: Camera)
	local gui = flareGui
	if not gui then
		return
	end
	local want = W.LensFlares and tier.lensFlare
	local sunDir = Lighting:GetSunDirection()
	local camCF = cam.CFrame
	local facing = camCF.LookVector:Dot(sunDir)
	local strength = 0
	if want and sunDir.Y > -0.05 then
		strength = smooth.sun * (1 - smooth.indoor) * (1 - smooth.occluded) * smoothstep(0.55, 0.95, facing)
		-- low in thick fog the sun is only a smudge
		strength *= 1 - 0.7 * smooth.intensity
	end
	if strength < 0.01 then
		gui.Enabled = false
		return
	end
	local sp, _onScreen = cam:WorldToViewportPoint(camCF.Position + sunDir * 1000)
	local vp = cam.ViewportSize
	local sx, sy = sp.X, sp.Y
	local cx, cy = vp.X * 0.5, vp.Y * 0.5
	gui.Enabled = true
	local glow = flareGlow
	if glow then
		local s = vp.Y * 0.32
		glow.Position = UDim2.fromOffset(sx, sy)
		glow.Size = UDim2.fromOffset(s, s)
		glow.ImageTransparency = 1 - strength -- (the texture itself is very faint)
	end
	for _, g in flareGhosts do
		local x = sx + (cx - sx) * g.at
		local y = sy + (cy - sy) * g.at
		local s = vp.Y * g.size
		g.image.Position = UDim2.fromOffset(x, y)
		g.image.Size = UDim2.fromOffset(s, s)
		g.image.ImageTransparency = 1 - g.alpha * strength
	end
end

-- Glitter on sunlit snow: a few tiny sparkles at random spots in front of the camera.
local function updateSparkles(cam: Camera, dt: number)
	local e, att, surface = sparkleEmitter, sparkleAttachment, surfaceAt
	if not e or not att or not surface or not W.GroundSparkles then
		return
	end
	local rate = tier.sparkles * smooth.sun * (1 - smooth.indoor)
	sparkleBudget = math.min(sparkleBudget + rate * dt, 4)
	if sparkleBudget < 1 then
		return
	end
	local camCF = cam.CFrame
	local look = camCF.LookVector
	local base = math.atan2(look.Z, look.X)
	local sunDir = Lighting:GetSunDirection()
	while sparkleBudget >= 1 do
		sparkleBudget -= 1
		local r = 4 + math.random() * 24
		local a = base + (math.random() - 0.5) * 1.6
		local x, z = camCF.Position.X + math.cos(a) * r, camCF.Position.Z + math.sin(a) * r
		local y = surface(x, z)
		if y then
			local p = Vector3.new(x, y + 0.04, z)
			-- only where the sun reaches the snow
			if not Workspace:Raycast(p, sunDir * 400, rayParams) then
				att.WorldPosition = p
				e:Emit(1)
			end
		end
	end
end

local function onRender(dt: number)
	if not started then
		return
	end
	local cam = camera()
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	local last = lastCam
	if last then
		local moved = camPos - last
		if moved.Magnitude > 80 then
			-- teleported: the snow around the old spot is of no use
			lastCam = camPos
			camVel = Vector3.zero
			farBox.CFrame = CFrame.new(camPos + Vector3.new(0, FAR_HEIGHT * 0.25, 0))
			fill()
		elseif dt > 0 then
			camVel += (moved / dt - camVel) * math.min(1, dt * 3)
		end
	end
	lastCam = camPos
	-- the far box leads the camera a little, so there is snow ahead when moving fast
	local lead = Vector3.new(camVel.X, 0, camVel.Z) * 1.2
	if lead.Magnitude > 40 then
		lead = lead.Unit * 40
	end
	farBox.CFrame = CFrame.new(camPos + lead + Vector3.new(0, FAR_HEIGHT * 0.25, 0))
	-- (upright: the flakes fall out of the bottom of their box whichever way the camera looks)
	local look = cam.CFrame.LookVector
	nearBox.CFrame = CFrame.new(camPos + look * (NEAR_SIZE * 0.5 + 1.5) + Vector3.new(0, 1.5, 0))
	updateFlare(cam)
	updateSparkles(cam, dt)
end

local function onHeartbeat(dt: number)
	if not started then
		return
	end
	local t = os.clock() - t0
	state = WeatherModel.sample(settings, t)
	if pinned.intensity then
		state.intensity = pinned.intensity
	end
	if pinned.sun then
		state.sun = pinned.sun
	end
	smooth.intensity = approach(smooth.intensity, state.intensity, dt, 3)
	smooth.sun = approach(smooth.sun, state.sun, dt, 4)
	smooth.indoor = approach(smooth.indoor, indoorTarget, dt, 0.6)

	local cam = camera()
	rayTimer += dt
	if cam and rayTimer >= 0.2 then
		rayTimer = 0
		local camPos = cam.CFrame.Position
		checkIndoor(camPos)
		local blocked = W.LensFlares and tier.lensFlare and smooth.sun > 0.01 and checkSunBlocked(camPos)
		smooth.occluded = if blocked then 1 else 0
	end

	slowTimer += dt
	if slowTimer >= 0.25 then
		slowTimer = 0
		setRates()
		updateLighting()
		if W.ChangeWind then
			Workspace.GlobalWind = Vector3.new(state.windX, 0, state.windZ)
		end
	end
end

------------------------------------------------------------------------ api
export type Options = {
	tier: Quality.Tier,
	-- top of the snow at (x, z) where it is simulated (for the glitter), or nil
	surfaceAt: ((x: number, z: number) -> number?)?,
	-- more things that are not roofs (e.g. the drawn snow)
	exclude: { Instance }?,
}

local renderName = "DeformableSnowWeather"
local heartbeatConn: RBXScriptConnection? = nil

function SnowWeather.start(opts: Options)
	if started or not W.Enabled then
		return
	end
	started = true
	tier = opts.tier
	surfaceAt = opts.surfaceAt
	excludeExtra = opts.exclude or {}
	t0 = os.clock()
	settings = {
		intensity = math.clamp(W.Intensity, 0, 1),
		variation = math.clamp(W.Variation, 0, 1),
		period = math.max(10, W.Period),
		windSpeed = math.max(0, W.WindSpeed),
		windAngle = math.rad(W.WindDirection),
		gustiness = math.clamp(W.Gusts, 0, 1),
		seed = (math.random() * 1000) // 1 + 0.5,
	}
	state = WeatherModel.sample(settings, 0)
	smooth.intensity, smooth.sun = state.intensity, state.sun

	local f = Instance.new("Folder")
	f.Name = "DeformableSnowWeather"
	f.Parent = Workspace
	folder = f
	farBox = newBox("SnowfallFar", Vector3.new(FAR_RADIUS * 2, FAR_HEIGHT, FAR_RADIUS * 2))
	nearBox = newBox("SnowfallNear", Vector3.new(NEAR_SIZE, NEAR_SIZE, NEAR_SIZE))
	table.clear(layers)
	for _, spec in LAYERS do
		table.insert(layers, buildLayer(spec))
	end
	buildSparkles()
	buildFlare()

	if W.ChangeWind then
		savedWind = Workspace.GlobalWind
	end
	setupLighting()
	applyTierEffects()
	updateLighting()

	local cam = camera()
	if cam then
		local camPos = cam.CFrame.Position
		farBox.CFrame = CFrame.new(camPos + Vector3.new(0, FAR_HEIGHT * 0.25, 0))
		lastCam = camPos
	end
	setRates()
	fill()

	-- right after the camera moves, so the boxes and the flare are where the camera is
	RunService:BindToRenderStep(renderName, Enum.RenderPriority.Camera.Value + 1, onRender)
	heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)
end

-- The quality level changed (Quality.luau).
function SnowWeather.setTier(newTier: Quality.Tier)
	tier = newTier
	if started then
		applyTierEffects()
		setRates()
	end
end

--[[
	Holds the weather (for a scripted blizzard, a sunny cutscene...): intensity 0..1 and/or sun
	0..1; nil lets that one follow the natural weather again. Changes blend in over a few seconds.
	  SnowWeather.pin(1, 0)     -- blizzard
	  SnowWeather.pin(0.1, 1)   -- light flurries in sunshine
	  SnowWeather.pin(nil, nil) -- back to normal
]]
function SnowWeather.pin(intensity: number?, sun: number?)
	pinned.intensity = if intensity then math.clamp(intensity, 0, 1) else nil
	pinned.sun = if sun then math.clamp(sun, 0, 1) else nil
end

-- Current weather (for other scripts): intensity 0..1, sun 0..1, indoor 0..1.
function SnowWeather.get(): (number, number, number)
	return smooth.intensity, smooth.sun, smooth.indoor
end

-- Removes the weather and puts the game's lighting back the way it was.
function SnowWeather.stop()
	if not started then
		return
	end
	started = false
	pcall(function()
		RunService:UnbindFromRenderStep(renderName)
	end)
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	for inst, props in saved do
		for prop, value in props do
			pcall(function()
				(inst :: any)[prop] = value
			end)
		end
	end
	table.clear(saved)
	if savedWind then
		Workspace.GlobalWind = savedWind
		savedWind = nil
	end
	for _, inst in { bloom, grade, sunRays, blur, flareGui } :: { Instance? } do
		if inst then
			inst:Destroy()
		end
	end
	bloom, grade, sunRays, blur, flareGui = nil, nil, nil, nil, nil
	if ownAtmosphere and atmosphere then
		atmosphere:Destroy()
	end
	if ownClouds and clouds then
		clouds:Destroy()
	end
	atmosphere, clouds, ownAtmosphere, ownClouds = nil, nil, false, false
	folder:Destroy()
	table.clear(layers)
	sparkleEmitter, sparkleAttachment, flareGlow = nil, nil, nil
	table.clear(flareGhosts)
end

return SnowWeather
