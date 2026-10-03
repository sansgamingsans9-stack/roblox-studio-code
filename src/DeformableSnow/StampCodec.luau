--!strict
--[[
	StampCodec
	Packs footprints ("stamps") into compact buffers for RemoteEvents.

	client -> server : u16 count, then per stamp 37 bytes
	    u8 kind | f32 px py pz | f32 sx sy sz | i16 rightX rightY rightZ upX upY upZ
	server -> client : u16 count, then per stamp 53 bytes
	    f64 userId | f64 serverTime | <the 37 bytes above>

	Pure Luau (only the `buffer` library) so it is unit-testable outside Roblox.
]]

local StampCodec = {}

export type Stamp = {
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
	sz: number,
	userId: number,
	time: number,
}

local BODY = 37
local RELAY = 53
StampCodec.BODY_SIZE = BODY
StampCodec.RELAY_SIZE = RELAY
StampCodec.MAX_PER_PACKET = 400

local Q = 32767

local function finite(x: number, limit: number): boolean
	return x == x and x > -limit and x < limit
end

local function clampUnit(x: number): number
	if x > 1 then
		return 1
	elseif x < -1 then
		return -1
	end
	return x
end

local function writeBody(b: buffer, o: number, s: Stamp)
	buffer.writeu8(b, o, s.kind)
	buffer.writef32(b, o + 1, s.px)
	buffer.writef32(b, o + 5, s.py)
	buffer.writef32(b, o + 9, s.pz)
	buffer.writef32(b, o + 13, s.sx)
	buffer.writef32(b, o + 17, s.sy)
	buffer.writef32(b, o + 21, s.sz)
	buffer.writei16(b, o + 25, math.round(clampUnit(s.r00) * Q))
	buffer.writei16(b, o + 27, math.round(clampUnit(s.r10) * Q))
	buffer.writei16(b, o + 29, math.round(clampUnit(s.r20) * Q))
	buffer.writei16(b, o + 31, math.round(clampUnit(s.r01) * Q))
	buffer.writei16(b, o + 33, math.round(clampUnit(s.r11) * Q))
	buffer.writei16(b, o + 35, math.round(clampUnit(s.r21) * Q))
end

-- Reads one body; returns nil if anything is malformed (NaN, absurd sizes, degenerate rotation).
local function readBody(b: buffer, o: number, userId: number, time: number): Stamp?
	local kind = buffer.readu8(b, o)
	if kind < 1 or kind > 3 then
		return nil
	end
	local px, py, pz = buffer.readf32(b, o + 1), buffer.readf32(b, o + 5), buffer.readf32(b, o + 9)
	local sx, sy, sz = buffer.readf32(b, o + 13), buffer.readf32(b, o + 17), buffer.readf32(b, o + 21)
	if not (finite(px, 1e6) and finite(py, 1e6) and finite(pz, 1e6)) then
		return nil
	end
	if not (finite(sx, 64) and finite(sy, 64) and finite(sz, 64)) or sx <= 0 or sy <= 0 or sz <= 0 then
		return nil
	end
	-- right (X) and up (Y) axes, re-orthonormalised; Z = X cross Y
	local ax, ay, az = buffer.readi16(b, o + 25) / Q, buffer.readi16(b, o + 27) / Q, buffer.readi16(b, o + 29) / Q
	local bx, by, bz = buffer.readi16(b, o + 31) / Q, buffer.readi16(b, o + 33) / Q, buffer.readi16(b, o + 35) / Q
	local la = math.sqrt(ax * ax + ay * ay + az * az)
	if la < 0.5 then
		return nil
	end
	ax, ay, az = ax / la, ay / la, az / la
	local dot = ax * bx + ay * by + az * bz
	bx, by, bz = bx - dot * ax, by - dot * ay, bz - dot * az
	local lb = math.sqrt(bx * bx + by * by + bz * bz)
	if lb < 0.5 then
		return nil
	end
	bx, by, bz = bx / lb, by / lb, bz / lb
	local cx, cy, cz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
	return {
		kind = kind,
		px = px,
		py = py,
		pz = pz,
		r00 = ax,
		r10 = ay,
		r20 = az,
		r01 = bx,
		r11 = by,
		r21 = bz,
		r02 = cx,
		r12 = cy,
		r22 = cz,
		sx = sx,
		sy = sy,
		sz = sz,
		userId = userId,
		time = time,
	}
end

function StampCodec.encodeClient(list: { Stamp }): buffer
	local count = math.min(#list, StampCodec.MAX_PER_PACKET)
	local b = buffer.create(2 + count * BODY)
	buffer.writeu16(b, 0, count)
	for i = 1, count do
		writeBody(b, 2 + (i - 1) * BODY, list[i])
	end
	return b
end

function StampCodec.decodeClient(b: any, userId: number, time: number): { Stamp }?
	if typeof(b) ~= "buffer" then
		return nil
	end
	local len = buffer.len(b)
	if len < 2 then
		return nil
	end
	local count = buffer.readu16(b, 0)
	if count > StampCodec.MAX_PER_PACKET or len ~= 2 + count * BODY then
		return nil
	end
	local out = {}
	for i = 1, count do
		local s = readBody(b, 2 + (i - 1) * BODY, userId, time)
		if s then
			table.insert(out, s)
		end
	end
	return out
end

function StampCodec.encodeRelay(list: { Stamp }, first: number?, last: number?): buffer
	local i0 = first or 1
	local i1 = math.min(last or #list, #list, i0 + StampCodec.MAX_PER_PACKET - 1)
	local count = math.max(0, i1 - i0 + 1)
	local b = buffer.create(2 + count * RELAY)
	buffer.writeu16(b, 0, count)
	for k = 0, count - 1 do
		local s = list[i0 + k]
		local o = 2 + k * RELAY
		buffer.writef64(b, o, s.userId)
		buffer.writef64(b, o + 8, s.time)
		writeBody(b, o + 16, s)
	end
	return b
end

function StampCodec.decodeRelay(b: any): { Stamp }?
	if typeof(b) ~= "buffer" then
		return nil
	end
	local len = buffer.len(b)
	if len < 2 then
		return nil
	end
	local count = buffer.readu16(b, 0)
	if len ~= 2 + count * RELAY then
		return nil
	end
	local out = {}
	for k = 0, count - 1 do
		local o = 2 + k * RELAY
		local s = readBody(b, o + 16, buffer.readf64(b, o), buffer.readf64(b, o + 8))
		if s then
			table.insert(out, s)
		end
	end
	return out
end

return StampCodec
