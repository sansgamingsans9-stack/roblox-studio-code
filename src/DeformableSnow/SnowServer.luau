--!strict
--[[
	SnowServer
	Optional helper that makes footprints shared:
	  * every client reports the prints its own character makes (compact buffers)
	  * the server validates them (rate limit, must be near that player's character), keeps a
	    rolling history and relays them to everybody
	  * players who join later receive the history, so existing trails are already there
	The snow itself is simulated on each client; the server never touches any meshes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.Config)
local StampCodec = require(script.Parent.StampCodec)

local SnowServer = {}

local RATE = 60 -- prints per second a player may report (sustained)
local BURST = 120
local MAX_DIST = 25 -- a print must be this close to the reporting player's character
local RELAY_INTERVAL = 0.25

function SnowServer.start()
	if (shared :: any).__DeformableSnowServer then
		return
	end
	(shared :: any).__DeformableSnowServer = true
	if not Config.SyncFootprints then
		return
	end

	local folder = ReplicatedStorage:FindFirstChild("DeformableSnowRemotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "DeformableSnowRemotes"
	end
	local ev = (folder :: Instance):FindFirstChild("Footprints") :: RemoteEvent?
	if not ev then
		local created = Instance.new("RemoteEvent")
		created.Name = "Footprints"
		created.Parent = folder
		ev = created
	end
	local remote = ev :: RemoteEvent
	;(folder :: Instance).Parent = ReplicatedStorage

	local history: { StampCodec.Stamp } = {}
	local pending: { StampCodec.Stamp } = {}
	local tokens: { [Player]: number } = {}
	local refilled: { [Player]: number } = {}
	local greeted: { [Player]: boolean } = {}

	-- prints older than this have fully regrown and are not worth sending
	local maxAge = math.huge
	if Config.RegrowSpeed > 0 then
		maxAge = Config.RegrowDelay + math.max(Config.SnowDepth, 2) * 3 / Config.RegrowSpeed
	end

	local function prune(t: number)
		local n = #history
		local cut = 0
		for i = 1, n do
			if t - history[i].time > maxAge then
				cut = i
			else
				break
			end
		end
		local over = n - Config.MaxHistory
		if over > cut then
			cut = over
		end
		if cut > 0 then
			table.move(history, cut + 1, n, 1)
			for i = n - cut + 1, n do
				history[i] = nil
			end
		end
	end

	local function sendHistory(player: Player)
		prune(Workspace:GetServerTimeNow())
		local snapshot = table.clone(history)
		local per = StampCodec.MAX_PER_PACKET
		for i = 1, #snapshot, per do
			if player.Parent ~= Players then
				return
			end
			remote:FireClient(player, "history", StampCodec.encodeRelay(snapshot, i, i + per - 1))
			task.wait(0.2)
		end
	end

	remote.OnServerEvent:Connect(function(player: Player, payload: any)
		if payload == "hello" then
			if not greeted[player] then
				greeted[player] = true
				task.spawn(sendHistory, player)
			end
			return
		end
		local t = Workspace:GetServerTimeNow()
		local list = StampCodec.decodeClient(payload, player.UserId, t)
		if not list then
			return
		end

		local clock = os.clock()
		local tk = math.min(BURST, (tokens[player] or BURST) + (clock - (refilled[player] or clock)) * RATE)
		refilled[player] = clock

		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local rp = root.Position
			for _, s in list do
				if tk < 1 then
					break
				end
				tk -= 1
				local dx, dy, dz = s.px - rp.X, s.py - rp.Y, s.pz - rp.Z
				if dx * dx + dy * dy + dz * dz <= MAX_DIST * MAX_DIST then
					table.insert(history, s)
					table.insert(pending, s)
				end
			end
		end
		tokens[player] = tk
	end)

	Players.PlayerRemoving:Connect(function(player)
		tokens[player] = nil
		refilled[player] = nil
		greeted[player] = nil
	end)

	local timer = 0
	RunService.Heartbeat:Connect(function(dt: number)
		timer += dt
		if timer < RELAY_INTERVAL then
			return
		end
		timer = 0
		if #pending > 0 then
			local per = StampCodec.MAX_PER_PACKET
			for i = 1, #pending, per do
				remote:FireAllClients("relay", StampCodec.encodeRelay(pending, i, i + per - 1))
			end
			table.clear(pending)
		end
		if #history > Config.MaxHistory then
			prune(Workspace:GetServerTimeNow())
		end
	end)

	task.spawn(function()
		while true do
			task.wait(10)
			prune(Workspace:GetServerTimeNow())
		end
	end)
end

return SnowServer
