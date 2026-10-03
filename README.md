# ❄️ DeformableSnow (Roblox)

Real, deformable snow for Roblox Studio. Everything inside **`Workspace.SnowParts`** gets a layer of
soft snow on top. Anything that walks, rolls or drives through it presses it down.

**No ID verification needed.** By default the snow is drawn with ordinary Parts and WedgeParts,
so it works in every published game with no special settings. Footprints are a real, smooth
triangle surface (like a mesh), not pixels. (An `EditableMesh` renderer is optional, see
[Renderers](#renderers).)

- **Any part type.** Part, MeshPart, Union, Wedge, Cylinder, Ball, inside Models or Folders at any depth.
- **Collidable or not.**
  - *Collidable* parts: you stand on the part and sink into the snow layer.
  - *Non-collidable* parts: you wade through down to whatever is underneath.
  - If a non-collidable part has nothing solid under it, you get an invisible collider (only on your
    own device), so you can still walk on it.
- **Real footprints.** Each R6/R15 foot, leg or body part presses the snow down to its own shape.
  Lying down leaves a body print.
- **Raised rims** of pushed-aside snow around every print.
- **Packed-snow tint.** Pressed snow turns a slightly blue-grey, like real trampled snow.
- **Players and NPCs** (anything with a Humanoid), plus **unanchored parts**: balls, crates, dropped
  tools, vehicle wheels (wheels are exact cylinders, so you get proper ruts).
- **Snow puffs and sparkles** when a foot sinks into fresh snow. An optional crunch sound is in Config.
- **Deep-snow slowdown.** Fresh deep snow slows you down; walking in an existing trail doesn't. It
  works with sprint scripts that also change WalkSpeed.
- **Trails fill back in** slowly (configurable, or permanent).
- **Multiplayer.** Everyone sees everyone's prints. Players who join later still see the existing
  trails (the server keeps a short history).
- **Fast.** The world is split into chunks with 4 levels of detail and loaded in the background
  within a per-frame time budget. Flat untouched snow is merged into big boxes (an untouched
  25×25-stud chunk is one Part), footprints use as few triangles as their shape needs, and only
  the Parts that actually change are updated.

## Install (2 minutes)

1. Download [`build/DeformableSnow.rbxmx`](build/DeformableSnow.rbxmx).
2. In Studio, open the **Explorer**, right-click **ReplicatedStorage**, choose **Insert from File…**
   and pick the file. You now have `ReplicatedStorage > DeformableSnow`.
3. Put your snow parts in a Folder named **`SnowParts`** in Workspace (you already have it).
4. Press **Play** and walk around.

That's it: one folder, no other setup. It contains:

| Item | What it is |
| --- | --- |
| `ClientMain` | Script, **RunContext = Client**. Runs on every player's device. |
| `ServerMain` | Script, **RunContext = Server**. Shares footprints for late joiners. |
| `Config` | All the settings, documented. Edit this. |
| `SnowClient`, `SnowField`, `ChunkParts`, `ChunkMesh`, `Shapes`, `StampCodec`, `SnowServer` | The system. |

> **Publishing:** nothing to do. The default `Parts` renderer uses only normal Parts, so it works
> in published games without ID verification or any experience setting.

Using Rojo instead? `default.project.json` maps `src/DeformableSnow` to
`ReplicatedStorage.DeformableSnow` (with `emitLegacyScripts: false`, so the `.client`/`.server`
files become RunContext scripts).

## Renderers

| `Config.Renderer` | Looks | Needs |
| --- | --- | --- |
| `"Parts"` (default) | Untouched snow is big flat boxes; footprints, trails, rims and slopes are a smooth triangle surface built from WedgeParts (flat-shaded, like a low-poly mesh). Snow edges are clean, straight slabs. | Nothing. Works everywhere. |
| `"EditableMesh"` | Smooth mesh surface with smooth slopes. | In published games, an owner who is 13+ and ID-verified, with **"Enable Mesh / Image APIs"** turned on in the Creator Dashboard. If it's blocked, the system switches to `"Parts"` by itself and prints one warning. |

## Settings (`Config`)

| Setting | Default | What it does |
| --- | --- | --- |
| `SnowFolderName` | `"SnowParts"` | Folder in Workspace that holds the snow parts |
| `Renderer` | `"Parts"` | `"Parts"` or `"EditableMesh"` (see [Renderers](#renderers)) |
| `PartsSmoothness` | `0.03` | Parts renderer: how closely the triangles follow the snow, in studs (smaller = smoother, more Parts) |
| `MaxSnowParts` | `12000` | Parts renderer: above this many snow Parts, far snow gets less detail (snow within 16 studs of the camera is never reduced) |
| `SnowDepth` | `1.0` | Studs of snow on top of each part |
| `CellSize` | `0.4` | Grid spacing. Smaller means sharper prints but more Parts/memory. `0.25`–`1` |
| `EdgeFalloff` | `1.5` | EditableMesh renderer: snow thins out over this distance at the edges (Parts: straight edges) |
| `MaxSlopeAngle` | `60` | Steeper surfaces hold no snow |
| `CliffHeight` | `3` | Bigger height jumps are treated as edges (snow doesn't drape off roofs) |
| `SnowColor` / `PackedSnowTint` | white / blue-grey | Fresh colour, and the tint where snow is pressed |
| `Material` / `MaterialVariant` | `Snow` / `""` | Look of the snow surface |
| `RimRatio` / `RimWidth` | `0.22` / `0.6` | Size of the pushed-up lip around prints |
| `RegrowDelay` / `RegrowSpeed` | `20` s / `0.015` studs/s | When and how fast trails fill in (`RegrowSpeed = 0` means permanent) |
| `WalkOnNonCollidableSnow` | `"Auto"` | `"Auto"`: add a collider only if nothing is under the part. `true`: always. `false`: never |
| `DeformByCharacters` | `true` | Players and NPCs make prints |
| `DeformByUnanchoredParts` | `true` | Loose parts make prints (up to `MaxDeformerSize` studs) |
| `SlowdownInDeepSnow` / `SlowdownStrength` | `true` / `0.3` | Up to 30% slower in fresh deep snow |
| `FootstepParticles` | `true` | Snow puffs |
| `FootstepSoundId` | `""` | e.g. `"rbxassetid://…"` for a crunch sound |
| `LodDistances` | `{32, 64, 128}` | Full / half / quarter detail ranges (eighth detail beyond) |
| `MaxRenderDistance` | `512` | Snow farther away than this isn't drawn |
| `SimulationDistance` | `300` | Prints are simulated within this range of the camera |
| `FrameBudgetMs` | `3` | Background loading time per frame |
| `SyncFootprints` / `MaxHistory` | `true` / `6000` | Share prints through the server |
| `Debug` | `false` | Print stats to the Output every 5 s |

### Per-part control (Properties window)

- **Attribute `SnowDepth`** (number) on a snow part overrides the depth for that part. `0` means no
  snow on it.
- **Tag `SnowDeformer`** on any part or model: it always makes prints, even when anchored (a plow, a
  scripted sled, etc.).
- **Tag `SnowIgnore`** on any part or model: it never makes prints. Inside `SnowParts`, it gets no
  snow.

## How it works

1. **Reading the surfaces.** The client raycasts straight down onto the snow parts on a world grid
   (`CellSize`). That finds the top surface of any part type, including meshes and unions.
   Non-collidable parts are made queryable locally so the rays can see them.
2. **Building the snow layer.** For every column the system stores the ground height, the rest
   height of the snow, the current height and the last time something pressed on it. Snow thins
   near edges (distance transform), on steep slopes and at tall cliffs. Adjacent parts merge into
   one seamless blanket.
3. **Pressing.** Every frame, each foot, limb, ball, wheel or crate is treated as an exact shape (box,
   sphere or cylinder). For every snow column under it, the system finds the shape's lowest point on
   that vertical line and pushes the snow down to there (never below the ground). A rim is pushed up
   around the print.
4. **Drawing.** Each 16×16-stud chunk is drawn by one of two renderers:
   - **Parts** (default): each chunk is split into 16×16-cell tiles.
     - A tile of level, untouched snow is drawn with boxes, merged as much as possible (a whole
       untouched chunk is one Part).
     - Any other tile (footprints, trails, rims, slopes) is triangulated with a right-triangulated
       irregular network (RTIN, the "Martini" algorithm): big triangles where the snow is flat,
       small ones only where the shape needs them, never more than `PartsSmoothness` studs off.
       Every triangle is drawn with two WedgeParts whose top faces sit exactly on it; their
       thickness hangs below the surface and hides hairline cracks between tiles.
     - A tile is rebuilt only when one of its samples visibly changes (cached per sample),
       triangles and boxes that did not change are never written to, moved Parts go through
       `Workspace:BulkMoveTo`, and Parts are pooled and reused.
     - Chunks at every detail level cover exactly their own area, and box sides are nudged off
       part edges, so nothing z-fights.
   - **EditableMesh**: one mesh per chunk shown through `AssetService:CreateMeshPartAsync`. Normals
     come from the heightfield (seamless shading), thin "skirts" hide cracks between detail levels,
     and two sub-pixel triangles pin each mesh's bounding box so it never shifts while it deforms.
5. **Networking.** Each client simulates the snow itself, from the characters it can see. Your own
   prints are also sent to the server in compact buffers. The server validates them: it rate-limits
   them and checks they're near your character. It keeps a rolling history and relays it, so late
   joiners and far-away players see the same trails.

## Good to know

- Snow lies on the **topmost** snow surface at each spot, so there's no snow under a snow-covered
  roof. That's also what real snow does.
- The invisible collider for floating non-collidable parts exists only on players' devices. NPCs
  simulated on the server still fall through those parts.
- Snow parts are meant to be mostly static. Moving or resizing one works, but the snow around it is
  re-read.
- MeshPart wheels are treated as boxes. Use Part cylinders for perfect ruts.
- Parts renderer: triangles are flat-shaded (like a low-poly mesh), and the snow ends in a clean
  vertical edge at the sides of your parts instead of thinning out. A footprint costs about 90
  WedgeParts at full detail (far fewer farther away); a player walking around keeps roughly
  4,000–5,000 snow Parts alive. Raise `CellSize` or `PartsSmoothness` for fewer Parts.
- Parts renderer: Roblox maps the Snow material per Part with a random offset, so you may see
  faint texture seams between triangles. `Material = Enum.Material.SmoothPlastic` is perfectly
  seamless.
- EditableMesh renderer: on low-memory devices Roblox may refuse more editable meshes. The affected
  chunks are then drawn with Parts instead, and a warning is printed once.

## Development

- `tools/test.sh` runs the offline test suite with the [`luau`](https://github.com/luau-lang/luau)
  CLI: 210 checks across 10 suites.
  - Unit tests for the geometry, heightfield and network codec.
  - End-to-end runs of the real client and server code against a small Roblox engine mock
    (`tests/rbxmock.luau`), for both renderers. That includes a game where EditableMesh is blocked
    (automatic switch to Parts), running out of EditableMesh memory, the Parts budget, and the
    Parts geometry: the two-wedge triangle construction, surfaces that follow slopes, curves
    and footprints within the smoothness tolerance with no holes, flat snow as single Parts,
    and no updates for invisible changes. The mock's `EditableMesh` rejects invalid or mixed-up
    ids like the real one.

  ```sh
  LUAU=/path/to/luau tools/test.sh
  ```

- Type-check against the Roblox API with [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp):

  ```sh
  luau-lsp analyze --sourcemap=tools/sourcemap.json --definitions=globalTypes.d.luau --platform=roblox src/DeformableSnow
  ```

- Rebuild the Studio model after editing `src/`: `python3 tools/build_rbxmx.py`.
