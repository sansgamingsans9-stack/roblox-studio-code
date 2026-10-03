--!strict
--[[
	Quality
	Keeps the snow smooth on every device:
	  * picks a starting quality tier from the device (phone/tablet/console, the player's own
	    graphics quality setting),
	  * watches the frame rate and steps the tier down when the game struggles, and back up when
	    there is headroom again (with hysteresis so it does not flip-flop),
	  * Config.Quality can force a tier.

	Pure logic (the device facts are passed in), so it can be unit-tested outside Roblox.
]]

local Quality = {}

export type Tier = {
	name: string,
	-- multiplies Config.LodDistances
	lodScale: number,
	-- Parts renderer budget (multiplied with Config.MaxSnowParts / 12000)
	maxParts: number,
	-- multiplies Config.PartsSmoothness (bigger = fewer triangles)
	smoothness: number,
	shadows: boolean,
	-- 0..1 amount of snow puffs
	particles: number,
	-- multiplies Config.SimulationDistance
	simDistance: number,
	-- press the snow every Nth frame
	deformEvery: number,
	-- milliseconds per frame for background loading
	budgetMs: number,
	-- seconds between scans for loose parts touching the snow
	scanInterval: number,
	-- Parts kept ready in the pool (boxes, wedges)
	poolBoxes: number,
	poolWedges: number,
}

Quality.TIERS = {
	{
		name = "Potato",
		lodScale = 0.5,
		maxParts = 1800,
		smoothness = 3,
		shadows = false,
		particles = 0,
		simDistance = 0.4,
		deformEvery = 2,
		budgetMs = 1.5,
		scanInterval = 0.6,
		poolBoxes = 60,
		poolWedges = 300,
	},
	{
		name = "Low",
		lodScale = 0.6,
		maxParts = 3500,
		smoothness = 2,
		shadows = false,
		particles = 0.35,
		simDistance = 0.6,
		deformEvery = 2,
		budgetMs = 2,
		scanInterval = 0.4,
		poolBoxes = 100,
		poolWedges = 600,
	},
	{
		name = "Medium",
		lodScale = 0.8,
		maxParts = 7000,
		smoothness = 1.4,
		shadows = true,
		particles = 0.7,
		simDistance = 0.8,
		deformEvery = 1,
		budgetMs = 2.5,
		scanInterval = 0.25,
		poolBoxes = 150,
		poolWedges = 1000,
	},
	{
		name = "High",
		lodScale = 1,
		maxParts = 12000,
		smoothness = 1,
		shadows = true,
		particles = 1,
		simDistance = 1,
		deformEvery = 1,
		budgetMs = 3,
		scanInterval = 0.2,
		poolBoxes = 200,
		poolWedges = 1500,
	},
} :: { Tier }

local INDEX = { Potato = 1, Low = 2, Medium = 3, High = 4 }

export type Device = {
	touchOnly: boolean, -- phone / tablet
	console: boolean,
	graphicsLevel: number?, -- the player's graphics quality 1..10, nil when "Automatic"
}

-- Starting tier for a device.
function Quality.initialTier(device: Device, forced: string?): number
	if forced and INDEX[forced] then
		return INDEX[forced]
	end
	local tier = INDEX.High
	if device.touchOnly then
		tier = INDEX.Low
	elseif device.console then
		tier = INDEX.Medium
	end
	local g = device.graphicsLevel
	if g then
		if g <= 2 then
			tier = math.min(tier, INDEX.Potato)
		elseif g <= 4 then
			tier = math.min(tier, INDEX.Low)
		elseif g <= 7 then
			tier = math.min(tier, INDEX.Medium)
		end
	end
	return tier
end

export type Monitor = {
	tier: number,
	maxTier: number,
	fixed: boolean,
	avgDt: number,
	lowTime: number,
	highTime: number,
	cooldown: number,
	warmup: number,
	-- seconds of smooth frames needed before trying a higher tier (doubles after each failed try)
	upNeed: number,
	lastUp: number,
}

-- Frame-rate watcher. `maxTier` caps how far it may climb (a phone never goes to High).
function Quality.newMonitor(tier: number, maxTier: number, fixed: boolean): Monitor
	return {
		tier = tier,
		maxTier = maxTier,
		fixed = fixed,
		avgDt = 1 / 60,
		lowTime = 0,
		highTime = 0,
		cooldown = 0,
		warmup = 5, -- loading hitches at the start do not count
		upNeed = 20,
		lastUp = -math.huge,
	}
end

--[[
	Feed one frame. Returns the new tier index when it changed, otherwise nil.
	Steps down after ~3 s below ~38 FPS, up after ~20 s above ~55 FPS (longer after a failed try).
]]
function Quality.step(m: Monitor, dt: number): number?
	if m.fixed then
		return nil
	end
	dt = math.clamp(dt, 0, 0.5)
	m.lastUp += dt
	if m.warmup > 0 then
		m.warmup -= dt
		return nil
	end
	-- exponential moving average over roughly half a second
	m.avgDt += (dt - m.avgDt) * math.min(1, dt * 2)
	if m.cooldown > 0 then
		m.cooldown -= dt
		return nil
	end
	local fps = 1 / math.max(m.avgDt, 1e-3)
	if fps < 38 then
		m.lowTime += dt
		m.highTime = 0
	elseif fps > 55 then
		m.highTime += dt
		m.lowTime = 0
	else
		m.lowTime = math.max(0, m.lowTime - dt)
		m.highTime = math.max(0, m.highTime - dt)
	end
	if m.lowTime > 3 and m.tier > 1 then
		m.tier -= 1
		m.lowTime, m.highTime, m.cooldown = 0, 0, 6
		if m.lastUp < 60 then
			-- the higher tier we just tried was too much: wait longer before trying it again
			m.upNeed = math.min(m.upNeed * 2, 320)
		end
		return m.tier
	end
	if m.highTime > m.upNeed and m.tier < m.maxTier then
		m.tier += 1
		m.lowTime, m.highTime, m.cooldown = 0, 0, 10
		m.lastUp = 0
		return m.tier
	end
	return nil
end

return Quality
