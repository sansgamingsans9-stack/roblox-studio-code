--!nocheck
-- The weather model on its own (run with tools/test.sh): smooth drifting snowfall, sun only in
-- light snow, gusty wind within bounds.
local T = require("./testlib")
local WM = require("./mods/WeatherModel")

local base = {
	intensity = 0.45,
	variation = 0.35,
	period = 150,
	windSpeed = 7,
	windAngle = math.rad(30),
	gustiness = 0.6,
	seed = 12.5,
}

local function run(s, seconds, dt, fn)
	local t = 0
	while t <= seconds do
		fn(WM.sample(s, t), t)
		t += dt
	end
end

T.describe("snowfall drifts smoothly around the chosen intensity", function()
	local lo, hi, sum, n = math.huge, -math.huge, 0, 0
	local biggestJump = 0
	local prev
	run(base, 3600, 0.5, function(st)
		T.ok(st.intensity >= 0 and st.intensity <= 1, "intensity within 0..1")
		lo, hi = math.min(lo, st.intensity), math.max(hi, st.intensity)
		sum += st.intensity
		n += 1
		if prev then
			biggestJump = math.max(biggestJump, math.abs(st.intensity - prev))
		end
		prev = st.intensity
	end)
	T.ok(hi - lo > 0.3, `it really changes over an hour ({lo} .. {hi})`)
	T.ok(lo >= base.intensity - base.variation - 1e-6 and hi <= base.intensity + base.variation + 1e-6, "stays within the variation")
	T.near(sum / n, base.intensity, 0.12, "averages out near the chosen intensity")
	T.ok(biggestJump < 0.02, `no sudden jumps ({biggestJump} per half second)`)

	local still = table.clone(base)
	still.variation = 0
	run(still, 600, 1, function(st)
		T.near(st.intensity, 0.45, 1e-9, "variation 0: constant")
	end)
end)

T.describe("the sun only breaks through light snowfall", function()
	local sunnyHeavy, sunnyLight = 0, 0
	local light = table.clone(base)
	light.intensity, light.variation = 0.1, 0
	local heavy = table.clone(base)
	heavy.intensity, heavy.variation = 0.85, 0
	run(heavy, 1800, 1, function(st)
		T.ok(st.sun >= 0 and st.sun <= 1, "sun within 0..1")
		if st.sun > 0.05 then
			sunnyHeavy += 1
		end
	end)
	run(light, 1800, 1, function(st)
		if st.sun > 0.5 then
			sunnyLight += 1
		end
	end)
	T.eq(sunnyHeavy, 0, "never sunny in heavy snow")
	T.ok(sunnyLight > 200, `sunny spells in light snow ({sunnyLight} of 1800 s)`)
	T.ok(sunnyLight < 1700, "but not all the time (clouds come and go)")
end)

T.describe("wind with gusts", function()
	local minSpeed, maxSpeed = math.huge, 0
	local gusts = 0
	local dirOk = true
	run(base, 1200, 0.5, function(st)
		local speed = math.sqrt(st.windX ^ 2 + st.windZ ^ 2)
		minSpeed, maxSpeed = math.min(minSpeed, speed), math.max(maxSpeed, speed)
		if st.gust > 0.3 then
			gusts += 1
		end
		local angle = math.atan2(st.windZ, st.windX)
		if math.abs(angle - base.windAngle) > 0.6 then
			dirOk = false
		end
	end)
	T.ok(minSpeed > 0.3 * base.windSpeed, `never dead calm ({minSpeed})`)
	T.ok(maxSpeed < base.windSpeed * 1.3 * 2.4 + 1e-6, `bounded gusts ({maxSpeed})`)
	T.ok(gusts > 10, `gusts happen ({gusts})`)
	T.ok(dirOk, "the direction only wanders a little")
	local calm = table.clone(base)
	calm.windSpeed = 0
	run(calm, 60, 1, function(st)
		T.eq(st.windX, 0, "no wind configured: none")
	end)
end)

T.describe("helpers", function()
	T.near(WM.approach(0, 1, 1, 1), 1 - math.exp(-1), 1e-9, "approach is exponential")
	local a = 0
	for _ = 1, 100 do
		a = WM.approach(a, 1, 0.01, 1)
	end
	T.near(a, WM.approach(0, 1, 1, 1), 1e-9, "and frame-rate independent")
	T.eq(WM.approach(0.3, 1, 0.1, 0), 1, "tau 0 snaps")
	T.near(WM.smoothstep(0, 1, 0.5), 0.5, 1e-9, "smoothstep middle")
	T.eq(WM.smoothstep(0.62, 0.18, 0.7), 0, "reversed smoothstep")
	local c = WM.lerp3({ 0, 0, 0 }, { 1, 2, 3 }, 0.5)
	T.ok(c[1] == 0.5 and c[2] == 1 and c[3] == 1.5, "lerp3")
end)

return T.finish("weathermodel")
