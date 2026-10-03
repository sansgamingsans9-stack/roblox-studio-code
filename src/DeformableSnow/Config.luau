--!strict
--[[
	DeformableSnow - settings
	Edit anything here. Everything inside Workspace.<SnowFolderName> (Parts, MeshParts, Unions,
	Wedges... collidable or not, nested in Models/Folders or not) gets a layer of soft snow on top
	that anything walking/rolling/driving through it presses down.

	Per-part overrides (set as Attributes on the part in the Properties window):
	  SnowDepth  (number)  snow thickness on that part; 0 = no snow on it
	Tags (CollectionService / Properties > Tags):
	  SnowDeformer  on any part/model: always makes prints (even anchored, e.g. a moving plow)
	  SnowIgnore    on any part/model: never makes prints; inside the snow folder: gets no snow
]]

local Config = {
	-- Folder in Workspace that holds the snow parts.
	SnowFolderName = "SnowParts",

	------------------------------------------------------------------ renderer
	-- "Parts": works in every game, no ID verification or special setting needed. Untouched snow
	--          is drawn with big boxes; footprints and trails become a smooth triangle surface
	--          made of WedgeParts, so they look like a mesh.
	-- "EditableMesh": real mesh. Needs "Enable Mesh / Image APIs" in published games (owner must
	--          be 13+ and ID verified). Falls back to "Parts" automatically when blocked.
	Renderer = "Parts",
	-- Parts renderer: how closely the triangles follow the snow, in studs. Smaller = smoother
	-- prints but more Parts. 0.02 .. 0.1
	PartsSmoothness = 0.03,
	-- Parts renderer: above this many snow Parts, far snow is drawn with less detail.
	MaxSnowParts = 12000,

	------------------------------------------------------------------ look
	-- Studs of soft snow laid on top of each snow part. Characters standing on a collidable part
	-- sink into this layer; on non-collidable parts they wade through to whatever is below.
	SnowDepth = 1.0,
	-- Grid spacing in studs. Smaller = sharper footprints but more Parts/memory. (0.25 .. 1)
	CellSize = 0.4,
	-- EditableMesh renderer: snow thins out over this many studs at the edges of the snow area.
	-- (The Parts renderer always draws clean, straight edges.)
	EdgeFalloff = 1.5,
	-- Surfaces steeper than this (degrees) do not hold snow.
	MaxSlopeAngle = 60,
	-- Height jumps bigger than this between neighbouring spots are treated as an edge
	-- (so snow on a roof does not drape down to the ground).
	CliffHeight = 3,
	-- Pressed snow never gets thinner than this (stops it flickering with the part below).
	MinThickness = 0.06,
	SnowColor = Color3.fromRGB(242, 246, 252),
	-- Multiplied in where the snow is packed down (slightly blue/grey, like real footprints).
	PackedSnowTint = Color3.fromRGB(196, 210, 232),
	Material = Enum.Material.Snow,
	-- Optional MaterialVariant name (from MaterialService) for a custom snow texture.
	MaterialVariant = "",
	-- EditableMesh renderer only: size of one texture repeat.
	TextureStudsPerTile = 8,
	CastShadow = true,

	-- Non-collidable snow parts: players wade through them down to whatever is underneath.
	-- If there is NOTHING solid underneath, you would fall through, so:
	--   "Auto" = add an invisible local collider only for parts with nothing solid below them
	--   true   = always make non-collidable snow parts walkable
	--   false  = never (leave collisions exactly as you set them)
	WalkOnNonCollidableSnow = "Auto" :: boolean | string,

	------------------------------------------------------------------ deformation
	-- Snow pushed up around prints, as a fraction of how deep the print is.
	RimRatio = 0.22,
	-- How far (studs) from the print that lip reaches.
	RimWidth = 0.6,
	-- Seconds a print stays untouched before it starts to fill back in.
	RegrowDelay = 20,
	-- Studs per second that prints fill back in. 0 = prints stay forever.
	RegrowSpeed = 0.015,

	------------------------------------------------------------------ what makes prints
	-- Players and NPCs (anything with a Humanoid).
	DeformByCharacters = true,
	-- Unanchored parts touching the snow: balls, crates, vehicle wheels, dropped tools...
	DeformByUnanchoredParts = true,
	-- Unanchored parts bigger than this (studs, largest side) are ignored.
	MaxDeformerSize = 24,
	DeformerTag = "SnowDeformer",
	IgnoreTag = "SnowIgnore",

	------------------------------------------------------------------ gameplay & feel
	-- Wading through deep, fresh snow slows the local player down (walking in an existing trail
	-- does not). Works together with other scripts that change WalkSpeed (sprint etc.).
	SlowdownInDeepSnow = true,
	SlowdownStrength = 0.3, -- 0.3 = up to 30% slower
	-- Little puffs of snow when a foot sinks into fresh snow.
	FootstepParticles = true,
	-- Optional crunch sound, e.g. "rbxassetid://1234567890". Empty = off.
	FootstepSoundId = "",
	FootstepSoundVolume = 0.35,

	------------------------------------------------------------------ performance
	-- Columns per chunk side: 16, 32 or 64.
	ChunkCells = 64,
	-- Level of detail: full detail closer than [1], 1/2 closer than [2], 1/4 closer than [3],
	-- 1/8 beyond that. (Footprints far away need far fewer Parts at lower detail.)
	LodDistances = { 32, 64, 128 },
	-- Snow farther than this from the camera is not drawn (the plain parts show instead).
	MaxRenderDistance = 512,
	-- Prints are only simulated within this distance of the camera.
	SimulationDistance = 300,
	-- Milliseconds per frame the background loader (sampling + meshing) may use.
	FrameBudgetMs = 3,

	------------------------------------------------------------------ multiplayer
	-- Share prints through the server so players who join later (or are far away) still see the
	-- trails. Needs the server script (ServerMain) to be running.
	SyncFootprints = true,
	-- Maximum number of prints the server remembers for late joiners.
	MaxHistory = 6000,

	-- Prints chunk/mesh statistics to the output every few seconds.
	Debug = false,
}

return Config
