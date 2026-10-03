--!strict
--[[
	SnowClient
	Runs on every client. Ties everything together:
	  * tracks every BasePart inside Workspace.SnowParts (collidable or not, any part type)
	  * reads their top surfaces with raycasts and builds a snow heightfield on top of them
	  * streams chunks in/out around the camera with 4 levels of detail
	  * presses snow down under feet, bodies, balls, wheels, crates... every frame
	  * snow puffs, optional crunch sounds, slows you down in deep fresh snow
	  * shares your prints through the server so late joiners see the trails too
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.Config)
local Shapes = require(script.Parent.Shapes)
local SnowField = require(script.Parent.SnowField)
local ChunkMesh = require(script.Parent.ChunkMesh)
local ChunkParts = require(script.Parent.ChunkParts)
local StampCodec = require(script.Parent.StampCodec)
local Quality = require(script.Parent.Quality)
local SnowWeather = require(script.Parent.SnowWeather)

type Chunk = SnowField.Chunk

type PartInfo = {
	keys: { number },
	depth: number,
	minX: number,
	maxX: number,
	minY: number,
	maxY: number,
	minZ: number,
	maxZ: number,
	conns: { RBXScriptConnection },
	collider: BasePart?,
}

-- what both renderers (ChunkParts and ChunkMesh) provide
type Renderer = {
	step: number,
	gridVersion: number,
	version: number,
	usesFull: boolean,
	partCount: number?, -- Parts renderer only
	wedgeCount: number?, -- Parts renderer only
	solid: any?, -- Parts renderer only: the chunk is one single box
	destroy: (self: any) -> (),
	restyle: ((self: any, chunk: Chunk, smoothness: number, budget: (() -> ())?) -> ())?, -- Parts only
	setShadows: (self: any, on: boolean) -> (),
	applyDirty: (
		self: any,
		field: SnowField.SnowField,
		chunk: Chunk,
		dirty: { [number]: number }?,
		all: boolean?,
		tint: Color3,
		budget: (() -> ())?
	) -> (),
}

type RenderState = {
	mesh: Renderer?,
	wantStep: number,
	wantFull: boolean,
	priority: number,
	dist: number,
	styleVersion: number,
	lastFlush: number, -- when its Parts were last updated with the snow's changes
	-- Parts renderer: real Part counts of the builds at each detail level (step -> count, time)
	partsAt: { [number]: number },
	partsAtTime: { [number]: number },
	-- the Parts budget lowered this chunk to `reducedTo` until `reducedUntil` (no popping)
	reducedTo: number,
	reducedUntil: number,
	building: boolean,
	failedUntil: number,
	emptyVersion: number,
	emptyStep: number,
}

type CharInfo = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart?,
	parts: { BasePart },
	kinds: { number },
	simulated: boolean,
	conns: { RBXScriptConnection },
	fxCooldown: { [BasePart]: number },
	lastSent: { [BasePart]: { t: number, pos: Vector3 } },
	lastPress: { [BasePart]: { number } },
}

type DynInfo = {
	kind: number,
	last: { number }, -- x, y, z, time of the previous press
	lastCF: CFrame?,
	lastSize: Vector3?,
	lastStamp: number,
	lastSeen: number,
	tagged: boolean,
}

local SnowClient = {}

------------------------------------------------------------------------ device & quality
-- What kind of device is this? (every lookup is guarded: none of it may break the snow)
local function detectDevice(): Quality.Device
	local device: Quality.Device = { touchOnly = false, console = false, graphicsLevel = nil }
	pcall(function()
		local uis = game:GetService("UserInputService")
		device.touchOnly = uis.TouchEnabled and not uis.KeyboardEnabled and not uis.MouseEnabled
	end)
	pcall(function()
		device.console = game:GetService("GuiService"):IsTenFootInterface()
	end)
	pcall(function()
		local level = (UserSettings():GetService("UserGameSettings") :: any).SavedQualityLevel
		if level ~= Enum.SavedQualitySetting.Automatic then
			device.graphicsLevel = level.Value
		end
	end)
	return device
end

local DEVICE = detectDevice()
local FORCED_TIER: string? = if Config.Quality ~= "Auto" then Config.Quality else nil
local START_TIER = Quality.initialTier(DEVICE, FORCED_TIER)
local tierIndex = START_TIER
local tier: Quality.Tier = Quality.TIERS[tierIndex]

------------------------------------------------------------------------ settings
-- weak devices start with a coarser grid: fewer, bigger triangles
local CELL = math.clamp(Config.CellSize, 0.1, 4)
if START_TIER <= 2 then
	CELL = math.max(CELL, 0.5)
end
-- a power of two (16, 32 or 64): the Parts renderer triangulates 16x16-cell tiles
local CHUNK_CELLS = if Config.ChunkCells >= 64 then 64 elseif Config.ChunkCells >= 32 then 32 else 16
local CHUNK_SPAN = CELL * CHUNK_CELLS
local NEAR_KEEP = 16 -- the Parts budget never lowers the detail of snow this close to the camera
local FX_DIST2 = 120 * 120
local SOUND_DIST2 = 60 * 60

-- "Parts" works everywhere; "EditableMesh" is smoother but needs the Mesh/Image APIs enabled
local useParts = Config.Renderer ~= "EditableMesh"

-- these follow the quality tier (see applyTier)
local LOD1, LOD2, LOD3 = 64, 128, 256
local RENDER_DIST = 512
local DATA_DISTANCE = LOD1 -- chunks closer than this are always simulated (others only where needed)
local SIM_DIST2 = 0
local CHAR_SIM_DIST2 = 0 -- other players' feet are simulated within this (squared) distance
local BUDGET = 0.003
local MAX_PARTS = 12000
local REGROW_INTERVAL = 0.25
local styleVersion = 0

local function tierSettings()
	local lod = Config.LodDistances
	-- full detail always reaches at least a third-person camera's distance from the player
	LOD1 = math.max((lod[1] or 32) * tier.lodScale, math.min(lod[1] or 32, 20))
	LOD2 = math.max((lod[2] or 64) * tier.lodScale, LOD1)
	LOD3 = math.max((lod[3] or 128) * tier.lodScale, LOD2)
	RENDER_DIST = math.max(Config.MaxRenderDistance * tier.lodScale, math.min(Config.MaxRenderDistance, LOD3))
	DATA_DISTANCE = LOD1
	local sim = Config.SimulationDistance * tier.simDistance
	SIM_DIST2 = sim * sim
	-- weak devices: other players farther than the last detail ring only show up through the
	-- server (simulating them would load full-detail snow where it is drawn coarsely anyway)
	local charSim = if tierIndex <= 2 then math.min(sim, LOD3) else sim
	CHAR_SIM_DIST2 = charSim * charSim
	BUDGET = math.max(0.5, math.min(Config.FrameBudgetMs, tier.budgetMs)) / 1000
	MAX_PARTS = math.max(1, math.floor(Config.MaxSnowParts * tier.maxParts / 12000))
	-- the Parts renderer draws heights in steps of ChunkParts.Q: regrowing in smaller steps than
	-- that rewrites the same Parts over and over for nothing
	REGROW_INTERVAL = if useParts and Config.RegrowSpeed > 0
		then math.max(0.25, tier.regrowSteps * ChunkParts.Q / Config.RegrowSpeed)
		else 0.25
end
tierSettings()

------------------------------------------------------------------------ state
local t0 = os.clock()
local function now(): number
	return os.clock() - t0
end

local localPlayer = Players.LocalPlayer
local field: SnowField.SnowField
local snowFolder: Instance? = nil
local renderFolder: Folder
local style: ChunkParts.Style
local warnedParts = false
-- chunks that are simulated (have full data): the only ones that can change every frame
local simChunks: { [Chunk]: boolean } = {}
local preloadUntil = 0
local lastTracked = 0 -- when a snow part was last added (they may still be streaming in)
local simEpoch = 0 -- bumped whenever a chunk starts being simulated (resting parts must press it)
local deepestSnow = Config.SnowDepth -- deepest snow on any part so far (how long prints last)
-- prints of chunks whose snow parts streamed out, restored when they stream back in
local detached: { [number]: { full: any, pending: any, time: number } } = {}

-- How long a print takes to fill back in completely (nil: prints are permanent).
local function maxPrintAge(): number?
	if Config.RegrowSpeed <= 0 then
		return nil
	end
	return Config.RegrowDelay + deepestSnow * (1 + Config.RimRatio) / Config.RegrowSpeed + 1
end

