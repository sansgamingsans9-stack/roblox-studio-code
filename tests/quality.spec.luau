--!nocheck
-- Quality tiers on their own (run with tools/test.sh): the starting tier per device and the
-- frame-rate watcher that lowers/raises it.
local T = require("./testlib")
local Quality = require("./mods/Quality")

local POTATO, LOW, MEDIUM, HIGH = 1, 2, 3, 4

T.describe("tiers are ordered from cheapest to best", function()
	local names = {}
	for i, tier in Quality.TIERS do
		names[i] = tier.name
		if i > 1 then
			local prev = Quality.TIERS[i - 1]
			T.ok(tier.maxParts > prev.maxParts, `{tier.name}: more Parts than {prev.name}`)
			T.ok(tier.lodScale >= prev.lodScale, `{tier.name}: detail reaches at least as far`)
			T.ok(tier.smoothness <= prev.smoothness, `{tier.name}: at least as smooth`)
			T.ok(tier.particles >= prev.particles, `{tier.name}: at least as many puffs`)
			T.ok(tier.deformEvery <= prev.deformEvery, `{tier.name}: presses at least as often`)
		end
	end
	T.eq(table.concat(names, ","), "Potato,Low,Medium,High", "tier names")
end)

T.describe("starting tier per device", function()
	local pc = { touchOnly = false, console = false, graphicsLevel = nil }
	T.eq(Quality.initialTier(pc), HIGH, "PC with automatic graphics")
	T.eq(Quality.initialTier({ touchOnly = true, console = false }), LOW, "phone / tablet")
	T.eq(Quality.initialTier({ touchOnly = false, console = true }), MEDIUM, "console")
	T.eq(Quality.initialTier({ touchOnly = false, console = false, graphicsLevel = 1 }), POTATO, "graphics 1")
	T.eq(Quality.initialTier({ touchOnly = false, console = false, graphicsLevel = 3 }), LOW, "graphics 3")
	T.eq(Quality.initialTier({ touchOnly = false, console = false, graphicsLevel = 6 }), MEDIUM, "graphics 6")
	T.eq(Quality.initialTier({ touchOnly = false, console = false, graphicsLevel = 10 }), HIGH, "graphics 10")
	T.eq(Quality.initialTier({ touchOnly = true, console = false, graphicsLevel = 10 }), LOW, "phone stays Low at max graphics")
	T.eq(Quality.initialTier({ touchOnly = true, console = false, graphicsLevel = 1 }), POTATO, "phone at graphics 1")
	T.eq(Quality.initialTier(pc, "Potato"), POTATO, "forced Potato")
	T.eq(Quality.initialTier({ touchOnly = true, console = false }, "High"), HIGH, "forced High wins over the device")
	T.eq(Quality.initialTier(pc, "Ultra"), HIGH, "unknown forced name is ignored")
end)

-- feeds `seconds` of frames at `fps`; returns every tier change in order
local function feed(m, seconds, fps)
	local changes = {}
	local dt = 1 / fps
	for _ = 1, math.floor(seconds * fps + 0.5) do
		local new = Quality.step(m, dt)
		if new then
			table.insert(changes, new)
		end
	end
	return changes
end

-- like feed, but the frame rate depends on the current tier (the snow is what costs time)
local function feedBy(m, seconds, fpsOf)
	local changes = {}
	local t = 0
	while t < seconds do
		local dt = 1 / fpsOf(m.tier)
		t += dt
		local new = Quality.step(m, dt)
		if new then
			table.insert(changes, new)
		end
	end
	return changes
end

