# Jedi Academy → Godot 4: Porting Plan

## 1. What is in this repository

| Area | Path | Size | Notes |
|---|---|---|---|
| Single-player game logic | `code/game` | ~191k lines | Entities, NPC AI (`AI_*.cpp`, `NPC_*.cpp`), saber (`wp_saber.cpp`, 13.7k), movement (`bg_pmove.cpp`, 15k), animation (`bg_panimate.cpp`), ICARUS bindings (`Q3_Interface.cpp`, 11k) |
| SP client game / HUD | `code/cgame` | ~51k | Prediction, HUD, weapon effects (`FX_*.cpp`) |
| Renderer | `code/renderer` | ~57k | Fixed-function OpenGL 1.x, RBSP loader (`tr_bsp.cpp`), shader scripts (`tr_shader.cpp`) |
| Ghoul2 skeletal animation | `code/ghoul2` | ~10k | `.glm` meshes / `.gla` skeletons, bolts, dismemberment |
| ICARUS scripting VM | `code/icarus` | ~8k | Runs the compiled `.IBI` scripts that drive cutscenes and level logic |
| Effects system | `code/client/Fx*.cpp` | | Parses and runs `.efx` particle files |
| Engine core | `code/qcommon`, `code/client`, `code/server` | ~64k | Filesystem (pk3), collision model, network, console/cvars |
| UI | `code/ui` + `base/ui/*.menu` | ~25k | Script-driven menus |
| Multiplayer | `codemp/` | separate tree | MP game, bots (`botlib`), siege, vehicles |
| Data | `base/ext_data` | | Plain-text `.npc`, `.sab`, `.veh`, `.wpn`, `weapons.dat`, `items.dat` |

**There are no game assets in this repo.** Maps, models, textures, sounds and
scripts live in the retail `GameData/base/assets0–3.pk3` (ordinary zip files).
The port has to read them from a copy the player owns.

Formats the port has to handle (confirmed from the headers):

- **Maps**: Raven BSP, `RBSP` v1 (`qcommon/qfiles.h:199`). This is *not* Quake 3's
  `IBSP` v46: it has 4 lightmaps and light styles per surface, so stock Q3 importers
  won't load it as-is.
- **Characters**: Ghoul2 `MDXM`/`MDXA` (`renderer/mdx_format.h`). Most humanoids
  share one skeleton/animation file, `_humanoid.gla`, with sequences named in `animation.cfg`.
- **Props/weapons**: MD3 (`IDP3`).
- **Materials**: `.shader` text scripts (multi-stage blend, tcMod, rgbGen, deforms).
- **Effects**: `.efx` text files. **Scripts**: ICARUS `.IBI` bytecode. **Camera paths**: `.rof`.
- **Simulation rate**: the server runs at 20 Hz (`sv_fps 20`, `server/sv_init.cpp:647`).
  Player movement runs per input command, with client-side prediction.

## 2. The three options

### A. Modernise the existing engine (cheapest, but not Godot)
The community fork **OpenJK** (github.com/JACoders/OpenJK) is built from this exact
source. It already has 64-bit builds, SDL2, bug fixes and the optional
**rend2** renderer (normal/specular maps, HDR, better lighting). If the goal
is "same game, nicer graphics, then mod it", this gets you there in weeks.
The downside: you still work in a 2003 C engine.

### B. Embed the old engine inside Godot
Wrap `code/game` as a GDExtension and let Godot only render. **Not recommended.**
The game code depends on engine `trap_*` calls, the BSP collision model
(`CM_*`), the entity/snapshot system and Ghoul2 internals. You would carry every
legacy limitation and also fight two engines.

### C. Data-driven remake in Godot 4 (recommended for your goals)
Godot owns rendering, physics, audio, UI and tools. The original C++ serves as the
**specification**: gameplay systems are re-implemented, and the code that
defines how the game *feels* (pmove, saber, force powers) is translated
closely. Original assets are converted from the player's own pk3 files,
then improved or replaced over time.

Neither "use only community importers" nor "re-create everything from scratch" is the
right answer by itself. Importers cover part of the asset work. Gameplay always has
to be rebuilt, and that is the bulk of the project.

## 3. Recommended architecture (option C)

```
godot_project/
  addons/ja_import/      # editor import plugins (pk3 → Godot resources)
  gdextension/           # C++: pmove, saber, force, ICARUS VM, BSP/Ghoul2 readers
  game/
    player/  npc/  saber/  force/  weapons/  vehicles/
    world/   # triggers, movers, func_* entities spawned from the BSP entity lump
    script/  # ICARUS bridge (Q3_Interface equivalent)
  ui/        # menus rebuilt with Control nodes
tools/convert/           # offline Python/C++ converters (batch, CI-friendly)
```

- **Language split**: use C++ GDExtension for code translated from the original
  (lets you port `bg_pmove.cpp` and `wp_saber.cpp` almost function by function
  and compare behaviour). Use GDScript for glue, UI and level logic.
- **Tick model**: run gameplay in `_physics_process` at a fixed rate (start at
  40–60 Hz, keep the pmove maths frame-rate independent like the original `pml.frametime`).
- **Collision**: create one `ConvexPolygonShape3D` per BSP brush, built from the
  brush planes. That reproduces Q3 collision exactly. Use a custom kinematic
  controller (shape-casts as `trace()`), not `CharacterBody3D` defaults, so strafe-jumping,
  wall-runs and force jumps feel like the original.
