--!strict
--[[
	ChunkMesh
	Draws one SnowField chunk as an EditableMesh-backed MeshPart and keeps it in sync with the
	simulation (only the vertices that actually changed are re-uploaded).

	* step = level of detail (1 = every column, 2 = every other column, ...).
	* Snow that has been pressed down is tinted (vertex colours multiply MeshPart.Color).
	* Every chunk border gets a thin "skirt" hanging down to the ground so no cracks show between
	  neighbouring chunks drawn at different detail levels.
	* Two microscopic triangles pin the mesh bounding box so it never changes size while the
	  surface is being deformed (keeps the MeshPart from shifting/scaling).
]]

local AssetService = game:GetService("AssetService")

local SnowField = require(script.Parent.SnowField)

local readf32 = buffer.readf32
local NO_SNOW_LIMIT = SnowField.NO_SNOW_LIMIT
local WHITE = Color3.new(1, 1, 1)

local ChunkMesh = {}
ChunkMesh.__index = ChunkMesh

export type Style = {
	color: Color3,
	packedTint: Color3,
	material: Enum.Material,
	materialVariant: string,
	studsPerTile: number,
	castShadow: boolean,
	parent: Instance,
	smoothness: number,
}

export type ChunkMesh = typeof(setmetatable(
	{} :: {
		step: number,
		nSide: number,
		em: EditableMesh,
		part: MeshPart?,
		order: { [number]: number }, -- lod index -> slot
		vids: { number }, -- slot -> vertex id
		nids: { number }, -- slot -> normal id
		cids: { number }, -- slot -> color id
		lodIndex: { number }, -- slot -> lod index
		gridVersion: number,
		version: number,
		half: number,
		midY: number,
		usesFull: boolean,
		batch: boolean,
		destroyed: boolean,
	},
	ChunkMesh
))

-- Batch APIs are much faster; fall back to the per-element API on engines without them.
local batchSupported: boolean? = nil
local function hasBatch(em: EditableMesh): boolean
	if batchSupported == nil then
		batchSupported = pcall(function()
			return (em :: any).BatchSetValues ~= nil and (em :: any).BatchAdd ~= nil
		end)
	end
	return batchSupported :: boolean
end

local function packedColor(base: number, rest: number, cur: number, tint: Color3): Color3
	if cur >= rest - 1e-3 then
		return WHITE
	end
	local depth = rest - base
	if depth < 0.05 then
		depth = 0.05
	end
	local t = (rest - cur) / depth * 1.6
	if t > 1 then
		t = 1
	end
	return WHITE:Lerp(tint, t)
end

type Source = {
	base: buffer,
	rest: buffer,
	cur: buffer,
	n: number,
	stride: number,
	minY: number,
	maxY: number,
}

local function sourceFor(chunk: SnowField.Chunk, step: number): Source?
	local full = chunk.full
	if full then
		return {
			base = full.base,
			rest = full.rest,
			cur = full.cur,
			n = full.n,
			stride = step,
			minY = full.minY,
			maxY = full.maxY,
		}
	end
	local g = chunk.coarse[step]
	if g then
		return {
			base = g.base,
			rest = g.rest,
			cur = g.rest,
			n = g.n,
			stride = 1,
			minY = g.minY,
			maxY = g.maxY,
		}
	end
	return nil
end

-- Height of LOD vertex (i, j) of this chunk, reaching into neighbour chunks when outside.
local function lodHeight(
	field: SnowField.SnowField,
	chunk: SnowField.Chunk,
	src: Source,
	step: number,
	nSide: number,
	i: number,
	j: number
): number?
	if i >= 0 and j >= 0 and i < nSide and j < nSide then
		local o = ((j * src.stride) * src.n + i * src.stride) * 4
		if readf32(src.base, o) <= NO_SNOW_LIMIT then
			return nil
		end
		return readf32(src.cur, o)
	end
	local C = field.params.chunkCells
	return field:heightAt(chunk.cx * C + i * step, chunk.cz * C + j * step)
end

