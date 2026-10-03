--!strict
--[[
	Shapes
	Pure geometry for anything that can press into the snow (feet, balls, wheels, crates...).
	No Roblox APIs are used here so the math can be unit-tested with the plain `luau` CLI.

	A shape is an oriented box, a ball or a cylinder (Roblox cylinders run along their local X axis).
	For every snow column we ask one question: "what is the lowest point of this shape on the
	vertical line through (x, z)?" - that is exactly how deep the snow gets pushed.
]]

local Shapes = {}

Shapes.BOX = 1
Shapes.BALL = 2
Shapes.CYLINDER = 3

export type Shape = {
	kind: number,
	px: number,
	py: number,
	pz: number,
	-- rotation matrix, same layout as CFrame:GetComponents() (columns are the local axes)
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number,
	r20: number,
	r21: number,
	r22: number,
	-- half size along local X/Y/Z
	hx: number,
	hy: number,
	hz: number,
	radius: number,
	-- world-space bounding box
	minX: number,
	maxX: number,
	minY: number,
	maxY: number,
	minZ: number,
	maxZ: number,
	-- horizontal footprint rectangle (centered on px/pz), used for the raised rim around prints
	ux: number,
	uz: number,
	hu: number,
	hv: number,
}

local abs = math.abs
local sqrt = math.sqrt
local huge = math.huge

function Shapes.new(): Shape
	return {
		kind = Shapes.BOX,
		px = 0,
		py = 0,
		pz = 0,
		r00 = 1,
		r01 = 0,
		r02 = 0,
		r10 = 0,
		r11 = 1,
		r12 = 0,
		r20 = 0,
		r21 = 0,
		r22 = 1,
		hx = 0.5,
		hy = 0.5,
		hz = 0.5,
		radius = 0.5,
		minX = -0.5,
		maxX = 0.5,
		minY = -0.5,
		maxY = 0.5,
		minZ = -0.5,
		maxZ = 0.5,
		ux = 1,
		uz = 0,
		hu = 0.5,
		hv = 0.5,
	}
end

-- Fills `s` in place (no allocations - this runs for every deformer every frame).
function Shapes.set(
	s: Shape,
	kind: number,
	px: number,
	py: number,
	pz: number,
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number,
	r20: number,
	r21: number,
	r22: number,
	sx: number,
	sy: number,
	sz: number
): Shape
	s.kind = kind
	s.px, s.py, s.pz = px, py, pz
	s.r00, s.r01, s.r02 = r00, r01, r02
	s.r10, s.r11, s.r12 = r10, r11, r12
	s.r20, s.r21, s.r22 = r20, r21, r22

	local hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5

	if kind == Shapes.BALL then
		local r = math.min(hx, hy, hz)
		s.hx, s.hy, s.hz, s.radius = r, r, r, r
		s.minX, s.maxX = px - r, px + r
		s.minY, s.maxY = py - r, py + r
		s.minZ, s.maxZ = pz - r, pz + r
		s.ux, s.uz, s.hu, s.hv = 1, 0, r, r
		return s
	end

	local ex, ey, ez
	if kind == Shapes.CYLINDER then
		-- axis = local X, radius from the other two axes (Roblox behaviour)
		local r = math.min(hy, hz)
		hy, hz = r, r
		s.radius = r
		-- exact AABB of a finite cylinder
		ex = abs(r00) * hx + r * sqrt(math.max(0, 1 - r00 * r00))
		ey = abs(r10) * hx + r * sqrt(math.max(0, 1 - r10 * r10))
		ez = abs(r20) * hx + r * sqrt(math.max(0, 1 - r20 * r20))
	else
		s.radius = math.min(hx, hy, hz)
		ex = abs(r00) * hx + abs(r01) * hy + abs(r02) * hz
		ey = abs(r10) * hx + abs(r11) * hy + abs(r12) * hz
		ez = abs(r20) * hx + abs(r21) * hy + abs(r22) * hz
	end
	s.hx, s.hy, s.hz = hx, hy, hz
	s.minX, s.maxX = px - ex, px + ex
	s.minY, s.maxY = py - ey, py + ey
	s.minZ, s.maxZ = pz - ez, pz + ez

	-- Footprint: take the local axis that is the most horizontal-looking (least vertical) as the
	-- rectangle's main direction, then measure the box's projected half-widths along it and its
	-- perpendicular (support function of the projected box).
	local a0, a1, a2 = abs(r10), abs(r11), abs(r12) -- vertical component of each local axis
	local fx, fz
	if a0 <= a1 and a0 <= a2 then
		fx, fz = r00, r20
	elseif a2 <= a1 then
		fx, fz = r02, r22
	else
		fx, fz = r01, r21
	end
	local len = sqrt(fx * fx + fz * fz)
	if len < 1e-6 then
		fx, fz, len = 1, 0, 1
	end
	local ux, uz = fx / len, fz / len
	local vx, vz = -uz, ux
	s.ux, s.uz = ux, uz
	s.hu = hx * abs(r00 * ux + r20 * uz) + hy * abs(r01 * ux + r21 * uz) + hz * abs(r02 * ux + r22 * uz)
	s.hv = hx * abs(r00 * vx + r20 * vz) + hy * abs(r01 * vx + r21 * vz) + hz * abs(r02 * vx + r22 * vz)
	return s
