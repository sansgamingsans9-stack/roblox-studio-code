--!nocheck
--[[
	A deliberately small mock of the Roblox engine, just enough to run the DeformableSnow client
	end-to-end with the `luau` CLI: datatypes, Instances with signals, a frame scheduler
	(Heartbeat / task.*), axis-aligned raycasts & box queries, and an EditableMesh that validates
	the ids it is given (like the real one, ids of different kinds are not interchangeable).
]]

local M = {}

------------------------------------------------------------------ datatypes
local Vector3 = {}
local V3mt = {}
local function v3(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3mt)
end
V3mt.__index = function(t, k)
	if k == "Magnitude" then
		return math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
	elseif k == "Unit" then
		local m = math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
		return v3(t.X / m, t.Y / m, t.Z / m)
	elseif k == "Dot" then
		return function(a, b)
			return a.X * b.X + a.Y * b.Y + a.Z * b.Z
		end
	elseif k == "Cross" then
		return function(a, b)
			return v3(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
		end
	end
	return nil
end
V3mt.__unm = function(a)
	return v3(-a.X, -a.Y, -a.Z)
end
V3mt.__add = function(a, b)
	return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V3mt.__sub = function(a, b)
	return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V3mt.__mul = function(a, b)
	if type(a) == "number" then
		return v3(b.X * a, b.Y * a, b.Z * a)
	elseif type(b) == "number" then
		return v3(a.X * b, a.Y * b, a.Z * b)
	end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3mt.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
V3mt.__tostring = function(t)
	return string.format("(%.3f, %.3f, %.3f)", t.X, t.Y, t.Z)
end
Vector3.new = v3
Vector3.zero = v3(0, 0, 0)
M.Vector3 = Vector3

M.Vector2 = {
	new = function(x, y)
		return { X = x or 0, Y = y or 0 }
	end,
}

local CFmt = {}
CFmt.__index = function(t, k)
	if k == "Position" then
		return v3(t.c[1], t.c[2], t.c[3])
	elseif k == "GetComponents" then
		return function(self)
			return table.unpack(self.c)
		end
	end
	return nil
end
CFmt.__eq = function(a, b)
	for i = 1, 12 do
		if a.c[i] ~= b.c[i] then
			return false
		end
	end
	return true
end
local CFrame = {}
function CFrame.new(x, y, z, ...)
	local rest = { ... }
	if #rest == 9 then
		return setmetatable({ c = { x, y, z, table.unpack(rest) } }, CFmt)
	end
	return setmetatable({ c = { x or 0, y or 0, z or 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 } }, CFmt)
end
function CFrame.fromMatrix(pos, vx, vy, vz)
	vz = vz or vx:Cross(vy)
	return setmetatable({ c = { pos.X, pos.Y, pos.Z, vx.X, vy.X, vz.X, vx.Y, vy.Y, vz.Y, vx.Z, vy.Z, vz.Z } }, CFmt)
end
-- rotation about Y (enough for the tests)
function CFrame.yaw(x, y, z, a)
	local c, s = math.cos(a), math.sin(a)
	return setmetatable({ c = { x, y, z, c, 0, s, 0, 1, 0, -s, 0, c } }, CFmt)
end
M.CFrame = CFrame

local C3mt = {}
C3mt.__index = {
	Lerp = function(a, b, t)
		return setmetatable({ R = a.R + (b.R - a.R) * t, G = a.G + (b.G - a.G) * t, B = a.B + (b.B - a.B) * t }, C3mt)
	end,
}
C3mt.__eq = function(a, b)
	return a.R == b.R and a.G == b.G and a.B == b.B
end
M.Color3 = {
	new = function(r, g, b)
		return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, C3mt)
	end,
	fromRGB = function(r, g, b)
		return setmetatable({ R = r / 255, G = g / 255, B = b / 255 }, C3mt)
	end,
}
local function passthrough(...)
	return { ... }
end
M.ColorSequence = { new = passthrough }
M.NumberSequence = { new = passthrough }
M.NumberSequenceKeypoint = { new = passthrough }
M.NumberRange = { new = passthrough }
M.Content = {
	fromObject = function(o)
		return { Object = o }
	end,
}