T.describe("frame-rate watcher", function()
	-- High runs at 25 FPS, Medium at 33, Low at 45
	local heavy = function(tier)
		return ({ 60, 45, 33, 25 })[tier]
	end
	local m = Quality.newMonitor(HIGH, HIGH, false)
	T.eq(#feed(m, 4.5, 15), 0, "loading hitches during the warm-up do not count")
	T.eq(#feed(m, 2, 60), 0, "smooth frames: no change")
	T.eq(#feed(m, 1.5, 25), 0, "a short slowdown is tolerated")
	T.eq(#feed(m, 2, 60), 0, "recovers")
	local down = feedBy(m, 5, heavy)
	T.eq(#down, 1, "steps down once after a few slow seconds")
	T.eq(down[1], MEDIUM, "High -> Medium")
	T.eq(#feedBy(m, 5, heavy), 0, "waits (cooldown) before stepping again")
	T.eq(feedBy(m, 5, heavy)[1], LOW, "still slow but it helped: Medium -> Low")
	T.eq(#feedBy(m, 60, heavy), 0, "fast enough on Low: stays")
	T.eq(m.tier, LOW, "settles on Low")

	-- a device that is slow whatever the snow does
	local m5 = Quality.newMonitor(LOW, HIGH, false)
	feed(m5, 6, 60)
	T.eq(feed(m5, 5, 20)[1], POTATO, "Low -> Potato")
	T.eq(feed(m5, 60, 10)[1], LOW, "Potato did not help: back to Low")
	T.eq(#feed(m5, 60, 10), 0, "and stays there")

	-- a slowdown that has nothing to do with a recent step up does not delay the next one
	local m4 = Quality.newMonitor(MEDIUM, HIGH, false)
	feed(m4, 6, 60)
	T.eq(feedBy(m4, 5, heavy)[1], LOW, "slow: Medium -> Low")
	T.eq(feed(m4, 30, 60)[1], MEDIUM, "back up after ~20 smooth seconds")

	local m2 = Quality.newMonitor(LOW, MEDIUM, false)
	feed(m2, 6, 60)
	T.eq(#feed(m2, 10, 60), 0, "does not climb after only a few smooth seconds")
	T.eq(feed(m2, 20, 60)[1], MEDIUM, "climbs after ~20 smooth seconds")
	T.eq(#feed(m2, 120, 60), 0, "never above maxTier")

	-- a lag spike now and then (an asset loading, a big explosion) must not lower the tier
	local m3 = Quality.newMonitor(HIGH, HIGH, false)
	feed(m3, 6, 60)
	local changed = 0
	for _ = 1, 20 do
		changed += #feed(m3, 2, 60)
		changed += #feed(m3, 0.6, 2) -- one frame frozen for half a second
	end
	T.eq(changed, 0, "occasional hitches do not lower the tier")
	-- a game that is slow all the time does
	T.eq(feed(m3, 6, 8)[1], MEDIUM, "sustained 8 FPS lowers it")
end)

T.describe("a device capped at 30 FPS keeps its quality", function()
	local m = Quality.newMonitor(HIGH, HIGH, false)
	local changes = feed(m, 120, 30)
	T.eq(table.concat(changes, ","), "3,4", "tries one step down, sees no gain, goes back")
	T.eq(m.tier, HIGH, "ends on High")
	-- later the snow gets heavy (many players): much slower than the cap, stepping down helps
	local heavy = function(tier)
		return ({ 30, 30, 22, 14 })[tier]
	end
	local down = feedBy(m, 20, heavy)
	T.eq(down[1], MEDIUM, "a new, worse slowdown still lowers the quality")
	T.eq(m.tier, LOW, "down to where it runs at the cap again")
end)

T.describe("no flip-flopping", function()
	-- Medium runs fine, High is too slow: the watcher tries High less and less often
	local m = Quality.newMonitor(MEDIUM, HIGH, false)
	local ups, t, upTimes = 0, 0, {}
	local fps = function()
		return if m.tier == HIGH then 25 else 60
	end
	while t < 900 do
		local new = Quality.step(m, 1 / fps())
		t += 1 / fps()
		if new == HIGH then
			ups += 1
			table.insert(upTimes, t)
		end
	end
	T.ok(ups >= 2 and ups <= 8, `tries the higher tier a few times, not constantly ({ups} in 15 min)`)
	local gaps = {}
	for i = 2, #upTimes do
		gaps[i - 1] = upTimes[i] - upTimes[i - 1]
	end
	T.ok(#gaps >= 2 and gaps[#gaps] > gaps[1], "waits longer after every failed try")
	T.eq(m.tier, MEDIUM, "settles on the tier that runs well")
end)

T.describe("a forced tier never changes", function()
	local m = Quality.newMonitor(HIGH, HIGH, true)
	T.eq(#feed(m, 60, 10), 0, "forced: stays")
end)

return T.finish("quality")