local parts: { [BasePart]: PartInfo } = {}
local chunkParts: { [number]: { [BasePart]: boolean } } = {}
local refreshQueue: { [BasePart]: boolean } = {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include
local includeDirty = true
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.RespectCanCollide = true

local characters: { [Model]: CharInfo } = {}
local deformers: { [BasePart]: DynInfo } = {}
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude

local camPos = Vector3.zero
local stopped = false
local consecutiveErrors = 0

local useFolder: (sf: Instance) -> ()
local remote: RemoteEvent? = nil
local partsReady = false
local outbox: { StampCodec.Stamp } = {}

-- chunks that hold something (a mesh, low-detail data, a simulation) or that someone needs:
-- planned even when out of range, so they get loaded or released. Chunks far away with nothing
-- loaded cost nothing per plan.
local loaded: { [Chunk]: boolean } = {}

-- Someone is (about to be) pressing this chunk: load its simulation.
local function need(chunk: Chunk, t: number)
	chunk.lastNeeded = t
	loaded[chunk] = true
end

-- scratch objects reused every frame
local shape = Shapes.new()
local stats = SnowField.newStats()

------------------------------------------------------------------------ helpers
local function aabb(part: BasePart): (number, number, number, number, number, number)
	local size = part.Size
	local px, py, pz, r00, r01, r02, r10, r11, r12, r20, r21, r22 = part.CFrame:GetComponents()
	local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
	local ex = math.abs(r00) * hx + math.abs(r01) * hy + math.abs(r02) * hz
	local ey = math.abs(r10) * hx + math.abs(r11) * hy + math.abs(r12) * hz
	local ez = math.abs(r20) * hx + math.abs(r21) * hy + math.abs(r22) * hz
	return px - ex, px + ex, py - ey, py + ey, pz - ez, pz + ez
end

local function hasTagUpTo(inst: Instance, tag: string, stopAt: Instance?): boolean
	local node: Instance? = inst
	while node and node ~= stopAt and node ~= game do
		if CollectionService:HasTag(node, tag) then
			return true
		end
		node = node.Parent
	end
	return false
end

local function shapeKind(part: BasePart): number
	if part:IsA("Part") then
		local s = (part :: Part).Shape
		if s == Enum.PartType.Ball then
			return Shapes.BALL
		elseif s == Enum.PartType.Cylinder then
			return Shapes.CYLINDER
		end
	end
	return Shapes.BOX
end

local function partDepth(part: BasePart): number
	local v = part:GetAttribute("SnowDepth")
	if typeof(v) == "number" then
		return math.max(0, v)
	end
	return Config.SnowDepth
end

local function getState(chunk: Chunk): RenderState
	local rs = chunk.render
	if rs == nil then
		rs = {
			mesh = nil,
			wantStep = 0,
			wantFull = false,
			priority = math.huge,
			dist = math.huge,
			styleVersion = 0,
			lastFlush = 0,
			partsAt = {},
			partsAtTime = {},
			reducedTo = 0,
			reducedUntil = 0,
			building = false,
			failedUntil = 0,
			emptyVersion = -1,
			emptyStep = 0,
		}
		chunk.render = rs
	end
	return rs :: RenderState
end

local function alive(chunk: Chunk): boolean
	return field.chunks[chunk.key] == chunk
end

local function destroyRender(chunk: Chunk)
	local rs = chunk.render :: RenderState?
	if rs and rs.mesh then
		rs.mesh:destroy()
		rs.mesh = nil
	end
end

------------------------------------------------------------------------ snow parts
local function rebuildInclude()
	local list: { Instance } = {}
	for part in parts do
		table.insert(list, part)
	end
	rayParams.FilterDescendantsInstances = list
	includeDirty = false
end

-- Is there nothing solid under this non-collidable snow part? (then players would fall through it)
local function needsCollider(part: BasePart, minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number): boolean
	local mode = Config.WalkOnNonCollidableSnow
	if part.CanCollide or mode == false then
		return false
	end
	if mode == true then
		return true
	end
	-- other (collidable) snow parts count as ground; only this part and characters are ignored
	local exclude: { Instance } = { renderFolder, part }
	for _, plr in Players:GetPlayers() do
		if plr.Character then
			table.insert(exclude, plr.Character)
		end
	end
	for model in characters do
		table.insert(exclude, model)
	end
	groundParams.FilterDescendantsInstances = exclude
	local dir = Vector3.new(0, -(maxY - minY) - 25, 0)
	local hits = 0
	for _, f in { { 0.5, 0.5 }, { 0.15, 0.15 }, { 0.85, 0.15 }, { 0.15, 0.85 }, { 0.85, 0.85 } } do
		local origin = Vector3.new(minX + (maxX - minX) * f[1], maxY, minZ + (maxZ - minZ) * f[2])
		if Workspace:Raycast(origin, dir, groundParams) then
			hits += 1
		end
	end
	return hits < 3
end

-- Invisible copy of the part that only this client collides with.
local function makeCollider(part: BasePart): BasePart?
	local ok, clone = pcall(function()
		return part:Clone()
	end)
	if not ok or not clone then
		return nil
	end
	local c = clone :: BasePart
	for _, child in c:GetChildren() do
		child:Destroy()
	end
	c.Name = "SnowCollider"
	c.Transparency = 1
	c.CanCollide = true
	c.CanTouch = false
	c.CastShadow = false
	c.Anchored = true
	c.Parent = renderFolder
	return c
end

local function trackPart(part: BasePart)
	if parts[part] or stopped then
		return
	end
	if hasTagUpTo(part, Config.IgnoreTag, Workspace) then
		return
	end
	if not part.CanQuery then
		-- surfaces are read with raycasts, which skip CanQuery=false parts (local change only)
		pcall(function()
			part.CanQuery = true
		end)
	end
	local minX, maxX, minY, maxY, minZ, maxZ = aabb(part)
	local info: PartInfo = {
		keys = field:addRegion(minX, maxX, minZ, maxZ),
		depth = partDepth(part),
		minX = minX,
		maxX = maxX,
		minY = minY,
		maxY = maxY,
		minZ = minZ,
		maxZ = maxZ,
		conns = {},
		collider = nil,
	}
	if needsCollider(part, minX, maxX, minY, maxY, minZ, maxZ) then
		info.collider = makeCollider(part)
	end
	parts[part] = info
	lastTracked = now()
	if info.depth > deepestSnow then
		deepestSnow = info.depth
		field.params.maxPendingAge = maxPrintAge()
	end
	-- a snow part streaming back in (StreamingEnabled): the prints on it come back
	for _, key in info.keys do
		local d = detached[key]
		if d then
			detached[key] = nil
			local chunk = field.chunks[key]
			local age = maxPrintAge()
			if chunk and not chunk.full and (age == nil or now() - d.time < age) then
				if d.full then
					-- re-read below (markStale) with the new parts, the prints are carried over
					chunk.full = d.full
					simEpoch += 1
					simChunks[chunk] = true
					loaded[chunk] = true
				end
				if d.pending then
					local list = chunk.pending or {}
					for _, item in d.pending do
						table.insert(list, item)
					end
					chunk.pending = list
				end
			end
		end
	end
	for _, key in info.keys do
		local set = chunkParts[key]
		if not set then
			set = {}
			chunkParts[key] = set
		end
		set[part] = true
	end
	field:markStale(minX, maxX, minZ, maxZ)
	includeDirty = true

	local function queue()
		refreshQueue[part] = true
	end
	table.insert(info.conns, part:GetPropertyChangedSignal("CFrame"):Connect(queue))
	table.insert(info.conns, part:GetPropertyChangedSignal("Size"):Connect(queue))
	table.insert(info.conns, part:GetAttributeChangedSignal("SnowDepth"):Connect(queue))
	table.insert(info.conns, part:GetPropertyChangedSignal("CanCollide"):Connect(queue))
end

-- Releases a PartInfo's chunks. Keys in `keep` (the part's new region) stay mapped to the part.
local function releaseInfo(part: BasePart, info: PartInfo, keep: { [number]: boolean }?)
	for _, c in info.conns do
		c:Disconnect()
	end
	if info.collider then
		info.collider:Destroy()
		info.collider = nil
	end
	for _, key in info.keys do
		if not (keep and keep[key]) then
			local set = chunkParts[key]
			if set then
				set[part] = nil
				if next(set) == nil then
					chunkParts[key] = nil
				end
			end
		end
	end
	field:markStale(info.minX, info.maxX, info.minZ, info.maxZ)
	for _, chunk in field:removeRegion(info.keys) do
		-- (keep its prints for a while: the part may only have streamed out)
		local full = chunk.full
		local active = full and full.activeCount > 0
		if active or chunk.pending then
			detached[chunk.key] = { full = if active then full else nil, pending = chunk.pending, time = now() }
		end
		destroyRender(chunk)
		simChunks[chunk] = nil
	end
	includeDirty = true
end

local function untrackPart(part: BasePart)
	local info = parts[part]
	if not info then
		return
	end
	parts[part] = nil
	refreshQueue[part] = nil
	releaseInfo(part, info, nil)
end

-- A snow part moved/resized: add the new region before releasing the old one so shared chunks
-- (and the prints in them) survive.
local function processRefreshQueue()
	if next(refreshQueue) == nil then
		return
	end
	local list = {}
	for part in refreshQueue do
		table.insert(list, part)
	end
	table.clear(refreshQueue)
	for _, part in list do
		local old = parts[part]
		parts[part] = nil
		if part.Parent and snowFolder and part:IsDescendantOf(snowFolder) then
			trackPart(part)
		end
		if old then
			local new = parts[part]
			local keep: { [number]: boolean } = {}
			if new then
				for _, key in new.keys do
					keep[key] = true
				end
			end
			releaseInfo(part, old, keep)
		end
	end
end

-- Vertical range of all snow parts around a chunk (so raycasts are short).
local function chunkYRange(chunk: Chunk): (number, number)
	local top, bottom = -math.huge, math.huge
	for dz = -1, 1 do
		for dx = -1, 1 do
			local set = chunkParts[SnowField.chunkKey(chunk.cx + dx, chunk.cz + dz)]
			if set then
				for part in set do
					local info = parts[part]
					if info then
						if info.maxY > top then
							top = info.maxY
						end
						if info.minY < bottom then
							bottom = info.minY
						end
					end
				end
			end
		end
	end
	return top, bottom