- **Legal**: translated code is a derivative of GPLv2, so the project is GPLv2
  (Godot's MIT licence is compatible). Assets belong to Disney/Lucasfilm and Activision:
  **never ship them**. Require the user's retail install and convert it on first launch
  (the OpenMW / ioquake3 model). New content you make yourself can ship.

## 4. Asset pipeline

| Asset | Route | Effort |
|---|---|---|
| pk3 | They are zip files, so extract with any zip library | trivial |
| Textures (tga/jpg/png) | Godot imports them directly. Later: AI upscale plus generated normal/roughness maps | low |
| Sounds (wav/mp3) | Direct import. Port `sound/*.txt` alias sets to `AudioStreamRandomizer` | low |
| `.npc` `.sab` `.veh` `.wpn` | Write a small parser for the brace format → Godot `Resource`s | low |
| MD3 | Write a small converter → glTF (or use an existing Blender MD3 addon) | low |
| **RBSP maps** | Option 1: `q3map2 -game ja -convert -format ase/obj` for geometry, plus your own entity-lump parser. Option 2 (better): write a converter that follows `tr_bsp.cpp`: faces, patches (bezier tessellation), brushes → collision, entities → scenes, lightmaps → baked into a second UV channel (or rebake with Godot LightmapGI / SDFGI) | **medium–high** |
| **Ghoul2 `.glm/.gla`** | Use a Blender Ghoul2 addon (a community import/export plugin exists) → glTF with `Skeleton3D`. Or write a converter using `mdx_format.h` + `G2_bones.cpp` (bone compression) as reference. Split `_humanoid.gla` into an `AnimationLibrary` using `animation.cfg` | **high** |
| Skins (`.skin`) and model surfaces | Map to material overrides; turn surface on/off flags into mesh visibility (dismemberment caps) | medium |
| `.shader` scripts | Write a translator to Godot `ShaderMaterial` code for the common keywords. Hand-author PBR replacements for important materials | medium |
| `.efx` effects | Port `FxParsing.cpp` → `GPUParticles3D` / custom primitives (lines, cylinders, trails) | medium |
| ICARUS `.IBI` | Port the VM in `code/icarus` (~8k lines) into the GDExtension, then rewrite the `Q3_Interface.cpp` command set against Godot nodes. Without this, the SP campaign's cutscenes and objectives don't work | **high** |
| `.menu` UI | Rebuild by hand in Godot. Parsing the old menus isn't worth it | medium |
| `.rof` camera/mover paths | Small binary format → `Animation` tracks | low |

## 5. Gameplay porting order

1. **Player movement**: `bg_pmove.cpp`, `bg_slidemove.cpp`. Ground/air/water
   movement, jumping, crouch, ladders. Get the feel identical before anything else.
2. **Animation state**: `bg_panimate.cpp` (legs/torso split, which maps to an
   `AnimationTree` with two blend layers).
3. **Saber combat**: `wp_saber.cpp`, `wp_saberLoad.cpp`, `bg_saber` parts. Stances,
   attack chains/move table, blocking/parry, saber locks, blade traces, dual/staff.
   This is the heart of JA. Replace the old fixed-trace hit detection with continuous
   swept capsules for smoother, more reliable hits.
4. **Force powers**: push/pull/jump/speed/grip/lightning/heal/mind trick/drain/
   protect/absorb/sight/rage/saber-throw (scattered across `wp_saber.cpp`, `g_active.cpp`).
5. **Ranged weapons** (`g_weapon.cpp`, `FX_*.cpp`) and items.
6. **NPC framework**: `NPC*.cpp` senses/combat/goals plus the `AI_*.cpp` behaviours.
   Use Godot `NavigationRegion3D` instead of the old waypoint nav (`g_nav*.cpp`).
   Start with Stormtrooper and Jedi (`AI_Jedi.cpp` is the most complex).
7. **World entities**: triggers, movers, doors, breakables, turrets, `target_*`.
8. **ICARUS bridge** → the campaign becomes playable mission by mission.
9. Vehicles, then multiplayer (Godot high-level multiplayer; take `codemp` rules
   for FFA/Duel/Siege; skip `botlib` and write new bots on top of the NPC AI).

## 6. Milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | Tooling | Reads pk3 files from a retail install, lists and extracts assets |
| M1 | Map viewer | One map (e.g. an MP duel map) rendered with collision and lightmaps, free-fly camera |
| M2 | Walkable | Ported pmove plus third-person camera on that map. Movement feels like the original |
| M3 | Character | Ghoul2 player model animated by the ported anim state machine |
| M4 | **Vertical slice** | Saber stances plus 3–4 force powers versus one Jedi NPC in one map. **Decide here whether the project is viable** |
| M5 | Content breadth | All weapons, NPC classes, entities. Map converter handles every level |
| M6 | Campaign | ICARUS running, SP missions playable start to finish |
| M7 | Upgrade | PBR materials, new lighting, effects overhaul, new gameplay, new content |
| M8 | Multiplayer | Duel/FFA, then Siege |

Expect M4 to take months for one person. A full, faithful port is a multi-year
hobby project. Keep scope tight until M4 works.

## 7. Practical hints

- Keep the original running (OpenJK build) next to the Godot version. Compare
  movement and saber behaviour side by side, and log values like velocity and anim
  frames from both.
- Port gameplay code faithfully first and improve it second. If you change both at
  once you can't tell which change broke the feel.
- Quake units: 1 unit ≈ 2.54 cm (1 inch). Q3 is Z-up, Godot is Y-up. Convert in one
  place, in the importers.
- Make converters deterministic batch tools so the whole game can be regenerated
  when an importer improves.
- Community Godot addons for Quake (`.map` via TrenchBroom/func_godot, Q1/Q2 BSP
  importers) are useful references, but they don't read Raven's RBSP or Ghoul2.
  Plan to write or extend those two yourself.
- New levels: author them in TrenchBroom or Blender for Godot directly. You don't need
  to keep making BSPs.
