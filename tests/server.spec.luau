--!nocheck
-- Server footprint relay: validation, rate limit, relay and late-join history (run with tools/test.sh).
local T = require("./testlib")
local R = require("./rbxmock")
local StampCodec = require("./mods/StampCodec")
local SnowServer = require("./mods/SnowServer")
local V, CF, I = R.Vector3, R.CFrame, R.Instance

local player = R.localPlayer -- the mock only has one Player object; acts as a remote player here
local char = I.new("Model")
local root = I.new("Part")
root.Name = "HumanoidRootPart"
root.CFrame = CF.new(0, 3, 0)
root.Parent = char
player.Character = char
char.Parent = R.Workspace

SnowServer.start()
local ev = R.ReplicatedStorage:FindFirstChild("DeformableSnowRemotes"):FindFirstChild("Footprints")

local function stamp(x: number)
	return {
		kind = 1,
		px = x,
		py = 0.2,
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
		sx = 1,
		sy = 0.4,
		sz = 1.2,
		userId = 0,
		time = 0,
	}
end

local function sent(kind: string)
	local n = 0
	for _, m in R.sentToClients do
		if m.kind == kind then
			n += #StampCodec.decodeRelay(m.payload)
		end
	end
	return n
end

T.describe("relays valid prints, drops far ones and junk", function()
	ev.OnServerEvent:Fire(player, StampCodec.encodeClient({ stamp(0.5), stamp(500) }))
	ev.OnServerEvent:Fire(player, "garbage")
	ev.OnServerEvent:Fire(player, buffer.create(3))
	R.run(0.3)
	T.eq(sent("relay"), 1, "only the print next to the character is relayed")
	local relay = StampCodec.decodeRelay(R.sentToClients[1].payload)
	T.eq(relay[1].userId, player.UserId, "stamped with the sender's id")
	T.ok(relay[1].time > 0, "stamped with server time")
end)

T.describe("rate limit", function()
	table.clear(R.sentToClients)
	local many = {}
	for i = 1, 400 do
		many[i] = stamp(0.01 * i)
	end
	ev.OnServerEvent:Fire(player, StampCodec.encodeClient(many))
	R.run(0.3)
	local n = sent("relay")
	T.ok(n > 0 and n <= 125, `burst capped ({n})`)
end)

T.describe("late joiner gets the history", function()
	table.clear(R.sentToClients)
	ev.OnServerEvent:Fire(player, "hello")
	R.run(2)
	local n = sent("history")
	T.ok(n >= 100, `history sent ({n})`)
	for _, m in R.sentToClients do
		if m.kind == "history" then
			T.eq(m.to, player, "only to the player who asked")
		end
	end
	table.clear(R.sentToClients)
	ev.OnServerEvent:Fire(player, "hello")
	R.run(1)
	T.eq(sent("history"), 0, "history is sent once per player")
end)

return T.finish("server")