end

local function samplerFor(chunk: Chunk): SnowField.Sampler
	if includeDirty then
		rebuildInclude()
	end
	local top, bottom = chunkYRange(chunk)
	if top < bottom then
		return function(_x: number, _z: number): (number?, number, number)
			return nil, 0, 0
		end
	end
	local startY = top + 1
	local dir = Vector3.new(0, -math.min(top - bottom + 2, 10000), 0)
	return function(x: number, z: number): (number?, number, number)
		local result = Workspace:Raycast(Vector3.new(x, startY, z), dir, rayParams)
		if not result then
			return nil, 0, 0
		end
		local info = parts[result.Instance :: BasePart]
		return result.Position.Y, result.Normal.Y, if info then info.depth else Config.SnowDepth
	end
end

------------------------------------------------------------------------ background loader
local workStart = os.clock()
local function budget()
	-- while preloading, background work may use more of each frame so the snow is ready fast
	-- (4x the normal budget: 12 ms on High, 6 ms on Potato)
	local limit = if now() < preloadUntil then BUDGET * 4 else BUDGET
	if os.clock() - workStart > limit then
		RunService.Heartbeat:Wait()
		workStart = os.clock()
	end
end

local workList: { Chunk } = {}

local function needsWork(chunk: Chunk, rs: RenderState): boolean
	if rs.building or now() < rs.failedUntil then
		return false
	end
	if chunk.stale then
		return true
	end
	if rs.wantFull and not chunk.full then
		return true
	end
	local step = rs.wantStep
	if step > 0 then
		if not chunk.full and not chunk.coarse[step] then
			return true
		end
		if rs.emptyVersion == chunk.gridVersion and rs.emptyStep == step then
			return false
		end
		local mesh = rs.mesh
		if not mesh or mesh.step ~= step or mesh.gridVersion ~= chunk.gridVersion then
			return true
		end
		if rs.styleVersion ~= styleVersion and useParts then
			return true -- the quality tier changed how much detail the triangles get
		end
	end
	return false
end

-- EditableMesh is not available (e.g. a published game without "Enable Mesh / Image APIs"):
-- switch every chunk over to the Parts renderer instead of giving up.
local function switchToParts(reason: string)
	if useParts then
		return
	end
	useParts = true
	tierSettings()
	warn("[DeformableSnow] " .. reason .. " Switching to the Parts renderer (works everywhere).")
	for _, chunk in field.chunks do
		destroyRender(chunk)
		local rs = chunk.render :: RenderState?
		if rs then
			rs.failedUntil = 0
			rs.emptyVersion = -1
		end
	end
end

local function doWork(chunk: Chunk, rs: RenderState)
	if chunk.stale then
		chunk.stale = false
		field:clearGrids(chunk)
		if chunk.full or rs.wantFull then
			local grid = field:sampleGrid(chunk, 1, samplerFor(chunk), budget)
			if alive(chunk) then
				field:attachFull(chunk, grid, now(), budget)
				simEpoch += 1
				simChunks[chunk] = true
			end
		end
		return
	end

	local step = rs.wantStep
	-- something to look at quickly: a coarse mesh first when nothing is drawn yet
	local quick = step > 1 and not chunk.full and not rs.mesh
	if rs.wantFull and not chunk.full and not (quick and rs.emptyVersion ~= chunk.gridVersion) then
		local grid = field:sampleGrid(chunk, 1, samplerFor(chunk), budget)
		if alive(chunk) and not chunk.full then
			field:attachFull(chunk, grid, now(), budget)
			simEpoch += 1
			simChunks[chunk] = true
		end
		return
	end

	if step <= 0 then
		return
	end
	if not chunk.full and not chunk.coarse[step] then
		local grid = field:sampleGrid(chunk, step, samplerFor(chunk), budget)
		if alive(chunk) then
			field:attachCoarse(chunk, grid)
		end
		return
	end

	-- only the quality level changed: re-triangulate in place (unchanged Parts stay untouched)
	local current = rs.mesh
	local restyle = current and current.restyle
	if
		useParts
		and current
		and restyle
		and current.step == step
		and current.gridVersion == chunk.gridVersion
		and rs.styleVersion ~= styleVersion
	then
		local version = styleVersion
		rs.building = true
		restyle(current, chunk, style.smoothness, budget)
		rs.building = false
		rs.styleVersion = version
		return
	end

	rs.building = true
	-- (no `:: any` directly on the calls: that would drop their second return value)
	local mesh: Renderer?, reason: string?
	local builtWithParts = useParts
	local buildStyle = styleVersion
	local buildShadows = style.castShadow
	if useParts then
		local built, why = ChunkParts.build(field, chunk, step, style, budget)
		mesh, reason = built :: any, why
	else
		local built, why = ChunkMesh.build(field, chunk, step, style, budget)
		mesh, reason = built :: any, why
		if reason == "budget" then
			-- this device is out of EditableMesh memory: draw everything with Parts (mixing the two
			-- renderers would leave seams, they line up differently at chunk borders)
			switchToParts("This device ran out of EditableMesh memory.")
			local built2, why2 = ChunkParts.build(field, chunk, step, style, budget)
			mesh, reason = built2 :: any, why2
			builtWithParts = true
		end
	end
	rs.building = false
	if not alive(chunk) or stopped or (useParts and not builtWithParts) then
		-- gone, or we switched to Parts while this EditableMesh was being built: never mix them
		if mesh then
			mesh:destroy()
		end
		return
	end
	if mesh then
		consecutiveErrors = 0
		rs.styleVersion = buildStyle
		local old = rs.mesh
		rs.mesh = mesh
		if old then
			old:destroy()
		end
		if style.castShadow ~= buildShadows then
			-- the quality level turned shadows on/off while this chunk was being built
			mesh:setShadows(style.castShadow)
		end
		if mesh.usesFull and chunk.version ~= mesh.version then
			-- the snow changed while the mesh was being built (catch up, a tile per budget slice)
			mesh:applyDirty(field, chunk, nil, true, Config.PackedSnowTint, budget)
		end
	elseif reason == "empty" then
		rs.emptyVersion = chunk.gridVersion
		rs.emptyStep = step
		destroyRender(chunk)
	elseif reason == "disabled" then
		switchToParts(
			"EditableMesh is not available here (published games need 'Enable Mesh / Image APIs', "
				.. "which requires an ID-verified owner)."
		)
	elseif reason == "error" then
		consecutiveErrors += 1
		rs.failedUntil = now() + 2
		if consecutiveErrors >= 3 then
			switchToParts(
				"EditableMesh is not available here (published games need 'Enable Mesh / Image APIs', "
					.. "which requires an ID-verified owner)."
			)
		end
	end
end

local function workerLoop()
	while not stopped do
		local picked: Chunk? = nil
		local pickedIndex = 0
		for i, chunk in workList do
			if alive(chunk) and needsWork(chunk, getState(chunk)) then
				picked = chunk
				pickedIndex = i
				break
			end
		end
		if picked then
			-- drop everything before it (already done or gone)
			for _ = 1, pickedIndex - 1 do
				table.remove(workList, 1)
			end
			local target = picked :: Chunk
			local rs = getState(target)
			local wasParts = useParts
			local before: { any } =
				{ target.gridVersion, rs.mesh, target.full, target.stale, rs.emptyVersion, rs.emptyStep, next(target.coarse) }
			local ok, err = pcall(function()
				doWork(target, rs)
			end)
			-- safety net: never spin on a chunk whose work did not change anything
			local after: { any } =
				{ target.gridVersion, rs.mesh, target.full, target.stale, rs.emptyVersion, rs.emptyStep, next(target.coarse) }
			local same = true
			for k = 1, 7 do
				if before[k] ~= after[k] then
					same = false
				end
			end
			if same and ok and wasParts == useParts then
				rs.failedUntil = math.max(rs.failedUntil, now() + 1)
			end
			if not ok then
				warn("[DeformableSnow] loader error:", err)
				rs.building = false -- or the chunk would never be worked on again
				rs.failedUntil = now() + 3
				table.remove(workList, 1)
			end
			budget()
		else
			table.clear(workList)
			RunService.Heartbeat:Wait()
			workStart = os.clock()
		end
	end
end

------------------------------------------------------------------------ planning (4x per second)
local overBudget = false
local cappedFor = 0 -- seconds the budget has been reducing detail in a row

-- Parts renderer budget: nearest chunks first; once the estimated number of snow Parts passes
-- MaxSnowParts, farther chunks get coarser detail, and beyond the last detail ring none. Snow
-- closer than NEAR_KEEP studs is never reduced. Hysteresis keeps it from flapping.
local function byDist(a: Chunk, b: Chunk): boolean
	return (a.render :: RenderState).dist < (b.render :: RenderState).dist
end

-- Estimated number of snow Parts for a chunk drawn at `want`.
local function estimateParts(rs: RenderState, want: number, t: number): number
	-- what a build at this detail really cost (a while ago at most: prints come and go)
	local known = rs.partsAt[want]
	if known and t - rs.partsAtTime[want] < 10 then
		return math.max(1, known)
	end
	local mesh = rs.mesh
	if not mesh or not mesh.partCount then
		return 1
	end
	if mesh.solid then
		return 1 -- a single-box chunk stays one box at any detail
	end
	-- otherwise ~4x per detail level (on the safe side: guessing low makes chunks pop back and forth)
	local ratio = mesh.step / want
	return math.max(1, mesh.partCount * ratio * ratio)
