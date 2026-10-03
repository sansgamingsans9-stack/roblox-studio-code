--!strict
-- Unit tests for StampCodec (run with tools/test.sh)
local T = require("./testlib")
local StampCodec = require("./mods/StampCodec")

local function stamp(px: number): StampCodec.Stamp
	local c, s = math.cos(0.3), math.sin(0.3)
	-- rotation about Y by 0.3 rad
	return {
		kind = 1,
		px = px,
		py = 12.5,
		pz = -7.25,
		r00 = c,
		r01 = 0,
		r02 = s,
		r10 = 0,
		r11 = 1,
		r12 = 0,
		r20 = -s,
		r21 = 0,
		r22 = c,
		sx = 1,
		sy = 0.4,
		sz = 1.2,
		userId = 5123456789,
		time = 1759500000.125,
	}
end

T.describe("client packet", function()
	local list = { stamp(1), stamp(2) }
	local b = StampCodec.encodeClient(list)
	T.eq(buffer.len(b), 2 + 2 * StampCodec.BODY_SIZE, "size")
	local out = StampCodec.decodeClient(b, 42, 99) :: { StampCodec.Stamp }
	T.eq(#out, 2, "count")
	T.near(out[2].px, 2, 1e-5, "position")
	T.near(out[1].sz, 1.2, 1e-5, "size")
	T.near(out[1].r02, math.sin(0.3), 1e-3, "rotation z axis rebuilt")
	T.near(out[1].r22, math.cos(0.3), 1e-3, "rotation z axis rebuilt (2)")
	T.eq(out[1].userId, 42, "server assigns user id")
end)

T.describe("relay packet", function()
	local list = { stamp(1), stamp(2), stamp(3) }
	local b = StampCodec.encodeRelay(list, 2, 3)
	local out = StampCodec.decodeRelay(b) :: { StampCodec.Stamp }
	T.eq(#out, 2, "slice")
	T.near(out[1].px, 2, 1e-5, "first of slice")
	T.eq(out[1].userId, 5123456789, "64-bit user id survives")
	T.near(out[1].time, 1759500000.125, 1e-6, "f64 time")
end)

T.describe("rejects garbage", function()
	T.eq(StampCodec.decodeClient("nope", 1, 1), nil, "not a buffer")
	local b = buffer.create(5)
	buffer.writeu16(b, 0, 3)
	T.eq(StampCodec.decodeClient(b, 1, 1), nil, "length mismatch")
	local bad = stamp(0)
	bad.px = 0 / 0
	local nanPacket = StampCodec.encodeClient({ bad, stamp(1) })
	local out = StampCodec.decodeClient(nanPacket, 1, 1) :: { StampCodec.Stamp }
	T.eq(#out, 1, "NaN stamp dropped")
	local huge = stamp(0)
	huge.sx = 500
	local out2 = StampCodec.decodeClient(StampCodec.encodeClient({ huge }), 1, 1) :: { StampCodec.Stamp }
	T.eq(#out2, 0, "absurd size dropped")
end)

T.describe("range past the end of the list", function()
	local b = StampCodec.encodeRelay({ stamp(1), stamp(2), stamp(3) }, 1, 400)
	local out = StampCodec.decodeRelay(b) :: { StampCodec.Stamp }
	T.eq(#out, 3, "clamped to the list length")
end)

return T.finish("codec")
