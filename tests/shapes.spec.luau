--!strict
-- Unit tests for Shapes (run with tools/test.sh)
local T = require("./testlib")
local Shapes = require("./mods/Shapes")

local s = Shapes.new()

T.describe("box", function()
	-- axis-aligned 2x1x4 box centred at (10, 5, -3)
	Shapes.set(s, Shapes.BOX, 10, 5, -3, 1, 0, 0, 0, 1, 0, 0, 0, 1, 2, 1, 4)
	T.near(s.minX, 9, 1e-9, "minX")
	T.near(s.maxY, 5.5, 1e-9, "maxY")
	T.near(s.minZ, -5, 1e-9, "minZ")
	T.near(Shapes.lowestAt(s, 10, -3) :: number, 4.5, 1e-9, "centre bottom")
	T.near(Shapes.lowestAt(s, 10.99, -4.99) :: number, 4.5, 1e-9, "corner bottom")
	T.eq(Shapes.lowestAt(s, 11.01, -3), nil, "outside x")
	T.eq(Shapes.lowestAt(s, 10, -5.01), nil, "outside z")
	T.near(Shapes.footprintDistance(s, 10, -3), -1, 1e-9, "inside footprint")
	T.near(Shapes.footprintDistance(s, 12, -3), 1, 1e-9, "1 stud outside along x")

	-- the same box rolled 90 degrees around Z: local X now points up, so it is 1 wide and 2 tall
	-- CFrame.Angles(0,0,pi/2): R = [[0,-1,0],[1,0,0],[0,0,1]]
	Shapes.set(s, Shapes.BOX, 0, 0, 0, 0, -1, 0, 1, 0, 0, 0, 0, 1, 2, 1, 4)
	T.near(s.minY, -1, 1e-9, "rolled minY")
	T.near(s.maxX, 0.5, 1e-9, "rolled maxX")
	T.near(Shapes.lowestAt(s, 0.2, 1) :: number, -1, 1e-9, "rolled bottom")
	T.eq(Shapes.lowestAt(s, 0.6, 1), nil, "rolled outside")

	-- 45 degree tilt around Z of a 2x2x2 cube: bottom is a ridge (an edge) at y = -sqrt(2)
	local c, sn = math.cos(math.pi / 4), math.sin(math.pi / 4)
	Shapes.set(s, Shapes.BOX, 0, 0, 0, c, -sn, 0, sn, c, 0, 0, 0, 1, 2, 2, 2)
	T.near(s.minY, -math.sqrt(2), 1e-9, "diamond minY")
	T.near(Shapes.lowestAt(s, 0, 0) :: number, -math.sqrt(2), 1e-9, "diamond ridge")
	T.near(Shapes.lowestAt(s, 0.5, 0) :: number, -math.sqrt(2) + 0.5, 1e-9, "diamond slope")
end)

T.describe("ball", function()
	Shapes.set(s, Shapes.BALL, 0, 3, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 2, 2, 2)
	T.near(Shapes.lowestAt(s, 0, 0) :: number, 2, 1e-9, "ball bottom")
	T.near(Shapes.lowestAt(s, 0.6, 0) :: number, 3 - 0.8, 1e-9, "ball side")
	T.eq(Shapes.lowestAt(s, 1.01, 0), nil, "ball miss")
	T.near(Shapes.footprintDistance(s, 3, 0), 2, 1e-9, "ball footprint")
end)

T.describe("cylinder", function()
	-- wheel: axis along world X (identity), radius 1, width 0.5, centre at y = 1
	Shapes.set(s, Shapes.CYLINDER, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0.5, 2, 2)
	T.near(s.minY, 0, 1e-9, "wheel minY")
	T.near(s.maxX, 0.25, 1e-9, "wheel half width")
	T.near(Shapes.lowestAt(s, 0, 0) :: number, 0, 1e-9, "contact point")
	T.near(Shapes.lowestAt(s, 0.2, 0.6) :: number, 1 - 0.8, 1e-9, "rounded along travel")
	T.eq(Shapes.lowestAt(s, 0.3, 0), nil, "beside the wheel")
	T.eq(Shapes.lowestAt(s, 0, 1.01), nil, "in front of the wheel")

	-- standing cylinder (axis = world Y): CFrame.Angles(0,0,pi/2) maps local X to world Y
	Shapes.set(s, Shapes.CYLINDER, 0, 0, 0, 0, -1, 0, 1, 0, 0, 0, 0, 1, 4, 2, 2)
	T.near(s.minY, -2, 1e-9, "standing minY")
	T.near(Shapes.lowestAt(s, 0.7, 0.7) :: number, -2, 1e-9, "flat cap")
	T.eq(Shapes.lowestAt(s, 0.75, 0.75), nil, "outside cap")
end)

return T.finish("shapes")