local function lodNormal(
	field: SnowField.SnowField,
	chunk: SnowField.Chunk,
	src: Source,
	step: number,
	nSide: number,
	i: number,
	j: number,
	h: number
): Vector3
	local hl = lodHeight(field, chunk, src, step, nSide, i - 1, j) or h
	local hr = lodHeight(field, chunk, src, step, nSide, i + 1, j) or h
	local hd = lodHeight(field, chunk, src, step, nSide, i, j - 1) or h
	local hu = lodHeight(field, chunk, src, step, nSide, i, j + 1) or h
	local w = 2 * step * field.params.cellSize
	return Vector3.new(hl - hr, w, hd - hu).Unit
end

--[[
	Builds the mesh for a chunk. May yield (calls `budget` and CreateMeshPartAsync).
	Returns nil plus a reason when nothing could be built:
	  "empty"  - no snow in this chunk
	  "nodata" - the requested grid is not sampled
	  "budget"   - the device ran out of EditableMesh memory
	  "disabled" - EditableMesh is not allowed here (Mesh / Image APIs off for this experience)
	  "error"    - building the mesh failed
]]
function ChunkMesh.build(
	field: SnowField.SnowField,
	chunk: SnowField.Chunk,
	step: number,
	style: Style,
	budget: () -> ()
): (ChunkMesh?, string?)
	local src = sourceFor(chunk, step)
	if not src then
		return nil, "nodata"
	end
	local gridVersion = chunk.gridVersion
	local version = chunk.version
	local p = field.params
	local C, S = p.chunkCells, p.cellSize
	local cliff = p.cliffHeight
	local nSide = C // step + 1
	local half = C * S * 0.5
	local minY, maxY = src.minY - 0.1, src.maxY + 0.1
	local midY = (minY + maxY) * 0.5
	local halfY = (maxY - minY) * 0.5
	local tile = style.studsPerTile
	local cxw, czw = field:chunkCenter(chunk)
	local tint = style.packedTint

	-- 1) collect snow columns of this LOD
	local exists: { [number]: boolean } = {}
	local baseOf: { [number]: number } = {}
	local curOf: { [number]: number } = {}
	local restOf: { [number]: number } = {}
	for j = 0, nSide - 1 do
		for i = 0, nSide - 1 do
			local o = ((j * src.stride) * src.n + i * src.stride) * 4
			local b = readf32(src.base, o)
			if b > NO_SNOW_LIMIT then
				local idx = j * nSide + i
				exists[idx] = true
				baseOf[idx] = b
				restOf[idx] = readf32(src.rest, o)
				curOf[idx] = readf32(src.cur, o)
			end
		end
	end

	-- 2) triangles (CCW seen from above), skipping tall cliffs
	local tris: { number } = {} -- flat list of lod indices, 3 per triangle
	local used: { [number]: boolean } = {}
	local function tri(a: number, b: number, c: number)
		local ba, bb, bc = baseOf[a], baseOf[b], baseOf[c]
		if math.max(ba, bb, bc) - math.min(ba, bb, bc) > cliff then
			return
		end
		table.insert(tris, a)
		table.insert(tris, b)
		table.insert(tris, c)
		used[a], used[b], used[c] = true, true, true
	end
	for j = 0, nSide - 2 do
		for i = 0, nSide - 2 do
			local a = j * nSide + i -- (i, j)
			local b = a + 1 -- (i+1, j)
			local c = a + nSide -- (i, j+1)
			local d = c + 1 -- (i+1, j+1)
			local ea, eb, ec, ed = exists[a], exists[b], exists[c], exists[d]
			if ea and eb and ec and ed then
				if (i + j) % 2 == 0 then
					tri(a, c, b)
					tri(b, c, d)
				else
					tri(a, c, d)
					tri(a, d, b)
				end
			elseif eb and ec and ed then
				tri(b, c, d)
			elseif ea and ec and ed then
				tri(a, c, d)
			elseif ea and eb and ed then
				tri(a, d, b)
			elseif ea and eb and ec then
				tri(a, c, b)
			end
		end
		if j % 8 == 0 then
			budget()
		end
	end
	if #tris == 0 then
		return nil, "empty"
	end

	-- 3) one vertex + one normal/uv/colour per used surface column
	local order: { [number]: number } = {}
	local lodIndex: { number } = {}
	local positions: { Vector3 } = {}
	local normals: { Vector3 } = {}
	local uvs: { Vector2 } = {}
	local colors: { Color3 } = {}
	local alphas: { number } = {}
	for j = 0, nSide - 1 do
		for i = 0, nSide - 1 do
			local idx = j * nSide + i
			if used[idx] then
				local slot = #positions + 1
				order[idx] = slot
				lodIndex[slot] = idx
				local h = curOf[idx]
				local lx, lz = i * step * S - half, j * step * S - half
				positions[slot] = Vector3.new(lx, h - midY, lz)
				normals[slot] = lodNormal(field, chunk, src, step, nSide, i, j, h)
				uvs[slot] = Vector2.new((cxw + lx) / tile, (czw + lz) / tile)
				colors[slot] = packedColor(baseOf[idx], restOf[idx], h, tint)
				alphas[slot] = 1
			end
		end
		if j % 8 == 0 then
			budget()
		end
	end
	local surfaceCount = #positions

	-- face list: {vertex slots} + {attribute slots}
	local faceVerts: { { number } } = {}
	local faceAttr: { { number } } = {}
	for t = 1, #tris, 3 do
		local sa, sb, sc = order[tris[t]], order[tris[t + 1]], order[tris[t + 2]]
		table.insert(faceVerts, { sa, sb, sc })
		table.insert(faceAttr, { sa, sb, sc })
	end

	-- 4) skirts along the four chunk borders (double sided), hanging down to the ground
	local skirtSlot: { [number]: number } = {}
	local function skirtBottom(idx: number): number
		local existing = skirtSlot[idx]
		if existing then
			return existing
		end
		local pos = positions[order[idx]]
		local s = #positions + 1
		positions[s] = Vector3.new(pos.X, baseOf[idx] + 0.01 - midY, pos.Z)
		skirtSlot[idx] = s
		return s
	end
	local function skirtEdge(a: number, b: number)
		if not (used[a] and used[b]) then
			return
		end
		local ta, tb = order[a], order[b]
		local ba, bb = skirtBottom(a), skirtBottom(b)
		-- both windings so it hides cracks from either side
		table.insert(faceVerts, { ta, ba, tb })
		table.insert(faceAttr, { ta, ta, tb })
		table.insert(faceVerts, { tb, ba, bb })
		table.insert(faceAttr, { tb, ta, tb })
		table.insert(faceVerts, { ta, tb, ba })
		table.insert(faceAttr, { ta, tb, ta })
		table.insert(faceVerts, { tb, bb, ba })
		table.insert(faceAttr, { tb, tb, ta })
	end
	local last = nSide - 1
	for k = 0, nSide - 2 do
		skirtEdge(k, k + 1) -- j = 0
		skirtEdge(last * nSide + k, last * nSide + k + 1) -- j = last
		skirtEdge(k * nSide, (k + 1) * nSide) -- i = 0
		skirtEdge(k * nSide + last, (k + 1) * nSide + last) -- i = last
	end

	-- 5) bounding box pins (sub-pixel triangles in two opposite corners)
	local function pin(x: number, y: number, z: number, dx: number)
		local s = #positions
		positions[s + 1] = Vector3.new(x, y, z)
		positions[s + 2] = Vector3.new(x + dx, y, z)
		positions[s + 3] = Vector3.new(x, y, z + dx)
		table.insert(faceVerts, { s + 1, s + 3, s + 2 })
		table.insert(faceAttr, { 1, 1, 1 })
	end
	pin(-half, -halfY, -half, 0.01)
	pin(half, halfY, half, -0.01)

	-- 6) upload
	local okCreate, em = pcall(AssetService.CreateEditableMesh, AssetService)
	if not okCreate then
		-- e.g. "EditableMesh is not accessible. Go to the Security Tab ..." in published games
		-- where the owner has not enabled the Mesh / Image APIs
		return nil, "disabled"
	end
	if em == nil then
		return nil, "budget"
	end
	local editable = em :: EditableMesh

	local useBatch = hasBatch(editable)
	local vids: { number }, nids: { number }, uvids: { number }, cids: { number } = {}, {}, {}, {}
	local okBuild, buildErr = pcall(function()
		if useBatch then
			vids = editable:BatchAdd(Enum.MeshAttribute.Vertex, positions) :: any
			nids = editable:BatchAdd(Enum.MeshAttribute.Normal, normals) :: any
			uvids = editable:BatchAdd(Enum.MeshAttribute.UV, uvs) :: any
			cids = (editable :: any):BatchAdd(Enum.MeshAttribute.Color, colors, alphas)
			local fv = table.create(#faceVerts)
			local fn = table.create(#faceVerts)
			local fu = table.create(#faceVerts)
			local fc = table.create(#faceVerts)
			for f, v in faceVerts do
				local a = faceAttr[f]
				fv[f] = { vids[v[1]], vids[v[2]], vids[v[3]] }
				fn[f] = { nids[a[1]], nids[a[2]], nids[a[3]] }
				fu[f] = { uvids[a[1]], uvids[a[2]], uvids[a[3]] }
				fc[f] = { cids[a[1]], cids[a[2]], cids[a[3]] }
			end
			local fids = editable:BatchAdd(Enum.MeshAttribute.Face, fv)
			editable:BatchSetFaceAttributes(fids, fn)
			editable:BatchSetFaceAttributes(fids, fu)
			editable:BatchSetFaceAttributes(fids, fc)
		else
			for s, pos in positions do
				vids[s] = editable:AddVertex(pos)
				if s % 512 == 0 then
					budget()
				end
			end
			for s = 1, surfaceCount do
				nids[s] = editable:AddNormal(normals[s])
				uvids[s] = editable:AddUV(uvs[s])
				cids[s] = editable:AddColor(colors[s], 1)
				if s % 256 == 0 then
					budget()
				end
			end
			for f, v in faceVerts do
				local a = faceAttr[f]
				local fid = editable:AddTriangle(vids[v[1]], vids[v[2]], vids[v[3]])
				editable:SetFaceNormals(fid, { nids[a[1]], nids[a[2]], nids[a[3]] })
				editable:SetFaceUVs(fid, { uvids[a[1]], uvids[a[2]], uvids[a[3]] })
				editable:SetFaceColors(fid, { cids[a[1]], cids[a[2]], cids[a[3]] })
				if f % 256 == 0 then
					budget()
				end
			end
		end
		-- drop the default attributes the engine created while adding faces
		editable:RemoveUnused()
	end)
	if not okBuild then
		editable:Destroy()
		warn("[DeformableSnow] mesh build failed:", buildErr)
		return nil, "error"
	end

	local okPart, part = pcall(function()
		return AssetService:CreateMeshPartAsync(Content.fromObject(editable), {
			CollisionFidelity = Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Precise,
		})
	end)
	if not okPart or part == nil then
		editable:Destroy()
		warn("[DeformableSnow] CreateMeshPartAsync failed:", part)
		return nil, "error"
	end
	local mp = part :: MeshPart
	mp.Name = `SnowChunk_{chunk.cx}_{chunk.cz}`
	mp.Anchored = true
	mp.CanCollide = false
	mp.CanTouch = false
	mp.CanQuery = false
	mp.CastShadow = style.castShadow
	mp.Material = style.material
	if style.materialVariant ~= "" then
		mp.MaterialVariant = style.materialVariant
	end
	mp.Color = style.color
	-- render the mesh 1:1 (its bounds are pinned, so this never changes afterwards)
	local okSize, meshSize = pcall(function()
		return mp.MeshSize
	end)
	if okSize and typeof(meshSize) == "Vector3" and meshSize.X > 0 and meshSize.Y > 0 and meshSize.Z > 0 then
		mp.Size = meshSize
	end
	mp.CFrame = CFrame.new(cxw, midY, czw)

	local self = setmetatable({
		step = step,
		nSide = nSide,
		em = editable,
		part = mp,
		order = order,
		vids = vids,
		nids = nids,
		cids = cids,
		lodIndex = lodIndex,
		gridVersion = gridVersion,
		version = version,
		half = half,
		midY = midY,
		usesFull = chunk.full ~= nil,
		batch = useBatch,
		destroyed = false,
	}, ChunkMesh)
	mp.Parent = style.parent
	return self, nil
end

function ChunkMesh.destroy(self: ChunkMesh)
	if self.destroyed then
		return
	end
	self.destroyed = true
	if self.part then
		self.part:Destroy()
		self.part = nil
	end
	self.em:Destroy()
end

--[[
	Re-uploads the vertices touched by the dirty columns of a simulated chunk.
	dirty: full-grid column index -> 1 (height changed) | 2 (only the normal needs refreshing)
	all:   refresh every vertex
]]
function ChunkMesh.applyDirty(
	self: ChunkMesh,
	field: SnowField.SnowField,
	chunk: SnowField.Chunk,
	dirty: { [number]: number }?,
	all: boolean?,
	tint: Color3
)
	if self.destroyed then
		return
	end
	local full = chunk.full
	if not full then
		return
	end
	local step, nSide = self.step, self.nSide
	local n = full.n
	local posSet: { [number]: boolean } = {}
	local normSet: { [number]: boolean } = {}

	if all then
		for slot, idx in self.lodIndex do
			posSet[idx] = true
			normSet[idx] = true
		end
	elseif dirty then
		for i, flag in dirty do
			local lx, lz = i % n, i // n
			if lx % step == 0 and lz % step == 0 then
				local li, lj = lx // step, lz // step
				local idx = lj * nSide + li
				normSet[idx] = true
				if flag == 1 then
					posSet[idx] = true
					if li > 0 then
						normSet[idx - 1] = true
					end
					if li < nSide - 1 then
						normSet[idx + 1] = true
					end
					if lj > 0 then
						normSet[idx - nSide] = true
					end
					if lj < nSide - 1 then
						normSet[idx + nSide] = true
					end
				end
			end
		end
	end

	local src: Source = {
		base = full.base,
		rest = full.rest,
		cur = full.cur,
		n = n,
		stride = step,
		minY = full.minY,
		maxY = full.maxY,
	}
	local S = field.params.cellSize
	local half, midY = self.half, self.midY
	local order = self.order

	local pv: { number }, pp: { Vector3 }, pc: { number }, pcol: { Color3 } = {}, {}, {}, {}
	for idx in posSet do
		local slot = order[idx]
		if slot then
			local li, lj = idx % nSide, idx // nSide
			local o = ((lj * step) * n + li * step) * 4
			local cur = readf32(full.cur, o)
			table.insert(pv, self.vids[slot])
			table.insert(pp, Vector3.new(li * step * S - half, cur - midY, lj * step * S - half))
			table.insert(pc, self.cids[slot])
			table.insert(pcol, packedColor(readf32(full.base, o), readf32(full.rest, o), cur, tint))
		end
	end
	local nv: { number }, nn: { Vector3 } = {}, {}
	for idx in normSet do
		local slot = order[idx]
		if slot then
			local li, lj = idx % nSide, idx // nSide
			local o = ((lj * step) * n + li * step) * 4
			table.insert(nv, self.nids[slot])
			table.insert(nn, lodNormal(field, chunk, src, step, nSide, li, lj, readf32(full.cur, o)))
		end
	end

	local em = self.em
	if self.batch then
		if #pv > 0 then
			em:BatchSetValues(pv, pp)
			em:BatchSetValues(pc, pcol)
		end
		if #nv > 0 then
			em:BatchSetValues(nv, nn)
		end
	else
		for k, vid in pv do
			em:SetPosition(vid, pp[k])
			em:SetColor(pc[k], pcol[k])
		end
		for k, nid in nv do
			em:SetNormal(nid, nn[k])
		end
	end
end

return ChunkMesh