end

local function applyPartBudget(drawn: { Chunk }, t: number)
	table.sort(drawn, byDist)
	local cap = MAX_PARTS * (if overBudget then 0.9 else 1)
	local used = 0
	local capped = false
	for _, chunk in drawn do
		local rs = chunk.render :: RenderState
		local mesh = rs.mesh
		if mesh and mesh.partCount and mesh.gridVersion == chunk.gridVersion then
			rs.partsAt[mesh.step] = mesh.partCount
			rs.partsAtTime[mesh.step] = t
		end
		local want = rs.wantStep
		if rs.dist >= NEAR_KEEP then
			-- recently lowered by the budget: stay there for a moment
			if t < rs.reducedUntil and want < rs.reducedTo then
				want = rs.reducedTo
			end
			local est = estimateParts(rs, want, t)
			while used + est > cap and want < 8 do
				want *= 2
				est = estimateParts(rs, want, t)
			end
			-- only far snow may be left out entirely: a missing chunk nearby looks like a hole
			if used + est > cap and rs.dist >= LOD3 and not (rs.emptyVersion == chunk.gridVersion) then
				want = 0
			end
			if want ~= rs.wantStep then
				capped = true
				if want > rs.wantStep and want ~= rs.reducedTo then
					rs.reducedTo, rs.reducedUntil = want, t + 4
				end
				rs.wantStep = want
			end
			if want > 0 then
				used += est
			end
		else
			used += estimateParts(rs, want, t)
		end
	end
	overBudget = capped
	cappedFor = if capped then cappedFor + 0.25 else 0
	-- (a short burst after a teleport is normal, only warn when it lasts)
	if cappedFor >= 5 and not warnedParts then
		warnedParts = true
		warn(
			`[DeformableSnow] more than {MAX_PARTS} snow Parts needed ({tier.name} quality); `
				.. "far snow is drawn with less detail. Raise CellSize or MaxSnowParts if this looks bad."
		)
	end
end

-- drawn but not simulated chunks within LOD2: also searched for loose parts, a few per scan
local scanFar: { Chunk } = {}
local scanFarIndex = 0
-- the chunks of the last plan (fresh distances)
local planned: { Chunk } = {}
local plannedSet: { [Chunk]: boolean } = {}

local function byPriority(a: Chunk, b: Chunk): boolean
	return (a.render :: RenderState).priority < (b.render :: RenderState).priority
end

local function planChunk(chunk: Chunk, t: number)
	local rs = getState(chunk)
	local halfSpan = CHUNK_SPAN * 0.5
	local cxw, czw = field:chunkCenter(chunk)
	local dx = math.max(math.abs(camPos.X - cxw) - halfSpan, 0)
	local dz = math.max(math.abs(camPos.Z - czw) - halfSpan, 0)
	local lo, hi = camPos.Y, camPos.Y
	local full = chunk.full
	if full then
		lo, hi = full.minY, full.maxY
	else
		for _, g in chunk.coarse do
			lo, hi = g.minY, g.maxY
			break
		end
	end
	local dy = if camPos.Y < lo then lo - camPos.Y elseif camPos.Y > hi then camPos.Y - hi else 0
	local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
	rs.dist = dist
	-- chunks someone nearby is about to step into jump the queue
	rs.priority = if not full and (t - chunk.lastNeeded) < 3 and dist < LOD2 then dist - 100000 else dist

	local step
	if dist > RENDER_DIST then
		step = 0
	elseif dist < LOD1 then
		step = 1
	elseif dist < LOD2 then
		step = 2
	elseif dist < LOD3 then
		step = 4
	else
		step = 8
	end
	rs.wantStep = step
	rs.wantFull = dist < DATA_DISTANCE or (t - chunk.lastNeeded) < 3
	plannedSet[chunk] = true
	table.insert(planned, chunk)
	if not full and dist < LOD2 and next(chunk.coarse) ~= nil then
		table.insert(scanFar, chunk)
	end
end

local function plan()
	local t = now()
	table.clear(scanFar)
	table.clear(planned)
	table.clear(plannedSet)

	-- every chunk within reach of the camera...
	local reach = RENDER_DIST + CHUNK_SPAN
	local cx0, cx1 = field:chunkRange(camPos.X - reach, camPos.X + reach)
	local cz0, cz1 = field:chunkRange(camPos.Z - reach, camPos.Z + reach)
	if (cx1 - cx0 + 1) * (cz1 - cz0 + 1) <= 20000 then
		for cz = cz0, cz1 do
			for cx = cx0, cx1 do
				local chunk = field:getChunk(cx, cz)
				if chunk then
					planChunk(chunk, t)
				end
			end
		end
	else
		for _, chunk in field.chunks do
			planChunk(chunk, t)
		end
	end
	-- ...and the ones farther away that still hold something
	for chunk in loaded do
		if not alive(chunk) then
			loaded[chunk] = nil
		elseif not plannedSet[chunk] then
			planChunk(chunk, t)
		end
	end

	if useParts then
		local drawn = {}
		for _, chunk in planned do
			if (chunk.render :: RenderState).wantStep > 0 then
				table.insert(drawn, chunk)
			end
		end
		applyPartBudget(drawn, t)
	end

	local list = {}
	for _, chunk in planned do
		local rs = chunk.render :: RenderState
		local full = chunk.full
		if rs.wantStep == 0 and rs.mesh and not rs.building then
			destroyRender(chunk)
		end
		-- far beyond the render distance: forget the low-detail surface too
		-- (not when it is only held back by the Parts budget, it would just be sampled again)
		if rs.dist > RENDER_DIST and not full and next(chunk.coarse) ~= nil then
			chunk.coarse = {}
		end
		-- forget simulations that are far away and fully regrown
		if full and not rs.wantFull and full.activeCount == 0 and not chunk.stale
			and rs.dist > DATA_DISTANCE * 1.25 and not rs.building
		then
			field:dropFull(chunk)
			simChunks[chunk] = nil
		end
		if needsWork(chunk, rs) then
			table.insert(list, chunk)
		end
		if rs.mesh or rs.building or chunk.full or next(chunk.coarse) ~= nil or rs.wantFull then
			loaded[chunk] = true
		else
			loaded[chunk] = nil
		end
	end
	table.sort(list, byPriority)
	workList = list
end

------------------------------------------------------------------------ effects
local fxAttachment: Attachment
local puffEmitter: ParticleEmitter
local sparkleEmitter: ParticleEmitter
local sounds: { Sound } = {}
local soundAttachments: { Attachment } = {}
local soundIndex = 0

local function setupEffects()
	local holder = Instance.new("Part")
	holder.Name = "SnowFx"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.CFrame = CFrame.new()
	holder.Parent = renderFolder

	fxAttachment = Instance.new("Attachment")
	fxAttachment.Parent = holder

	puffEmitter = Instance.new("ParticleEmitter")
	puffEmitter.Name = "Puff"
	puffEmitter.Enabled = false
	puffEmitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	puffEmitter.Color = ColorSequence.new(Config.SnowColor)
	puffEmitter.LightEmission = 0.1
	puffEmitter.LightInfluence = 1
	puffEmitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 0.75),
	})
	puffEmitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	puffEmitter.Lifetime = NumberRange.new(0.35, 0.7)
	puffEmitter.Speed = NumberRange.new(1.5, 4)
	puffEmitter.SpreadAngle = Vector2.new(70, 70)
	puffEmitter.EmissionDirection = Enum.NormalId.Top
	puffEmitter.Acceleration = Vector3.new(0, -14, 0)
	puffEmitter.Drag = 3
	puffEmitter.Rotation = NumberRange.new(0, 360)
	puffEmitter.RotSpeed = NumberRange.new(-120, 120)
	puffEmitter.Parent = fxAttachment

	sparkleEmitter = Instance.new("ParticleEmitter")
	sparkleEmitter.Name = "Flakes"
	sparkleEmitter.Enabled = false
	sparkleEmitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkleEmitter.Color = ColorSequence.new(Color3.new(1, 1, 1))
	sparkleEmitter.LightEmission = 0.6
	sparkleEmitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.12),
		NumberSequenceKeypoint.new(1, 0.04),
	})
	sparkleEmitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparkleEmitter.Lifetime = NumberRange.new(0.5, 0.9)
	sparkleEmitter.Speed = NumberRange.new(2, 5)
	sparkleEmitter.SpreadAngle = Vector2.new(60, 60)
	sparkleEmitter.EmissionDirection = Enum.NormalId.Top
	sparkleEmitter.Acceleration = Vector3.new(0, -18, 0)
	sparkleEmitter.Drag = 1.5
	sparkleEmitter.Parent = fxAttachment

	if Config.FootstepSoundId ~= "" then
		for i = 1, 4 do
			local a = Instance.new("Attachment")
			a.Parent = holder
			local s = Instance.new("Sound")
			s.SoundId = Config.FootstepSoundId
			s.Volume = Config.FootstepSoundVolume
			s.RollOffMaxDistance = 60
			s.Parent = a
			soundAttachments[i] = a
			sounds[i] = s
		end
	end
end

local function puff(pos: Vector3, volume: number)
	local amount = tier.particles
	if amount <= 0 then
		return
	end
	fxAttachment.WorldPosition = pos
	puffEmitter:Emit(math.clamp(math.floor(volume * 14 * amount + 0.5), 1, 14))
	if amount >= 0.5 then
		sparkleEmitter:Emit(math.clamp(math.floor(volume * 6 * amount + 0.5), 1, 6))
	end
