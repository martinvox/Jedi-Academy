# Port status / handoff log

Keep this file current. Anyone (human or Claude, locally or in the cloud) can
continue from here. Branch: `claude/exciting-mendel-ieutjw`.

## Done

- [x] M0 Tooling: `JAVfs` mounts `base` + an optional mod dir, with pk3 order matching `FS_AddGameDirectory`
- [x] RBSP v1 parser (all lumps the map builder needs; nodes, leafs, vis and the light grid are not parsed yet)
- [x] Shader scripts: cull, blendFunc, alphaFunc, map/clampMap/animMap (first frame), tcMod scroll, surfaceparm, skyparms
- [x] Map builder: per-material meshes, lightmap atlas (UV2), vertex-lit surfaces, Bezier patches,
      convex brush collision split by contents (solid / player clip / monster clip / shot clip / ladder),
      water/lava/slime and trigger `Area3D`s, patch collision, brush entities as their own nodes (movers are `AnimatableBody3D`)
- [x] Skybox (`skyparms env/x`), using the face mapping derived from `tr_sky.cpp` `MakeSkyVec`
- [x] Map viewer (setup panel, map list, free-fly camera, `--screenshot`, `--view`)
- [x] Tests: 50 headless checks on a synthetic map. Rendering checked with Xvfb + OpenGL.
- [x] **M2 movement (first pass)**: `JACollisionWorld` is an exact port of `CM_TraceThroughBrush`/`CM_TestBoxInBrush`, with
      patches as thin facet brushes. `JAPmove` ports walk/air/water/ladder movement, friction, acceleration,
      PM_SlideMove/PM_StepSlideMove (g_stepSlideFix 1), the ground trace, ducking, the normal jump and landing timers.
      `JAPlayer` adds input, a fixed tick with interpolation, and 1st/3rd-person cameras. Covered by 22 movement/collision tests.
- [x] **Map entities**: `JAGameWorld` ports func_door (teams, auto trigger, wait/toggle/locked/start_open/delay, reversing
      when blocked), func_plat, func_button, func_bobbing, func_rotating (visual), func_usable, trigger_multiple/once
      (wait, delay, USE_BUTTON, FACING), trigger_push (arc/linear/relative/conveyor), trigger_teleport, target_relay/
      delay/push/teleporter/print/activate/deactivate, plus movers carrying and pushing the player. E is use.
      Covered by 12 tests (84 total).
- [x] Verified on retail data by the user: t1_sour loads with 0 missing textures and `flipped_surfaces: 0`, and walking feels right.
- [x] Performance: a retail-sized synthetic map (50k surfaces, 10k brushes) parses and builds in about 2 s in GDScript

## Needs checking on real game data (cannot be done in the cloud session)

- [ ] Load several retail maps (`mp/ffa_bespin`, `t1_sour`, `yavin1`, `kor1`) and report:
      the stats line, the missing textures list, and screenshots of anything that looks wrong
- [ ] Triangle winding. The builder auto-corrects per surface, and `flipped_surfaces` in the stats shows how often that happened.
      Expected to be 0, because Godot and q3map2 both use clockwise front faces.
- [ ] Skybox orientation. The derivation is verified only on the synthetic test.
- [ ] Lightmap brightness (`JAMaterials.light_scale`; 1.0 matches `r_overBrightBits 0`)

## Next steps (in order)

1. Fix whatever real maps turn up (see above).
2. Shader improvements: multi-stage blending (lightmap + detail + glow), `rgbGen`/`alphaGen` waves,
   `tcMod rotate/turb/stretch`, `deformVertexes wave/autosprite`, animMap animation, environment maps.
3. **M2 movement, remaining**: force jump (hold jump, `forceJumpHeight`/`forceJumpStrength`), flips, wall runs,
   rolls, water jump, falling damage. Still missing on the entity side: func_train/path_corner, rotating collision,
   func_breakable, ICARUS scripts (`usescript`/`spawnscript`), and sounds.
4. MD3 loader (`misc_model_static`, weapons, items) → `ArrayMesh`
5. **M3 Ghoul2**: `.glm`/`.gla` loader (`code/renderer/mdx_format.h`, `code/ghoul2/G2_bones.cpp` for bone
   decompression), `Skeleton3D`, and `animation.cfg` → `AnimationLibrary`
6. Movers: `func_door`/`func_plat`/`func_rotating`/`func_train` from `g_mover.cpp`
7. Possibly move the hot loops (BSP decode, patch tessellation) to a C++ GDExtension if load times grow.

## Session log

- 2026-10-05: Map entities: doors, lifts, buttons, triggers, teleporters, jump pads.
- 2026-10-05: M2 first pass: brush tracing + pmove port; the viewer now spawns a walkable player.
- 2026-10-04: Switched to Godot 4.7.1 (tests and rendering re-verified).
- 2026-10-04: Plan written. M0/M1 implemented and tested headless. Autosave script added.
  The container restarted once (OOM from a test generator, now fixed); no work was lost.
