--!strict
--[[
	WeatherModel
	The weather itself, as plain numbers (no Roblox objects, so it can be unit-tested):
	  * how hard it snows right now (0 = a few flakes, 1 = blizzard), drifting slowly and
	    smoothly around Config.Weather.Intensity,
	  * how much the sun breaks through (only when the snowfall is light),
	  * wind with gusts.
	SnowWeather turns these into Lighting, Atmosphere, particles and lens flares.
]]

local WeatherModel = {}

export type Settings = {
	intensity: number, -- 0..1, the average snowfall
	variation: number, -- 0..1, how far it drifts around the average
	period: number, -- seconds, roughly how long a swing from light to heavy snow takes
	windSpeed: number, -- studs/s
	windAngle: number, -- radians, where the wind blows towards (0 = +X)
	gustiness: number, -- 0..1
	seed: number,
}

export type State = {
	intensity: number, -- 0..1
	sun: number, -- 0..1: 0 = overcast, 1 = sunny spell
	gust: number, -- 0..1
	windX: number, -- studs/s
	windZ: number,
}

local function clamp01(x: number): number
	return if x < 0 then 0 elseif x > 1 then 1 else x
end

function WeatherModel.smoothstep(e0: number, e1: number, x: number): number
	local t = clamp01((x - e0) / (e1 - e0))
	return t * t * (3 - 2 * t)
end
local smoothstep = WeatherModel.smoothstep

-- Smooth noise in about -1..1, built from a few octaves of Perlin noise.
local function fbm(x: number, seed: number): number
	local n = math.noise(x, seed + 0.31, 0.73) * 1.0
		+ math.noise(x * 2.03, seed + 7.17, 1.91) * 0.5
		+ math.noise(x * 4.11, seed + 13.7, 3.37) * 0.25
	-- (Perlin noise rarely leaves -0.5..0.5; this spreads it over about -1..1)
	return math.clamp(n * 1.6, -1, 1)
end
WeatherModel.fbm = fbm

-- The weather at time t (seconds).
function WeatherModel.sample(s: Settings, t: number): State
	local base = clamp01(s.intensity)
	local swing = fbm(t / math.max(s.period, 1), s.seed)
	local intensity = clamp01(base + swing * s.variation)

	-- the sun only breaks through light snowfall; a second, slower noise moves the cloud gaps
	local gaps = fbm(t / math.max(s.period * 0.6, 1), s.seed + 101) * 0.5 + 0.5
	local sun = smoothstep(0.62, 0.18, intensity) * smoothstep(0.25, 0.7, gaps)

	-- gusts: short bursts on top of a steady wind, stronger when it snows hard
	local g = fbm(t / 7, s.seed + 37) * 0.5 + 0.5
	local gust = smoothstep(0.55, 0.95, g) * s.gustiness
	local speed = s.windSpeed * (0.55 + 0.75 * intensity) * (1 + 1.4 * gust)
	-- the direction wanders a little
	local angle = s.windAngle + fbm(t / 40, s.seed + 53) * 0.35
	return {
		intensity = intensity,
		sun = sun,
		gust = gust,
		windX = math.cos(angle) * speed,
		windZ = math.sin(angle) * speed,
	}
end

-- Linear interpolation of numbers and of { r, g, b } triples.
function WeatherModel.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function WeatherModel.lerp3(a: { number }, b: { number }, t: number): { number }
	return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end

-- Moves `current` towards `target` with a time constant of `tau` seconds (frame-rate independent).
function WeatherModel.approach(current: number, target: number, dt: number, tau: number): number
	if tau <= 0 then
		return target
	end
	return target + (current - target) * math.exp(-dt / tau)
end

return WeatherModel