end

--[[
	Lowest point of the shape on the vertical line through (x, z), or nil when the line misses it.
]]
function Shapes.lowestAt(s: Shape, x: number, z: number): number?
	local dx, dz = x - s.px, z - s.pz
	local kind = s.kind

	if kind == Shapes.BALL then
		local r = s.radius
		local d2 = dx * dx + dz * dz
		local r2 = r * r
		if d2 > r2 then
			return nil
		end
		return s.py - sqrt(r2 - d2)
	end

	-- Line in the shape's local space: L(t) = a + t * d, where t is world Y relative to s.py.
	local a0 = s.r00 * dx + s.r20 * dz
	local a1 = s.r01 * dx + s.r21 * dz
	local a2 = s.r02 * dx + s.r22 * dz
	local d0, d1, d2 = s.r10, s.r11, s.r12

	local tmin, tmax = -huge, huge

	if kind == Shapes.CYLINDER then
		-- axial slab (local X)
		local h = s.hx
		if abs(d0) < 1e-9 then
			if abs(a0) > h then
				return nil
			end
		else
			local t1, t2 = (-h - a0) / d0, (h - a0) / d0
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tmin, tmax = t1, t2
		end
		-- radial: (a1 + t d1)^2 + (a2 + t d2)^2 <= r^2
		local r = s.radius
		local A = d1 * d1 + d2 * d2
		local C = a1 * a1 + a2 * a2 - r * r
		if A < 1e-12 then
			if C > 0 then
				return nil
			end
		else
			local B = 2 * (a1 * d1 + a2 * d2)
			local disc = B * B - 4 * A * C
			if disc < 0 then
				return nil
			end
			local sq = sqrt(disc)
			local t1, t2 = (-B - sq) / (2 * A), (-B + sq) / (2 * A)
			if t1 > tmin then
				tmin = t1
			end
			if t2 < tmax then
				tmax = t2
			end
		end
		if tmin > tmax then
			return nil
		end
		return s.py + tmin
	end

	-- oriented box: slab test on all three axes
	local h = s.hx
	if abs(d0) < 1e-9 then
		if abs(a0) > h then
			return nil
		end
	else
		local t1, t2 = (-h - a0) / d0, (h - a0) / d0
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		if t1 > tmin then
			tmin = t1
		end
		if t2 < tmax then
			tmax = t2
		end
	end
	h = s.hy
	if abs(d1) < 1e-9 then
		if abs(a1) > h then
			return nil
		end
	else
		local t1, t2 = (-h - a1) / d1, (h - a1) / d1
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		if t1 > tmin then
			tmin = t1
		end
		if t2 < tmax then
			tmax = t2
		end
	end
	h = s.hz
	if abs(d2) < 1e-9 then
		if abs(a2) > h then
			return nil
		end
	else
		local t1, t2 = (-h - a2) / d2, (h - a2) / d2
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		if t1 > tmin then
			tmin = t1
		end
		if t2 < tmax then
			tmax = t2
		end
	end
	if tmin > tmax then
		return nil
	end
	return s.py + tmin
end

--[[
	Approximate horizontal distance from (x, z) to the shape's footprint.
	<= 0 means inside the footprint. Used to shape the little lip of snow pushed up around prints.
]]
function Shapes.footprintDistance(s: Shape, x: number, z: number): number
	local dx, dz = x - s.px, z - s.pz
	if s.kind == Shapes.BALL then
		return sqrt(dx * dx + dz * dz) - s.radius
	end
	local ux, uz = s.ux, s.uz
	local qu = abs(dx * ux + dz * uz) - s.hu
	local qv = abs(dz * ux - dx * uz) - s.hv
	local ou, ov = math.max(qu, 0), math.max(qv, 0)
	return sqrt(ou * ou + ov * ov) + math.min(math.max(qu, qv), 0)
end

return Shapes