end

local function crunch(pos: Vector3, strength: number)
	if #sounds == 0 then
		return
	end
	soundIndex = soundIndex % #sounds + 1
	soundAttachments[soundIndex].WorldPosition = pos
	local s = sounds[soundIndex]
	s.Volume = Config.FootstepSoundVolume * math.clamp(0.4 + strength, 0.4, 1)
	s.PlaybackSpeed = 0.9 + math.random() * 0.2
	s:Play()
end

------------------------------------------------------------------------ slowdown
local resist = 0
local speedApplied: number? = nil
local speedBase = 16
local speedHumanoid: Humanoid? = nil

local function applySlowdown(dt: number, framePen: number)
	local char = localPlayer and localPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum ~= speedHumanoid then
		speedHumanoid = hum
		speedApplied = nil
		resist = 0
	end
	if not hum then
		return
	end
	local depth = math.max(Config.SnowDepth, 0.2)
	local r = math.clamp(framePen / depth, 0, 1)
	resist = math.max(r, resist * math.exp(-dt / 0.4))
	local factor = 1 - Config.SlowdownStrength * resist

	if speedApplied == nil or math.abs(hum.WalkSpeed - speedApplied) > 1e-3 then
		-- first time, or another script changed WalkSpeed: that is the new base
		if factor >= 0.999 and speedApplied == nil then
			return
		end
		speedBase = hum.WalkSpeed
	end
	if factor >= 0.999 then
		if speedApplied ~= nil then
			hum.WalkSpeed = speedBase
			speedApplied = nil
		end
		return
	end
	local target = speedBase * factor
	if math.abs(hum.WalkSpeed - target) > 0.01 then
		hum.WalkSpeed = target
	end
	speedApplied = hum.WalkSpeed
end

------------------------------------------------------------------------ deformers
-- Presses the shape currently in `shape` into the snow.
local function pressShape(t: number, collect: boolean): boolean
	-- broad phase: is there simulated snow under this shape that reaches up to it?
	local reach = false
	local cx0, cx1 = field:chunkRange(shape.minX, shape.maxX)
	local cz0, cz1 = field:chunkRange(shape.minZ, shape.maxZ)
	for cz = cz0, cz1 do
		for cx = cx0, cx1 do
			local chunk = field:getChunk(cx, cz)
			if chunk then
				local full = chunk.full
				if full then
					if shape.minY < full.maxY then
						reach = true
						need(chunk, t)
					end
				else
					-- not simulated yet: ask the loader for it if we might touch it
					local near = true
					for _, g in chunk.coarse do
						near = shape.minY < g.maxY + 2
						break
					end
					if near then
						need(chunk, t)
					end
				end
			end
		end
	end
	if not reach then
		return false
	end
	if collect then
		SnowField.resetStats(stats)
		return field:stamp(shape, 0, t, stats, nil)
	end
	return field:stamp(shape, 0, t, nil, nil)
end

-- something resting in the snow is pressed again this often (before its dent starts to regrow)
local REPRESS = math.clamp(Config.RegrowDelay * 0.5, 0, 1)

-- A new `last` record for pressPart.
local function newLast(): { number }
	-- 1-4: x, y, z, time of the previous call; 5: time of the last real press;
	-- 6-14: position and rotation at that press; 15: simEpoch at that press
	return { 0, 0, 0, -math.huge, -math.huge, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1 }
end