M.Enum = setmetatable({}, {
	__index = function(_, enumName)
		return setmetatable({}, {
			__index = function(_, item)
				return "Enum." .. enumName .. "." .. item
			end,
		})
	end,
})

------------------------------------------------------------------ scheduler
local clock = 0
local heartbeatWaiters = {}
local timed = {}
local deferred = {}
M.warnings = {}

local function resume(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		error(debug.traceback(co, tostring(err)), 0)
	end
end

-- simulated clock (os.clock inside the modules is this, so timings are deterministic)
M.os = setmetatable({
	clock = function()
		return clock
	end,
}, { __index = os })

M.task = {
	spawn = function(f, ...)
		local co = if type(f) == "thread" then f else coroutine.create(f)
		resume(co, ...)
		return co
	end,
	defer = function(f, ...)
		table.insert(deferred, { f = f, args = { ... } })
	end,
	wait = function(t)
		local co = coroutine.running()
		table.insert(timed, { co = co, at = clock + (t or 0) })
		return coroutine.yield()
	end,
}

function M.warn(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring(select(i, ...))
	end
	local msg = table.concat(parts, " ")
	table.insert(M.warnings, msg)
	print("WARN " .. msg)
end

------------------------------------------------------------------ signals
local Signal = {}
Signal.__index = Signal
local function newSignal()
	return setmetatable({ handlers = {}, waiting = {} }, Signal)
end
function Signal:Connect(fn)
	local h = { fn = fn, connected = true }
	table.insert(self.handlers, h)
	return {
		Disconnect = function()
			h.connected = false
		end,
	}
end
function Signal:Fire(...)
	for _, h in table.clone(self.handlers) do
		if h.connected then
			M.task.spawn(h.fn, ...)
		end
	end
	local w = self.waiting
	self.waiting = {}
	for _, co in w do
		resume(co, ...)
	end
end
function Signal:Wait()
	table.insert(self.waiting, coroutine.running())
	return coroutine.yield()
end
M.newSignal = newSignal

------------------------------------------------------------------ instances
local isA = {
	BasePart = { Part = true, MeshPart = true, WedgePart = true, BasePart = true },
	Part = { Part = true },
	MeshPart = { MeshPart = true },
}
local Instance = {}
local Imt = {}
local methods = {}
local nextId = 0

local function signal(self, name)
	local s = rawget(self, "_signals")[name]
	if not s then
		s = newSignal()
		rawget(self, "_signals")[name] = s
	end
	return s
end

local function defaults(cls)
	local p = { Name = cls, Archivable = true }
	if cls == "Part" or cls == "MeshPart" or cls == "WedgePart" then
		p.CFrame = CFrame.new()
		p.Size = v3(4, 1, 2)
		p.Anchored = false
		p.CanCollide = true
		p.CanQuery = true
		p.CanTouch = true
		p.Transparency = 0
		p.Shape = "Enum.PartType.Block"
	elseif cls == "Humanoid" then
		p.WalkSpeed = 16
		p.RootPart = nil
	elseif cls == "Camera" then
		p.CFrame = CFrame.new()
	end
	return p
end

function Instance.new(cls)
	nextId += 1
	local self = setmetatable({
		ClassName = cls,
		_props = defaults(cls),
		_children = {},
		_attrs = {},
		_tags = {},
		_signals = {},
		_id = nextId,
	}, Imt)
	return self
end
M.Instance = Instance

Imt.__index = function(self, k)
	local m = methods[k]
	if m then
		return m
	end
	local props = rawget(self, "_props")
	if k == "Parent" then
		return props.Parent
	elseif k == "Position" and props.CFrame then
		return props.CFrame.Position
	elseif k == "WorldPosition" then
		return props.WorldPosition or v3()
	end
	local v = props[k]
	if v ~= nil then
		return v
	end
	if
		k == "ChildAdded"
		or k == "ChildRemoved"
		or k == "DescendantAdded"
		or k == "DescendantRemoving"
		or k == "AncestryChanged"
		or k == "OnClientEvent"
		or k == "OnServerEvent"
		or k == "PlayerRemoving"
	then
		return signal(self, k)
	end
	-- child lookup by name (game.Workspace style)
	for _, c in rawget(self, "_children") do
		if c.Name == k then
			return c
		end
	end
	return nil
end

local function fireDescendantAdded(node, inst)
	local p = node
	while p do
		signal(p, "DescendantAdded"):Fire(inst)
		p = rawget(p, "_props").Parent
	end
end

local function fireDescendantRemoving(node, inst)
	local p = node
	while p do
		signal(p, "DescendantRemoving"):Fire(inst)
		p = rawget(p, "_props").Parent
	end
end

local function allDescendants(inst, out)
	for _, c in rawget(inst, "_children") do
		table.insert(out, c)
		allDescendants(c, out)
	end
	return out
end

Imt.__newindex = function(self, k, v)
	local props = rawget(self, "_props")
	if k == "Parent" then
		local old = props.Parent
		if old == v then
			return
		end
		if old then
			for _, d in allDescendants(self, { self }) do
				fireDescendantRemoving(old, d)
			end
			local list = rawget(old, "_children")
			for i, c in list do
				if c == self then
					table.remove(list, i)
					break
				end
			end
			signal(old, "ChildRemoved"):Fire(self)
		end
		props.Parent = v
		if v then
			table.insert(rawget(v, "_children"), self)
			signal(v, "ChildAdded"):Fire(self)
			for _, d in allDescendants(self, { self }) do
				fireDescendantAdded(v, d)
			end
		end
		signal(self, "AncestryChanged"):Fire(self, v)
		for _, d in allDescendants(self, {}) do
			signal(d, "AncestryChanged"):Fire(self, v)
		end
		return
	end
	if k == "WorldPosition" then
		props.WorldPosition = v
		return
	end
	if props.Name == "Snow" and (k == "Size" or k == "CFrame" or k == "Color") then
		M.snowWrites = (M.snowWrites or 0) + 1
	end
	props[k] = v
	local s = rawget(self, "_signals")["prop:" .. k]
	if s then
		s:Fire()
	end
end

function methods.IsA(self, cls)
	if self.ClassName == cls or cls == "Instance" then
		return true
	end
	local set = isA[cls]
	return set ~= nil and set[self.ClassName] == true
end
function methods.GetChildren(self)
	return table.clone(rawget(self, "_children"))
end
function methods.GetDescendants(self)
	return allDescendants(self, {})
end
function methods.FindFirstChild(self, name)
	for _, c in rawget(self, "_children") do
		if c.Name == name then
			return c
		end
	end
	return nil
end
function methods.FindFirstChildOfClass(self, cls)
	for _, c in rawget(self, "_children") do
		if c.ClassName == cls then
			return c
		end
	end
	return nil
end
function methods.WaitForChild(self, name, timeout)
	local start = clock
	while true do
		local c = methods.FindFirstChild(self, name)
		if c then
			return c
		end
		if timeout and clock - start >= timeout then
			return nil
		end
		M.task.wait(0)
	end
end
function methods.IsDescendantOf(self, other)
	local p = rawget(self, "_props").Parent
	while p do
		if p == other then
			return true
		end
		p = rawget(p, "_props").Parent
	end
	return false
end
function methods.Destroy(self)
	self.Parent = nil
	rawset(self, "_destroyed", true)
end
function methods.Clone(self)
	local c = Instance.new(self.ClassName)
	for k, v in rawget(self, "_props") do
		if k ~= "Parent" then
			rawget(c, "_props")[k] = v
		end
	end
	return c
end
function methods.GetPlayers(self)
	return { M.localPlayer }
end
function methods.GetPropertyChangedSignal(self, prop)
	return signal(self, "prop:" .. prop)
end
function methods.GetAttribute(self, name)
	return rawget(self, "_attrs")[name]
end
function methods.SetAttribute(self, name, value)
	rawget(self, "_attrs")[name] = value
	signal(self, "attr:" .. name):Fire()
end
function methods.GetAttributeChangedSignal(self, name)
	return signal(self, "attr:" .. name)
end
function methods.Emit(self, n)
	M.emitted = (M.emitted or 0) + n
end
function methods.Play(self)
	M.played = (M.played or 0) + 1
end
function methods.FireServer(self, payload)
	table.insert(M.sentToServer, payload)
end
M.sentToClients = {}
function methods.FireClient(self, player, kind, payload)
	table.insert(M.sentToClients, { to = player, kind = kind, payload = payload })
end
function methods.FireAllClients(self, kind, payload)
	table.insert(M.sentToClients, { to = "all", kind = kind, payload = payload })
end
function methods.GetServerTimeNow(_self)
	return 1759500000 + clock
end

-- services ---------------------------------------------------------
local game = Instance.new("DataModel")
local Workspace = Instance.new("Workspace")
Workspace.Name = "Workspace"
Workspace.Parent = game
local camera = Instance.new("Camera")
camera.Parent = Workspace
rawget(Workspace, "_props").CurrentCamera = camera
local ReplicatedStorage = Instance.new("ReplicatedStorage")
ReplicatedStorage.Name = "ReplicatedStorage"
ReplicatedStorage.Parent = game
local Players = Instance.new("Players")
Players.Name = "Players"
Players.Parent = game
local localPlayer = Instance.new("Player")
localPlayer.UserId = 1001
localPlayer.Parent = Players
rawget(Players, "_props").LocalPlayer = localPlayer
M.sentToServer = {}

local RunService = { Heartbeat = newSignal() }
local tagged = {}
local tagAdded, tagRemoved = {}, {}
local CollectionService = {}
function CollectionService:HasTag(inst, tag)
	return rawget(inst, "_tags")[tag] == true
end
function CollectionService:GetTagged(tag)
	local out = {}
	for inst in tagged[tag] or {} do
		table.insert(out, inst)
	end
	return out
end
function CollectionService:AddTag(inst, tag)
	rawget(inst, "_tags")[tag] = true
	tagged[tag] = tagged[tag] or {}
	tagged[tag][inst] = true
	if tagAdded[tag] then
		tagAdded[tag]:Fire(inst)
	end
end
function CollectionService:GetInstanceAddedSignal(tag)
	tagAdded[tag] = tagAdded[tag] or newSignal()
	return tagAdded[tag]
end
function CollectionService:GetInstanceRemovedSignal(tag)
	tagRemoved[tag] = tagRemoved[tag] or newSignal()
	return tagRemoved[tag]
end

function methods.GetPlayerByUserId(_self, id)
	if id == localPlayer.UserId then
		return localPlayer
	end
	return nil
end

-- geometry queries (axis-aligned boxes; enough for the scenarios) ---------
local function partBox(p)
	local pos, s = p.CFrame.Position, p.Size
	return pos.X - s.X / 2, pos.X + s.X / 2, pos.Y - s.Y / 2, pos.Y + s.Y / 2, pos.Z - s.Z / 2, pos.Z + s.Z / 2
end

M.raycasts = 0
function methods.Raycast(_self, origin, dir, params)
	M.raycasts += 1
	local best, bestT
	local list = {}
	if params.FilterType == "Enum.RaycastFilterType.Exclude" then
		for _, p in allDescendants(Workspace, {}) do
			local skip = false
			for _, e in params.FilterDescendantsInstances or {} do
				if p == e or methods.IsDescendantOf(p, e) then
					skip = true
				end
			end
			if not skip then
				table.insert(list, p)
			end
		end
	else
		for _, inst in params.FilterDescendantsInstances or {} do
			table.insert(list, inst)
			for _, d in allDescendants(inst, {}) do
				table.insert(list, d)
			end
		end
	end
	for _, p in list do
		if methods.IsA(p, "BasePart") and p.CanQuery and (not params.RespectCanCollide or p.CanCollide) then
			local x0, x1, y0, y1, z0, z1 = partBox(p)
			local tmin, tmax = 0, 1
			local ok = true
			for _, ax in { { origin.X, dir.X, x0, x1 }, { origin.Y, dir.Y, y0, y1 }, { origin.Z, dir.Z, z0, z1 } } do
				local o, d, lo, hi = ax[1], ax[2], ax[3], ax[4]
				if math.abs(d) < 1e-12 then
					if o < lo or o > hi then
						ok = false
					end
				else
					local a, b = (lo - o) / d, (hi - o) / d
					if a > b then
						a, b = b, a
					end
					tmin, tmax = math.max(tmin, a), math.min(tmax, b)
				end
			end
			if ok and tmin <= tmax and (not bestT or tmin < bestT) then
				best, bestT = p, tmin
			end
		end
	end
	if not best then
		return nil
	end
	return { Instance = best, Position = origin + dir * bestT, Normal = v3(0, 1, 0) }
end

function methods.BulkMoveTo(_self, parts, cframes, _mode)
	assert(#parts == #cframes, "BulkMoveTo: lists differ in length")
	M.bulkMoves = (M.bulkMoves or 0) + 1
	for i, p in parts do
		assert(methods.IsDescendantOf(p, Workspace), "BulkMoveTo: part not in Workspace")
		p.CFrame = cframes[i]
	end
end

function methods.GetPartBoundsInBox(_self, cf, size, params)
	local excl = params.FilterDescendantsInstances or {}
	local c = cf.Position
	local out = {}
	for _, p in allDescendants(Workspace, {}) do
		if methods.IsA(p, "BasePart") then
			local skip = false
			for _, e in excl do
				if p == e or methods.IsDescendantOf(p, e) then
					skip = true
				end
			end
			if not skip then
				local x0, x1, y0, y1, z0, z1 = partBox(p)
				if
					x1 >= c.X - size.X / 2
					and x0 <= c.X + size.X / 2
					and y1 >= c.Y - size.Y / 2
					and y0 <= c.Y + size.Y / 2
					and z1 >= c.Z - size.Z / 2
					and z0 <= c.Z + size.Z / 2
				then
					table.insert(out, p)
				end
			end
		end
	end
	return out
end

-- EditableMesh -------------------------------------------------------------
-- ids are tagged by kind in the high digits so mixing them up errors like the real engine
local KIND = { vertex = 1, normal = 2, uv = 3, color = 4, face = 5 }
local EM = {}
EM.__index = EM
M.meshes = {}
M.disableBatch = false

local function newEM()
	local self = setmetatable({ pools = { {}, {}, {}, {}, {} }, counters = { 0, 0, 0, 0, 0 }, destroyed = false }, EM)
	table.insert(M.meshes, self)
	return self
end
local function kindOf(id)
	return id // 10000000
end
function EM:_add(kind, value)
	self.counters[kind] += 1
	local id = kind * 10000000 + self.counters[kind]
	self.pools[kind][id] = value
	return id
end
function EM:_check(id, kind)
	assert(type(id) == "number", "id must be a number, got " .. type(id))
	assert(kindOf(id) == kind, `wrong id kind {kindOf(id)} (expected {kind})`)
	assert(self.pools[kind][id] ~= nil, "invalid id " .. id)
end
function EM:_addFace(vs)
	assert(#vs == 3, "triangles only in this mock")
	local f = { v = {}, n = {}, uv = {}, c = {} }
	for i, vid in vs do
		self:_check(vid, KIND.vertex)
		f.v[i] = vid
		-- auto attributes: reuse those of an existing face on this vertex, else new defaults
		self.vattr = self.vattr or {}
		local reuse = self.vattr[vid]
		if reuse then
			f.n[i], f.uv[i], f.c[i] = reuse[1], reuse[2], reuse[3]
		else
			f.n[i] = self:_add(KIND.normal, "auto")
			f.uv[i] = self:_add(KIND.uv, { X = 0, Y = 0 })
			f.c[i] = self:_add(KIND.color, { color = M.Color3.new(1, 1, 1), alpha = 1 })
			self.vattr[vid] = { f.n[i], f.uv[i], f.c[i] }
		end
	end
	return self:_add(KIND.face, f)
end
function EM:AddVertex(p)
	return self:_add(KIND.vertex, p)
end
function EM:AddNormal(n)
	return self:_add(KIND.normal, n or "auto")
end
function EM:AddUV(uv)
	return self:_add(KIND.uv, uv)
end
function EM:AddColor(c, a)
	return self:_add(KIND.color, { color = c, alpha = a })
end
function EM:AddTriangle(a, b, c)
	return self:_addFace({ a, b, c })
end
function EM:_setFace(fid, ids, field, kind)
	self:_check(fid, KIND.face)
	for i, id in ids do
		self:_check(id, kind)
		self.pools[KIND.face][fid][field][i] = id
	end
end
function EM:SetFaceNormals(fid, ids)
	self:_setFace(fid, ids, "n", KIND.normal)
end
function EM:SetFaceUVs(fid, ids)
	self:_setFace(fid, ids, "uv", KIND.uv)
end
function EM:SetFaceColors(fid, ids)
	self:_setFace(fid, ids, "c", KIND.color)
end
function EM:SetPosition(id, p)
	self:_check(id, KIND.vertex)
	self.pools[KIND.vertex][id] = p
end
function EM:SetNormal(id, n)
	self:_check(id, KIND.normal)
	self.pools[KIND.normal][id] = n
end
function EM:SetColor(id, c)
	self:_check(id, KIND.color)
	self.pools[KIND.color][id].color = c
end
function EM:RemoveUnused()
	local used = { {}, {}, {}, {} }
	for _, f in self.pools[KIND.face] do
		for i = 1, 3 do
			used[1][f.v[i]] = true
			used[2][f.n[i]] = true
			used[3][f.uv[i]] = true
			used[4][f.c[i]] = true
		end
	end
	local removed = {}
	for kind = 1, 4 do
		for id in self.pools[kind] do
			if not used[kind][id] then
				self.pools[kind][id] = nil
				table.insert(removed, id)
			end
		end
	end
	return removed
end
function EM:Destroy()
	self.destroyed = true
end
local function batchAdd(self, attr, data, alphas)
	local out = {}
	if attr == "Enum.MeshAttribute.Vertex" then
		for i, p in data do
			out[i] = self:AddVertex(p)
		end
	elseif attr == "Enum.MeshAttribute.Normal" then
		for i, n in data do
			out[i] = self:AddNormal(n)
		end
	elseif attr == "Enum.MeshAttribute.UV" then
		for i, uv in data do
			out[i] = self:AddUV(uv)
		end
	elseif attr == "Enum.MeshAttribute.Color" then
		assert(alphas and #alphas == #data, "colour batch needs alphas")
		for i, c in data do
			out[i] = self:AddColor(c, alphas[i])
		end
	elseif attr == "Enum.MeshAttribute.Face" then
		for i, vs in data do
			out[i] = self:_addFace(vs)
		end
	else
		error("bad attr " .. tostring(attr))
	end
	return out
end
local function batchSetFaceAttributes(self, fids, arrays)
	assert(#fids == #arrays, "length mismatch")
	for i, fid in fids do
		local kind = kindOf(arrays[i][1])
		local field = if kind == KIND.normal then "n" elseif kind == KIND.uv then "uv" else "c"
		self:_setFace(fid, arrays[i], field, kind)
	end
end
local function batchSetValues(self, ids, values)
	assert(#ids == #values, "length mismatch")
	for i, id in ids do
		local kind = kindOf(id)
		if kind == KIND.vertex then
			self:SetPosition(id, values[i])
		elseif kind == KIND.normal then
			self:SetNormal(id, values[i])
		elseif kind == KIND.color then
			self:SetColor(id, values[i])
		else
			error("unsupported id kind")
		end
	end
end
EM.__index = function(self, k)
	if not M.disableBatch then
		if k == "BatchAdd" then
			return batchAdd
		elseif k == "BatchSetFaceAttributes" then
			return batchSetFaceAttributes
		elseif k == "BatchSetValues" then
			return batchSetValues
		end
	elseif k:sub(1, 5) == "Batch" then
		error(k .. " is not a valid member of EditableMesh")
	end
	return EM[k]
end

local AssetService = {}
function AssetService:CreateEditableMesh()
	if M.editableDisabled then
		error("EditableMesh is not enabled for this experience")
	end
	if M.meshBudget and #M.meshes >= M.meshBudget then
		return nil
	end
	return newEM()
end
function AssetService:CreateMeshPartAsync(content, _opts)
	M.task.wait(0) -- yields like the real one
	local mp = Instance.new("MeshPart")
	rawget(mp, "_props").MeshContent = content
	return mp
end

local services = {
	Workspace = Workspace,
	ReplicatedStorage = ReplicatedStorage,
	Players = Players,
	RunService = RunService,
	CollectionService = CollectionService,
	AssetService = AssetService,
}
function methods.GetService(_self, name)
	return assert(services[name], "no mock service " .. name)
end
M.game = game
M.Workspace = Workspace
M.ReplicatedStorage = ReplicatedStorage
M.Players = Players
M.localPlayer = localPlayer
M.camera = camera
M.CollectionService = CollectionService
M.shared = {}

M.RaycastParams = {
	new = function()
		return { FilterType = nil, FilterDescendantsInstances = {} }
	end,
}
M.OverlapParams = M.RaycastParams

-- advances one frame of `dt` seconds
function M.frame(dt)
	clock += dt
	RunService.Heartbeat:Fire(dt)
	local due = {}
	local keep = {}
	for _, w in timed do
		if w.at <= clock then
			table.insert(due, w)
		else
			table.insert(keep, w)
		end
	end
	timed = keep
	for _, w in due do
		resume(w.co)
	end
	local d = deferred
	deferred = {}
	for _, item in d do
		M.task.spawn(item.f, table.unpack(item.args))
	end
end

function M.run(seconds, dt)
	dt = dt or 1 / 60
	local frames = math.floor(seconds / dt + 0.5)
	for _ = 1, frames do
		M.frame(dt)
	end
end

-- un-normalised geometric normal (cross product) of a triangle
function M.faceNormal(a, b, c)
	local ux, uy, uz = b.X - a.X, b.Y - a.Y, b.Z - a.Z
	local vx, vy, vz = c.X - a.X, c.Y - a.Y, c.Z - a.Z
	return v3(uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx)
end

-- every face of every live chunk mesh: calls fn(normal, area2) for checks
function M.eachFace(fn)
	for _, mp in allDescendants(Workspace, {}) do
		if mp.ClassName == "MeshPart" and mp.MeshContent then
			local em = mp.MeshContent.Object
			for _, f in em.pools[KIND.face] do
				local a = em.pools[KIND.vertex][f.v[1]]
				local b = em.pools[KIND.vertex][f.v[2]]
				local c = em.pools[KIND.vertex][f.v[3]]
				assert(a and b and c, "face references a removed vertex")
				for i = 1, 3 do
					assert(em.pools[KIND.normal][f.n[i]] ~= nil, "face references a removed normal")
					assert(em.pools[KIND.color][f.c[i]] ~= nil, "face references a removed colour")
				end
				fn(M.faceNormal(a, b, c), mp, em)
			end
		end
	end
end

function M.meshParts()
	local out = {}
	for _, mp in allDescendants(Workspace, {}) do
		if mp.ClassName == "MeshPart" and mp.MeshContent then
			table.insert(out, mp)
		end
	end
	return out
end

-- all live snow boxes drawn by the Parts renderer
function M.snowBoxes()
	local out = {}
	local render = Workspace:FindFirstChild("DeformableSnowRender")
	if render then
		for _, p in allDescendants(render, {}) do
			if (p.ClassName == "Part" or p.ClassName == "WedgePart") and p.Name == "Snow" then
				table.insert(out, p)
			end
		end
	end
	return out
end

-- the triangle face of a WedgePart that lies on the snow surface (the higher of its two faces)
function M.wedgeTop(w)
	local c, s = w.CFrame.c, w.Size
	local pos = v3(c[1], c[2], c[3])
	local X, Y, Z = v3(c[4], c[7], c[10]), v3(c[5], c[8], c[11]), v3(c[6], c[9], c[12])
	local best, bestY
	for _, side in { -1, 1 } do
		local function at(y, z)
			return pos + X * (side * s.X / 2) + Y * y + Z * z
		end
		local a, b, d = at(-s.Y / 2, -s.Z / 2), at(-s.Y / 2, s.Z / 2), at(s.Y / 2, s.Z / 2)
		local my = (a.Y + b.Y + d.Y) / 3
		if not bestY or my > bestY then
			best, bestY = { a, b, d }, my
		end
	end
	return best
end

-- height of a triangle (a, b, c) above (x, z), or nil when (x, z) is outside it
function M.triHeight(t, x, z)
	local a, b, c = t[1], t[2], t[3]
	local d = (b.Z - c.Z) * (a.X - c.X) + (c.X - b.X) * (a.Z - c.Z)
	if math.abs(d) < 1e-12 then
		return nil
	end
	local l1 = ((b.Z - c.Z) * (x - c.X) + (c.X - b.X) * (z - c.Z)) / d
	local l2 = ((c.Z - a.Z) * (x - c.X) + (a.X - c.X) * (z - c.Z)) / d
	local l3 = 1 - l1 - l2
	if l1 < -1e-6 or l2 < -1e-6 or l3 < -1e-6 then
		return nil
	end
	return l1 * a.Y + l2 * b.Y + l3 * c.Y
end

-- top of the drawn snow (boxes and wedge triangles) at (x, z), if any
function M.boxTopY(x, z)
	local best
	for _, p in M.snowBoxes() do
		if p.ClassName == "WedgePart" then
			local y = M.triHeight(M.wedgeTop(p), x, z)
			if y and (not best or y > best) then
				best = y
			end
			continue
		end
		local c, s = p.CFrame.Position, p.Size
		if math.abs(x - c.X) <= s.X / 2 + 1e-9 and math.abs(z - c.Z) <= s.Z / 2 + 1e-9 then
			local top = c.Y + s.Y / 2
			if not best or top > best then
				best = top
			end
		end
	end
	return best
end

-- number of pairs of snow boxes that overlap (they must tile without overlapping)
function M.boxOverlaps()
	local boxes = {}
	for _, p in M.snowBoxes() do
		if p.ClassName == "Part" then
			table.insert(boxes, p)
		end
	end
	local n = 0
	for a = 1, #boxes do
		local ca, sa = boxes[a].CFrame.Position, boxes[a].Size
		for b = a + 1, #boxes do
			local cb, sb = boxes[b].CFrame.Position, boxes[b].Size
			local ox = math.min(ca.X + sa.X / 2, cb.X + sb.X / 2) - math.max(ca.X - sa.X / 2, cb.X - sb.X / 2)
			local oz = math.min(ca.Z + sa.Z / 2, cb.Z + sb.Z / 2) - math.max(ca.Z - sa.Z / 2, cb.Z - sb.Z / 2)
			if ox > 1e-6 and oz > 1e-6 then
				n += 1
			end
		end
	end
	return n
end

-- world-space vertex heights of all live chunk meshes near (x, z)
function M.surfaceY(x, z)
	local boxTop = M.boxTopY(x, z)
	if boxTop then
		return boxTop, 0
	end
	local best, bestD
	for _, mp in allDescendants(Workspace, {}) do
		if mp.ClassName == "MeshPart" and mp.MeshContent then
			local em = mp.MeshContent.Object
			local origin = mp.CFrame.Position
			for _, f in em.pools[KIND.face] do
				local a = em.pools[KIND.vertex][f.v[1]]
				local b = em.pools[KIND.vertex][f.v[2]]
				local c = em.pools[KIND.vertex][f.v[3]]
				local n = M.faceNormal(a, b, c)
				-- only real surface triangles (skip vertical skirts and the tiny bounds pins)
				if n.Y > 0.2 and n.Magnitude > 1e-4 then
					for _, p in { a, b, c } do
						local wx, wz = origin.X + p.X, origin.Z + p.Z
						local d = math.abs(wx - x) + math.abs(wz - z)
						if not bestD or d < bestD - 1e-9 or (math.abs(d - bestD) <= 1e-9 and origin.Y + p.Y > best) then
							best, bestD = origin.Y + p.Y, d
						end
					end
				end
			end
		end
	end
	return best, bestD
end

return M