-- Did the part stay where it was last pressed (a standing player's feet)?
local function samePose(
	last: { number },
	px: number,
	py: number,
	pz: number,
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number
): boolean
	return math.abs(px - last[6]) < 0.005
		and math.abs(py - last[7]) < 0.005
		and math.abs(pz - last[8]) < 0.005
		and math.abs(r00 - last[9]) < 0.002
		and math.abs(r01 - last[10]) < 0.002
		and math.abs(r02 - last[11]) < 0.002
		and math.abs(r10 - last[12]) < 0.002
		and math.abs(r11 - last[13]) < 0.002
		and math.abs(r12 - last[14]) < 0.002
end

--[[
	Presses `part` into the snow at its current pose. `last` (see newLast) remembers its previous
	press: when it moved further than about half its own width since then (fast objects, low frame
	rates), it is also pressed in between, so it leaves a continuous trail, not a row of dents. A
	part resting where it was pressed is only pressed again once a second (keeps its dent fresh).
	Returns whether a press at the current pose touched snow (`stats` then describes it).
]]
local function pressPart(part: BasePart, kind: number, t: number, collect: boolean, last: { number }?): boolean
	local size = part.Size
	local px, py, pz, r00, r01, r02, r10, r11, r12, r20, r21, r22 = part.CFrame:GetComponents()
	-- broken physics (NaN) or a part flung far away: ignore it
	if not (math.abs(px) < 1e6 and math.abs(py) < 1e6 and math.abs(pz) < 1e6) then
		return false
	end
	if
		last
		and t - last[5] < REPRESS
		and last[15] == simEpoch
		and samePose(last, px, py, pz, r00, r01, r02, r10, r11, r12)
	then
		last[1], last[2], last[3], last[4] = px, py, pz, t
		return false
	end
	local sx, sy, sz = size.X, size.Y, size.Z
	Shapes.set(shape, kind, px, py, pz, r00, r01, r02, r10, r11, r12, r20, r21, r22, sx, sy, sz)
	local width = math.min(shape.maxX - shape.minX, shape.maxZ - shape.minZ)
	local hit = pressShape(t, collect)
	if last then
		local lx, ly, lz = last[1], last[2], last[3]
		local dx, dy, dz = px - lx, py - ly, pz - lz
		local gap = math.sqrt(dx * dx + dz * dz)
		local spacing = math.max(0.6 * width, 0.25)
		-- (not after a teleport or a long pause)
		if t - last[4] < 0.25 and gap > spacing and gap < 16 then
			local n = math.min(math.ceil(gap / spacing) - 1, 6)
			for k = 1, n do
				local f = k / (n + 1)
				Shapes.set(shape, kind, lx + dx * f, ly + dy * f, lz + dz * f, r00, r01, r02, r10, r11, r12, r20, r21, r22, sx, sy, sz)
				pressShape(t, false)
			end
		end
		last[1], last[2], last[3], last[4] = px, py, pz, t
		last[5], last[6], last[7], last[8] = t, px, py, pz
		last[9], last[10], last[11], last[12], last[13], last[14] = r00, r01, r02, r10, r11, r12
		last[15] = simEpoch
	end
	return hit
end

local function refreshCharParts(info: CharInfo)
	local list, kinds = {}, {}
	local rootPart = info.humanoid.RootPart
	for _, child in info.model:GetChildren() do
		if child:IsA("BasePart") and child.Name ~= "HumanoidRootPart" and child ~= rootPart then
			table.insert(list, child)
			table.insert(kinds, shapeKind(child))
		end
	end
	info.parts = list
	info.kinds = kinds
	-- forget parts that left the character
	for part in info.lastPress do
		if part.Parent ~= info.model then
			info.lastPress[part] = nil
			info.fxCooldown[part] = nil
			info.lastSent[part] = nil
		end
	end
	local root = info.model:FindFirstChild("HumanoidRootPart")
	info.root = if root and root:IsA("BasePart") then root else info.humanoid.RootPart
end

local function untrackCharacter(model: Model)
	local info = characters[model]
	if not info then
		return
	end
	characters[model] = nil
	for _, c in info.conns do
		c:Disconnect()
	end
end

local function trackHumanoid(humanoid: Humanoid)
	if not Config.DeformByCharacters then
		return
	end
	local model = humanoid.Parent
	if not model or not model:IsA("Model") or characters[model] then
		return
	end
	if snowFolder and model:IsDescendantOf(snowFolder) then
		return
	end
	if hasTagUpTo(model, Config.IgnoreTag, Workspace) then
		return
	end
	local info: CharInfo = {
		model = model,
		humanoid = humanoid,
		root = nil,
		parts = {},
		kinds = {},
		simulated = false,
		conns = {},
		fxCooldown = {},
		lastSent = {},
		lastPress = {},
	}
	characters[model] = info
	refreshCharParts(info)
	local function refresh()
		if characters[model] == info then
			refreshCharParts(info)
		end
	end
	table.insert(info.conns, model.ChildAdded:Connect(refresh))
	table.insert(info.conns, model.ChildRemoved:Connect(refresh))
	table.insert(
		info.conns,
		model.AncestryChanged:Connect(function()
			if not model:IsDescendantOf(Workspace) then
				untrackCharacter(model)
			end
		end)
	)
	table.insert(
		info.conns,
		humanoid.AncestryChanged:Connect(function()
			if humanoid.Parent ~= model then
				untrackCharacter(model)
			end
		end)
	)
end

local function isCharacterPart(part: BasePart): boolean
	local node: Instance? = part.Parent
	for _ = 1, 4 do
		if not node then
			return false
		end
		if node:IsA("Model") and characters[node :: Model] then
			return true
		end
		node = node.Parent
	end
	return false
end

-- tagged models: parts added later (or streamed back in) are deformers too
local taggedConns: { [Instance]: RBXScriptConnection } = {}

local function addTagged(inst: Instance)
	local function add(p: BasePart)
		local d = deformers[p]
		if d then
			d.tagged = true
		else
			deformers[p] = {
				kind = shapeKind(p),
				last = newLast(),
				lastCF = nil,
				lastSize = nil,
				lastStamp = 0,
				lastSeen = math.huge,
				tagged = true,
			}
		end
	end
	if inst:IsA("BasePart") then
		add(inst)
	elseif not taggedConns[inst] then
		taggedConns[inst] = inst.DescendantAdded:Connect(function(d)
			if d:IsA("BasePart") then
				add(d)
			end
		end)
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			add(d)
		end
	end
end

local function removeTagged(inst: Instance)
	local conn = taggedConns[inst]
	if conn then
		conn:Disconnect()
		taggedConns[inst] = nil
	end
	local function remove(p: BasePart)
		local d = deformers[p]
		if d then
			d.tagged = false
			d.lastSeen = now()
		end
	end
	if inst:IsA("BasePart") then
		remove(inst)
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			remove(d)
		end
	end
end

-- Looks for unanchored parts in the snow layer of one chunk (between minY and maxY).
local function scanChunk(chunk: Chunk, minY: number, maxY: number, t: number)
	local maxSize = Config.MaxDeformerSize
	local cxw, czw = field:chunkCenter(chunk)
	local dx, dz = cxw - camPos.X, czw - camPos.Z
	if dx * dx + dz * dz < SIM_DIST2 then
		local h = maxY - minY + 1
		local found = Workspace:GetPartBoundsInBox(
			CFrame.new(cxw, (minY + maxY) * 0.5, czw),
			Vector3.new(CHUNK_SPAN, h, CHUNK_SPAN),
			overlapParams
		)
		for _, p in found do
			local d = deformers[p]
			if d then
				d.lastSeen = t
			elseif not p.Anchored and not isCharacterPart(p) then
				local s = p.Size
				if math.max(s.X, s.Y, s.Z) <= maxSize and not hasTagUpTo(p, Config.IgnoreTag, Workspace) then
					deformers[p] = {
						kind = shapeKind(p),
						last = newLast(),
						lastCF = nil,
						lastSize = nil,
						lastStamp = 0,
						lastSeen = t,
						tagged = false,
					}
				end
			end
		end
	end
end

-- Finds unanchored parts touching the snow: every simulated chunk, plus a few of the drawn but
-- not simulated chunks a little farther away (a part found there wakes up their simulation).
local function scanDynamic(t: number)
	if not Config.DeformByUnanchoredParts then
		return
	end
	for chunk in simChunks do
		local full = chunk.full
		if full and full.snowCount > 0 and alive(chunk) then
			scanChunk(chunk, full.minY, full.maxY, t)
		end
	end
	local n = #scanFar
	for _ = 1, math.min(n, 6) do
		scanFarIndex = scanFarIndex % n + 1
		local chunk = scanFar[scanFarIndex]
		if alive(chunk) and not chunk.full then
			for _, g in chunk.coarse do
				scanChunk(chunk, g.minY, g.maxY + 2, t)
				break
			end
		end
	end
end

local function queueOutgoing(part: BasePart, info: CharInfo, kind: number, t: number)
	if not remote then
		return
	end
	local pos = part.Position
	local last = info.lastSent[part]
	if last and t - last.t < 0.1 and (pos - last.pos).Magnitude < 0.3 then
		return
	end
	info.lastSent[part] = { t = t, pos = pos }
	local size = part.Size
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = part.CFrame:GetComponents()
	table.insert(outbox, {
		kind = kind,
		px = pos.X,
		py = pos.Y,
		pz = pos.Z,
		r00 = r00,
		r01 = r01,
		r02 = r02,
		r10 = r10,
		r11 = r11,
		r12 = r12,
		r20 = r20,
		r21 = r21,
		r22 = r22,
		sx = size.X,
		sy = size.Y,
		sz = size.Z,
		userId = 0,
		time = 0,
	})
	if #outbox > 200 then
		table.remove(outbox, 1)
	end
end

-- Where the last press happened, at the top of the untouched snow (for puffs/sounds).
local function contactPoint(): Vector3
	local cx, cz = stats.sumX / stats.count, stats.sumZ / stats.count
	local y = stats.sumY / stats.count
	local base, rest = field:columnAt(cx, cz)
	if base and rest > y then
		y = rest
	end
	return Vector3.new(cx, y + 0.1, cz)
end

local function stepDeformers(t: number, dt: number)
	local localChar = localPlayer and localPlayer.Character
	local framePen = 0
	local areaScale = CELL * CELL

	for model, info in characters do
		local root = info.root
		if root and root.Parent then
			local pos = root.Position
			local dx, dy, dz = pos.X - camPos.X, pos.Y - camPos.Y, pos.Z - camPos.Z
			local d2 = dx * dx + dy * dy + dz * dz
			local isLocal = model == localChar
			info.simulated = isLocal or d2 < CHAR_SIM_DIST2
			if info.simulated then
				-- warm up the snow around them before they step into it
				local snowTop = -math.huge -- highest simulated snow (rims included) around them
				local cx0, cx1 = field:chunkRange(pos.X - 10, pos.X + 10)
				local cz0, cz1 = field:chunkRange(pos.Z - 10, pos.Z + 10)
				for cz = cz0, cz1 do
					for cx = cx0, cx1 do
						local chunk = field:getChunk(cx, cz)
						if chunk then
							local full = chunk.full
							if not full or pos.Y - 8 < full.maxY then
								need(chunk, t)
							end
							if full and full.maxY > snowTop then
								snowTop = full.maxY
							end
						end
					end
				end
				local nearFx = d2 < FX_DIST2
				for k, part in info.parts do
					local last = info.lastPress[part]
					if not last then
						last = newLast()
						info.lastPress[part] = last
					end
					local pressed = false
					if part.Parent then
						-- arms, head, torso... far above the snow: skip the exact shape test
						local p, s = part.Position, part.Size
						local hx, hz = p.X - pos.X, p.Z - pos.Z
						-- (invisible parts: hitboxes and helpers welded to the character)
						if
							(p.Y - 0.5 * s.Magnitude > snowTop and hx * hx + hz * hz < 64)
							or part.Transparency >= 0.99
						then
							last[1], last[2], last[3], last[4] = p.X, p.Y, p.Z, t
						else
							pressed = pressPart(part, info.kinds[k], t, true, last)
						end
					end
					if pressed then
						local vol = stats.volume * areaScale
						if isLocal then
							if stats.maxPen > framePen then
								framePen = stats.maxPen
							end
							queueOutgoing(part, info, info.kinds[k], t)
						end
						if nearFx and stats.count > 0 and vol > 0.04 then
							local cd = info.fxCooldown[part]
							if not cd or t - cd > 0.12 then
								info.fxCooldown[part] = t
								local at = contactPoint()
								if Config.FootstepParticles then
									puff(at, vol)
								end
								if d2 < SOUND_DIST2 then
									crunch(at, vol)
								end
							end
						end
					end
				end
			end
		else
			info.simulated = false
		end
	end

	for p, d in deformers do
		if not p.Parent or (not d.tagged and t - d.lastSeen > 0.6) then
			deformers[p] = nil
		elseif d.tagged and not p:IsDescendantOf(Workspace) then
			-- a tagged tool in a backpack, a template in ReplicatedStorage...: not in the world
			d.lastCF = nil
			d.last[4], d.last[5] = -math.huge, -math.huge
		else
			local cf = p.CFrame
			local size = p.Size
			-- a resting object only needs re-pressing now and then (keeps its dent from regrowing)
			if cf ~= d.lastCF or size ~= d.lastSize or t - d.lastStamp > REPRESS then
				local pos = cf.Position
				local dx, dz = pos.X - camPos.X, pos.Z - camPos.Z
				if dx * dx + dz * dz < SIM_DIST2 then
					d.lastCF, d.lastSize, d.lastStamp = cf, size, t
					local collect = Config.FootstepParticles
					if pressPart(p, d.kind, t, collect, d.last) and collect then
						local vol = stats.volume * areaScale
						if vol > 0.08 and stats.count > 0 and dx * dx + dz * dz < FX_DIST2 then
							puff(contactPoint(), math.min(vol, 1))
						end
					end
				end
			else
				-- resting where it was last pressed: that press is as good as a fresh one
				d.last[4] = t
			end
		end
	end

	if Config.SlowdownInDeepSnow then
		applySlowdown(dt, framePen)
	end
end

------------------------------------------------------------------------ mesh updates
-- Flags a neighbour chunk's border vertex for a normal refresh (its shading depends on our columns).
local function pokeNeighbor(chunk: Chunk, dcx: number, dcz: number, ni: number)
	local nb = field:getChunk(chunk.cx + dcx, chunk.cz + dcz)
	if nb and nb.full and nb.render and nb.dirty[ni] == nil then
		nb.dirty[ni] = 2
		nb.dirtyCount += 1
	end
end

local spareDirty: { [number]: number }? = {}

local function flushMeshes(t: number)
	local C = CHUNK_CELLS
	local n = C + 1
	local tint = Config.PackedSnowTint
	local lowEnd = tierIndex <= 2
	for chunk in simChunks do
		if not alive(chunk) or not chunk.full then
			simChunks[chunk] = nil
		elseif chunk.dirtyCount > 0 then
			local rs = chunk.render :: RenderState?
			local mesh = rs and rs.mesh
			-- snow farther away (and all snow on weak devices) is redrawn at most 20x a second;
			-- its changes keep collecting in chunk.dirty meanwhile
			if rs and mesh and (mesh.step >= 2 or lowEnd) and t - rs.lastFlush < 0.05 then
				continue
			end
			if rs then
				rs.lastFlush = t
			end
			local dirty = chunk.dirty
			-- (reuse last flush's table; taken first so an error below can never share it)
			chunk.dirty = spareDirty or {}
			spareDirty = nil
			chunk.dirtyCount = 0
			if mesh and mesh.usesFull then
				local ok, err = pcall(mesh.applyDirty :: any, mesh, field, chunk, dirty, false, tint)
				if not ok then
					if useParts then
						error(err, 0)
					end
					-- Roblox can revoke EditableMesh access mid-session
					switchToParts("EditableMesh stopped working.")
				end
			end
			for i, flag in dirty do
				-- neighbour pokes only refresh mesh shading; the Parts renderer has none
				if flag == 1 and not useParts then
					local lx, lz = i % n, i // n
					if lx > 0 and lx <= 8 then
						pokeNeighbor(chunk, -1, 0, lz * n + C)
					elseif lx < C and lx >= C - 8 then
						pokeNeighbor(chunk, 1, 0, lz * n)
					end
					if lz > 0 and lz <= 8 then
						pokeNeighbor(chunk, 0, -1, C * n + lx)
					elseif lz < C and lz >= C - 8 then
						pokeNeighbor(chunk, 0, 1, lx)
					end
				end
			end
			table.clear(dirty)
			spareDirty = dirty
		end
	end
end

local function stepRegrow(t: number)
	if Config.RegrowSpeed <= 0 then
		return
	end
	for chunk in simChunks do
		local full = chunk.full
		if full and full.activeCount > 0 and t - full.lastRegrow >= REGROW_INTERVAL then
			field:regrow(chunk, t)
		end
	end
end

------------------------------------------------------------------------ networking

local function isSimulatedLocally(userId: number): boolean
	local plr = Players:GetPlayerByUserId(userId)
	local char = plr and plr.Character
	local info = char and characters[char]
	return info ~= nil and info.simulated
end

local function onRemote(kind: any, payload: any)
	if stopped or (kind ~= "relay" and kind ~= "history") then
		return
	end
	local list = StampCodec.decodeRelay(payload)
	if not list then
		return
	end
	local serverNow = Workspace:GetServerTimeNow()
	local t = now()
	local maxAge = maxPrintAge()
	local myId = localPlayer and localPlayer.UserId or 0
	for _, s in list do
		if kind == "relay" and (s.userId == myId or isSimulatedLocally(s.userId)) then
			continue
		end
		local age = math.max(0, serverNow - s.time)
		if maxAge and age > maxAge then
			continue
		end
		local sh = Shapes.new()
		Shapes.set(sh, s.kind, s.px, s.py, s.pz, s.r00, s.r01, s.r02, s.r10, s.r11, s.r12, s.r20, s.r21, s.r22, s.sx, s.sy, s.sz)
		field:queueStamp(sh, t, t - age)
	end
end

local function connectRemote()
	if not Config.SyncFootprints then
		return
	end
	local folder = ReplicatedStorage:WaitForChild("DeformableSnowRemotes", 30)
	if not folder then
		warn("[DeformableSnow] server script not found - footprints are not shared with late joiners")
		return
	end
	local ev = folder:WaitForChild("Footprints", 10)
	if not ev or not ev:IsA("RemoteEvent") then
		return
	end
	ev.OnClientEvent:Connect(onRemote)
	remote = ev
	-- ask for the history only once our snow parts are known (prints need chunks to land in)
	while not partsReady and not stopped do
		task.wait(0.1)
	end
	ev:FireServer("hello")
end

local function flushOutbox()
	local ev = remote
	if ev and #outbox > 0 then
		local packet = StampCodec.encodeClient(outbox)
		table.clear(outbox)
		ev:FireServer(packet)
	end
end

------------------------------------------------------------------------ quality & preloading
local prewarming = false
local settleUntil = 0 -- the frame-rate watcher waits while a quality change is being applied

-- Creates the Parts the renderer will need ahead of time, a little every frame.
local function prewarmPool()
	if prewarming or not useParts then
		return
	end
	prewarming = true
	local started = os.clock()
	ChunkParts.prewarm(style, tier.poolBoxes, tier.poolWedges, function()
		if os.clock() - started > 0.002 then
			RunService.Heartbeat:Wait()
			started = os.clock()
		end
	end)
	prewarming = false
end

-- Switches to another quality tier (the frame-rate watcher decided, see Quality.luau).
local function applyTier(index: number)
	tierIndex = index
	tier = Quality.TIERS[index]
	tierSettings()
	local smooth = math.max(0.005, Config.PartsSmoothness * tier.smoothness)
	if style.smoothness ~= smooth then
		style.smoothness = smooth
		styleVersion += 1
		-- chunks without triangles only need the new setting (no Part changes); the others are
		-- re-triangulated in place, one by one in the background
		for chunk in loaded do
			local rs = chunk.render :: RenderState?
			local mesh = rs and rs.mesh
			local restyle = mesh and mesh.restyle
			if rs and mesh and restyle and not rs.building and (mesh.wedgeCount or 0) == 0 then
				restyle(mesh, chunk, smooth, nil)
				rs.styleVersion = styleVersion
			end
		end
		settleUntil = now() + 15
	end
	local shadows = Config.CastShadow and tier.shadows
	if style.castShadow ~= shadows then
		-- pooled Parts pick up the setting when they are reused; the drawn ones are switched a
		-- few chunks per frame (thousands of Parts at once would be a hitch on a slow device)
		style.castShadow = shadows
		local list = {}
		for chunk in loaded do
			table.insert(list, chunk)
		end
		task.spawn(function()
			local started = os.clock()
			for _, chunk in list do
				if style.castShadow ~= shadows or stopped then
					return
				end
				local rs = chunk.render :: RenderState?
				local mesh = rs and rs.mesh
				if mesh then
					mesh:setShadows(shadows)
				end
				if os.clock() - started > 0.002 then
					RunService.Heartbeat:Wait()
					started = os.clock()
				end
			end
		end)
	end
	renderFolder:SetAttribute("SnowQuality", tier.name)
	SnowWeather.setTier(tier)
	task.spawn(prewarmPool)
	if Config.Debug then
		print(`[DeformableSnow] quality -> {tier.name}`)
	end
end

local readySent = false
local readyDeadline = math.huge

-- Sets Workspace.DeformableSnowRender's "SnowReady" attribute once the snow around the player is
-- drawn (a loading screen can wait for it), and ends the heavier preloading.
local function checkReady()
	if readySent or not partsReady then
		return
	end
	local t = now()
	-- (a loading screen must never wait forever: after the deadline it is "ready" anyway)
	if t < readyDeadline then
		if t - lastTracked < 0.5 then
			return -- snow parts are still arriving (StreamingEnabled)
		end
		local char = localPlayer and localPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart")) or (root.Position - camPos).Magnitude > 60 then
			return -- not spawned yet, or the camera is not at the character yet
		end
		for _, chunk in planned do
			local rs = chunk.render :: RenderState?
			if rs and rs.dist < LOD1 and rs.wantStep > 0 then
				local mesh = rs.mesh
				local drawn = (mesh ~= nil and mesh.step == rs.wantStep)
					or (rs.emptyVersion == chunk.gridVersion and rs.emptyStep == rs.wantStep)
				if not drawn then
					return
				end
			end
		end
	end
	readySent = true
	renderFolder:SetAttribute("SnowReady", true)
	preloadUntil = math.min(preloadUntil, t + 1)
end

------------------------------------------------------------------------ the SnowParts folder
local folderConns: { RBXScriptConnection } = {}

-- Forgets kept prints that have regrown by now (every few seconds).
local function pruneKeptPrints()
	local t = now()
	local age = maxPrintAge() or 300
	for key, d in detached do
		if t - d.time > age then
			detached[key] = nil
		end
	end
	field:pruneOrphans(t)
end

-- Forgets every snow part (the SnowParts folder was removed, e.g. a round-based game changing maps).
local function dropFolder()
	for _, c in folderConns do
		c:Disconnect()
	end
	table.clear(folderConns)
	local list = {}
	for part in parts do
		table.insert(list, part)
	end
	for _, part in list do
		untrackPart(part)
	end
	table.clear(refreshQueue)
	-- a different map: old prints do not belong on it
	table.clear(detached)
	snowFolder = nil
end

-- Puts snow on everything in this folder, and keeps following it.
function useFolder(sf: Instance)
	if snowFolder == sf then
		return
	end
	if snowFolder then
		dropFolder()
	end
	snowFolder = sf
	overlapParams.FilterDescendantsInstances = { renderFolder, sf }
	for _, d in sf:GetDescendants() do
		if d:IsA("BasePart") then
			trackPart(d)
		end
	end
	table.insert(
		folderConns,
		sf.DescendantAdded:Connect(function(d)
			if d:IsA("BasePart") then
				trackPart(d)
			end
		end)
	)
	table.insert(
		folderConns,
		sf.DescendantRemoving:Connect(function(d)
			if d:IsA("BasePart") then
				untrackPart(d)
			end
		end)
	)
	-- (removing the folder itself fires no DescendantRemoving for what is inside it)
	table.insert(
		folderConns,
		sf.AncestryChanged:Connect(function()
			if snowFolder == sf and not sf:IsDescendantOf(Workspace) then
				dropFolder()
				local other = Workspace:FindFirstChild(Config.SnowFolderName)
				if other then
					useFolder(other)
				end
			end
		end)
	)
end

------------------------------------------------------------------------ start
function SnowClient.start()
	if (shared :: any).__DeformableSnowClient then
		warn("[DeformableSnow] client already running (is the folder in two places?)")
		return
	end
	(shared :: any).__DeformableSnowClient = true

	field = SnowField.new({
		cellSize = CELL,
		chunkCells = CHUNK_CELLS,
		-- the Parts renderer draws clean, straight snow edges; thinning them out (smoothly, with
		-- triangles) would cost far too many Parts along every edge
		edgeFalloff = if useParts then 0 else math.max(0, Config.EdgeFalloff),
		minThickness = math.max(0.01, Config.MinThickness),
		cliffHeight = math.max(0.5, Config.CliffHeight),
		maxSlopeCos = math.cos(math.rad(math.clamp(Config.MaxSlopeAngle, 1, 89))),
		rimRatio = math.max(0, Config.RimRatio),
		rimWidth = math.max(0.01, Config.RimWidth),
		regrowDelay = math.max(0, Config.RegrowDelay),
		regrowSpeed = math.max(0, Config.RegrowSpeed),
		maxPendingPerChunk = 600,
		maxPendingAge = maxPrintAge(),
	})

	local folder = Instance.new("Folder")
	folder.Name = "DeformableSnowRender"
	folder.Parent = Workspace
	renderFolder = folder

	style = {
		color = Config.SnowColor,
		packedTint = Config.PackedSnowTint,
		material = Config.Material,
		materialVariant = Config.MaterialVariant,
		studsPerTile = math.max(0.5, Config.TextureStudsPerTile),
		smoothness = math.max(0.005, Config.PartsSmoothness * tier.smoothness),
		castShadow = Config.CastShadow and tier.shadows,
		parent = renderFolder,
	}
	setupEffects()
	-- falling snow, fog, winter light, lens flares (Config.Weather)
	task.spawn(function()
		local ok, err = pcall(function()
			SnowWeather.start({
				tier = tier,
				surfaceAt = function(x: number, z: number): number?
					local base, _, cur = field:columnAt(x, z)
					return if base then cur else nil
				end,
				exclude = { renderFolder :: Instance },
			})
		end)
		if not ok then
			warn("[DeformableSnow] weather: " .. tostring(err))
		end
	end)
	renderFolder:SetAttribute("SnowQuality", tier.name)
	renderFolder:SetAttribute("SnowReady", false)
	-- particle/sound assets load in the background so the first puff is not blank
	task.spawn(function()
		pcall(function()
			local list: { Instance } = { puffEmitter, sparkleEmitter }
			for _, snd in sounds do
				table.insert(list, snd)
			end
			game:GetService("ContentProvider"):PreloadAsync(list)
		end)
	end)

	-- snow parts
	task.spawn(function()
		local f = Workspace:WaitForChild(Config.SnowFolderName, 10)
		if not f then
			warn(`[DeformableSnow] waiting for Workspace.{Config.SnowFolderName} (put your snow parts in it)`)
			f = Workspace:WaitForChild(Config.SnowFolderName)
		end
		if not snowFolder then
			useFolder(f :: Instance)
		end
		partsReady = true
		-- preload: build the snow around the camera quickly and get Parts ready before anyone walks
		preloadUntil = now() + math.max(0, Config.PreloadSeconds)
		readyDeadline = now() + math.max(0, Config.PreloadSeconds) + 10
		task.spawn(prewarmPool)
	end)
	-- a new map: a new SnowParts folder (the old one was removed, see useFolder)
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == Config.SnowFolderName and snowFolder == nil and partsReady then
			useFolder(child)
		end
	end)
	CollectionService:GetInstanceAddedSignal(Config.IgnoreTag):Connect(function(inst: Instance)
		if inst:IsA("BasePart") then
			untrackPart(inst)
		end
		for _, d in inst:GetDescendants() do
			if d:IsA("BasePart") then
				untrackPart(d)
			end
		end
	end)
	CollectionService:GetInstanceRemovedSignal(Config.IgnoreTag):Connect(function(inst: Instance)
		local sf = snowFolder
		if not sf or not inst:IsDescendantOf(sf) then
			return
		end
		if inst:IsA("BasePart") then
			trackPart(inst)
		end
		for _, d in inst:GetDescendants() do
			if d:IsA("BasePart") then
				trackPart(d)
			end
		end
	end)

	-- characters & NPCs
	for _, d in Workspace:GetDescendants() do
		if d:IsA("Humanoid") then
			trackHumanoid(d)
		end
	end
	Workspace.DescendantAdded:Connect(function(d)
		if d:IsA("Humanoid") then
			task.defer(trackHumanoid, d)
		end
	end)

	-- tagged deformers
	for _, inst in CollectionService:GetTagged(Config.DeformerTag) do
		addTagged(inst)
	end
	CollectionService:GetInstanceAddedSignal(Config.DeformerTag):Connect(addTagged)
	CollectionService:GetInstanceRemovedSignal(Config.DeformerTag):Connect(removeTagged)

	-- (re)spawning: build the snow around the new spot quickly again
	if localPlayer then
		localPlayer.CharacterAdded:Connect(function()
			if partsReady then
				preloadUntil = math.max(preloadUntil, now() + math.max(0, Config.PreloadSeconds))
			end
		end)
	end

	task.spawn(connectRemote)
	task.spawn(workerLoop)

	local planTimer, scanTimer, sendTimer, debugTimer, pruneTimer = 0, 0, 0, 0, 0
	local frame, deformDt = 0, 0
	-- climbs back up after a slowdown, but never above the player's own graphics setting, and a
	-- phone never goes to High
	local deviceCap = if DEVICE.touchOnly then 3 else 4
	local graphicsCap = if DEVICE.graphicsLevel
		then Quality.initialTier({ touchOnly = false, console = false, graphicsLevel = DEVICE.graphicsLevel })
		else 4
	local maxTier = math.max(START_TIER, math.min(deviceCap, graphicsCap))
	local monitor = Quality.newMonitor(START_TIER, maxTier, FORCED_TIER ~= nil)
	-- a minimized / unfocused game runs slower for reasons that have nothing to do with the snow
	local focused = true
	pcall(function()
		local uis = game:GetService("UserInputService")
		uis.WindowFocusReleased:Connect(function()
			focused = false
		end)
		uis.WindowFocused:Connect(function()
			focused = true
			monitor.warmup = math.max(monitor.warmup, 3)
		end)
	end)
	local lastError: string? = nil
	-- runs one piece of the frame update; an unexpected error is reported once instead of every frame
	local function protected(fn: (...any) -> (), ...: any)
		local ok, err = pcall(fn :: any, ...)
		if not ok and tostring(err) ~= lastError then
			lastError = tostring(err)
			warn("[DeformableSnow] " .. tostring(err))
		end
	end

	RunService.Heartbeat:Connect(function(dt: number)
		if stopped then
			return
		end
		local t = now()
		local cam = Workspace.CurrentCamera
		if cam then
			camPos = cam.CFrame.Position
		end

		-- weak devices press the snow every other frame (still 30 times a second)
		frame += 1
		deformDt += dt
		if frame % tier.deformEvery == 0 then
			protected(stepDeformers, t, deformDt)
			deformDt = 0
		end
		protected(stepRegrow, t)
		protected(flushMeshes, t)

		-- the extra loading work right after joining, or after a quality change, is not a reason to
		-- lower the quality (again)
		if not partsReady or t < preloadUntil then
			monitor.warmup = math.max(monitor.warmup, 1)
		elseif t < settleUntil and #workList > 0 then
			monitor.cooldown = math.max(monitor.cooldown, 0.5)
		end
		local newTier = if focused then Quality.step(monitor, dt) else nil
		if newTier then
			protected(applyTier, newTier)
		end

		planTimer += dt
		if planTimer >= 0.25 then
			planTimer = 0
			protected(processRefreshQueue)
			protected(plan)
			protected(checkReady)
		end
		scanTimer += dt
		if scanTimer >= tier.scanInterval then
			scanTimer = 0
			protected(scanDynamic, t)
		end
		sendTimer += dt
		if sendTimer >= 0.25 then
			sendTimer = 0
			protected(flushOutbox)
		end
		pruneTimer += dt
		if pruneTimer >= 5 then
			pruneTimer = 0
			protected(pruneKeptPrints)
		end
		if Config.Debug then
			debugTimer += dt
			if debugTimer >= 5 then
				debugTimer = 0
				local nChunks, nFull, nMesh, nActive = 0, 0, 0, 0
				for _, chunk in field.chunks do
					nChunks += 1
					if chunk.full then
						nFull += 1
						nActive += chunk.full.activeCount
					end
					local rs = chunk.render :: RenderState?
					if rs and rs.mesh then
						nMesh += 1
					end
				end
				local nParts = 0
				for _ in parts do
					nParts += 1
				end
				print(
					`[DeformableSnow] snowParts={nParts} chunks={nChunks} simulated={nFull} drawn={nMesh} `
						.. `regrowing={nActive} queue={#workList} renderer={if useParts then "Parts" else "EditableMesh"} `
						.. `boxes={ChunkParts.liveCount}`
				)
			end
		end
	end)
end

return SnowClient
