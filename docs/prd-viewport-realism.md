# Build Spec: **Viewport realism** — make the 3D model read as a real object — for Codex

**Date:** 2026-06-30. **Repo:** this repository. **Audience:** Codex orchestrator +
sub-agents. Reuse `docs/prd-inflatables.md` **§0** (multi-agent orchestration +
context budget) and **§9** (Codex prompting rules) — restate them in every sub-agent
prompt. This spec is self-contained for the rendering work.

## Goal & target look
The imported-model viewport currently reads as flat, shadeless **CG clay**. Make it
look like a **real object under good studio light** — the neutral, form-revealing look
a sculptor uses to judge a piece (matte plaster/clay under soft directional + ambient
light), NOT a simulation of a specific finish (stone/metal/etc — that's a later,
per-material option). The win is overwhelmingly about **lighting and material**, not
geometry.

**Hard constraints (do not regress):**
- **RealityKit only** — SceneKit is permanently off the table (owner decision). Mitigate
  any render-loop cost inside RealityKit.
- Keep the geometry cache (`ViewportGeometryCache`) and the in-place highlight/selection
  retint path working — do not trigger full scene rebuilds per frame.
- **Slices/panels keep flat shading** (they ARE flat); this work targets the imported
  **model** entity (and the inflatable membrane preview), not slice solids.
- No cloud/runtime asset downloads (owner killed cloud deps) — bundle any HDRI in the
  SwiftPM resources.

## Current setup (read these; all in `app/RefabArtist/Sources/RefabArtist/`)
- `ModelSceneView.swift`:
  - RealityView setup **L186–219**: `content.environment = .default` (flat neutral
    ambient — the core problem), DoF/motionBlur/cameraGrain disabled, `.virtual` camera.
  - `configureLights` **L2815–2836**: three `DirectionalLight`s — key (intensity 3600),
    fill (420), rim (1100, cool). A decent 3-point rig, but directional-only.
  - `makeModelEntity` **L720–761**: builds the model `ModelEntity` from
    `ViewportMeshRenderData.smoothShadedMesh`, sets `modelMaterial`, adds
    `GroundingShadowComponent`, and draws the **feature-edge overlay** (L749–758) — the
    dark crease/boundary lines (see `featureEdges`, crease 18°, in `ViewportMeshRenderData.swift`).
  - `modelMaterial` **L2889–2902**: a single matte `PhysicallyBasedMaterial` (warm grey,
    roughness 0.6, metallic 0) — inert, nothing to reflect, no AO.
  - Camera FOV 42° (L2849).
  - Background: `WorkspaceDarkModePalette.viewportBackground` (L288–289).
- `ViewportMeshRenderData.swift`: `smoothShadedMesh` (welds + area-weighted normals),
  `featureEdges` (crease+boundary overlay), `shouldRenderFeatureEdges` (≤50k budget).
- `SurfaceDespeckle.swift`: `polished` (L36) — feature-preserving bilateral normal
  filter; reuse to de-facet healed meshes.
- `MeshModifier.swift`: `shrinkwrap` (L366) — Make Watertight; produces a faceted
  voxel-isosurface (root cause of the crease lines after healing).
- `app/RefabArtist/Package.swift` — add a `resources:` entry to bundle the HDRI.

## Why it looks CG (the three gaps)
1. **No image-based lighting.** `.default` is flat ambient; directional lights alone
   give even, shadeless shading. Real objects are lit by an environment.
2. **No ambient occlusion.** Crevices (between fingers, concavities) don't darken, so
   the form loses its depth cue.
3. **Inert material.** Uniform roughness, no specular/clearcoat, nothing to reflect.
Plus two realism-killers already filed elsewhere: the **black crease overlay** and the
**faceted healed surface**.

---

## Work units (apply PRD-inflatables §0/§9; one sub-agent per unit)

### WU-R1 — Image-based lighting from a studio HDRI (THE win; do first)
- **Goal:** Light the scene with a neutral studio **HDRI** so the model gets soft
  directional ambient + subtle reflections instead of flat fill.
- **Read-set:** `ModelSceneView.swift` L186–219 (RealityView/environment),
  L2815–2836 (lights), L720–761 (model entity); `Package.swift`.
- **Write-set:** add `Resources/studio_env.exr` (or `.hdr`) — a **neutral, soft studio
  HDRI** (royalty-free or generated; even, low-contrast, slightly warm key); register it
  in `Package.swift` (`resources: [.process("Resources")]`); `ModelSceneView.swift`.
- **Approach (verify exact API against the installed RealityKit SDK):**
  - Load once, cached: `let env = try await EnvironmentResource(named: "studio_env", in: .module)`.
  - **Preferred (keeps the custom 2D background):** create an IBL entity with
    `ImageBasedLightComponent(source: .single(env), intensityExponent: ~0.7)` and attach
    `ImageBasedLightReceiverComponent(imageBasedLight: iblEntity)` to the model (and
    membrane) entities. Then **dial the 3 directional lights down** to accents (key
    ~1200, fill ~150, rim ~500) so the IBL carries the base light.
  - **Alternative (simpler, replaces background with the env):**
    `content.environment = .skybox(env)` — gives IBL + skybox in one line; use only if
    the owner wants the environment visible as backdrop.
  - Load the EnvironmentResource ONCE and reuse (it's expensive); never per-frame.
- **Acceptance:** model shows a soft lit-to-shadow gradient + faint environment
  reflection; no per-frame hitch (IBL loaded once); selection/highlight still works;
  build green.

### WU-R2 — Material upgrade (now that there's an environment to reflect)
- **Goal:** Give the surface believable finish.
- **Read-set:** `ModelSceneView.swift` L2889–2902 (`modelMaterial`).
- **Write-set:** `ModelSceneView.swift`.
- **Approach:** keep `PhysicallyBasedMaterial`, metallic 0; set roughness ~0.5–0.55, add a
  faint **clearcoat** (`material.clearcoat = 0.12`, `clearcoatRoughness = 0.55`) and a
  touch of `specular` so the HDRI gives subtle sheen; keep the warm-grey plaster tint.
  Preserve the `ghosted` transparent path unchanged.
- **Acceptance:** material reads as matte plaster with a hint of life under the HDRI;
  ghosted "Both" mode unchanged.

### WU-R3 — Stop fighting realism: overlay + heal faceting (cheap, high impact)
- **Goal:** Remove the dark crease lines and the voxel faceting from the realistic view.
- **Read-set:** `ModelSceneView.swift` L749–758 (overlay); `ViewportMeshRenderData.swift`
  (`featureEdges`, `shouldRenderFeatureEdges`); `MeshModifier.swift` `shrinkwrap` L366–419;
  `SurfaceDespeckle.swift` L36.
- **Write-set:** `ModelSceneView.swift` and/or `MeshModifier.swift`.
- **Approach:** (a) **Suppress / soften the feature-edge overlay on the imported model**
  — either gate it behind a "show edges" toggle (default OFF for the realistic look) or
  raise the crease angle well above 18° so only genuine hard features draw; keep boundary
  edges only when the mesh is actually open. (b) Run a light `SurfaceDespeckle.polished`
  (or a couple of Taubin-smoothing iterations) on the **healed** mesh so the
  reconstruction itself isn't faceted (improves the geometry, not just hides lines).
  Both were flagged in `docs/handoff-inflatables-quality-and-ui.md`; this is the right
  place to land them.
- **Acceptance:** a healed organic mesh renders smooth with no scattered black lines;
  genuine sharp features (if any) can still be shown via the toggle; mesh stays watertight.

### WU-R4 — Anti-aliasing + tone/exposure polish
- **Goal:** Crisp silhouettes and balanced exposure under the new HDRI.
- **Read-set:** `ModelSceneView.swift` L186–199 (RealityView render options).
- **Write-set:** `ModelSceneView.swift`.
- **Approach:** confirm MSAA/AA is active for the RealityView (jagged edges read as CG);
  if the SDK exposes it, ensure it's on. Tune IBL `intensityExponent` / light intensities
  so the model isn't blown out or muddy. Keep DoF/motionBlur/grain disabled. Optionally a
  subtle viewport background gradient for grounding (minor).
- **Acceptance:** smooth silhouettes; balanced exposure (no clipped highlights / crushed
  shadows) on `handStand_ex4.obj`.

### WU-R5 — Ambient occlusion (OPTIONAL stretch; do last — real cost)
- **Goal:** Darken crevices for solid-object depth.
- **RealityKit caveat (state honestly):** RealityKit's high-level renderer has **no
  built-in SSAO**, and PBR `ambientOcclusion` is a **texture channel sampled by UV** — the
  imported scan has no UVs. So true AO requires either (a) **baking per-vertex AO**
  (hemisphere ray sampling or a cheap concavity/curvature approximation) and applying it
  via a `CustomMaterial`/`ShaderGraphMaterial` that multiplies baseColor by a vertex-color
  AO channel, or (b) baking an AO texture with a generated UV. Both are real work.
- **Read-set:** `ModelSceneView.swift` (material + mesh build), `ViewportMeshRenderData.swift`.
- **Write-set:** new `ViewportAmbientOcclusion.swift` + material wiring.
- **Approach:** compute per-vertex AO once (cache with the mesh in `ViewportGeometryCache`),
  bake into vertex colors, render via a CustomMaterial that modulates baseColor. Keep it
  off the per-frame path. If it proves heavy or janky, **ship R1–R4 without it** — IBL +
  material + de-facet already deliver most of the realism.
- **Acceptance:** finger-gaps/concavities visibly darken; no per-frame cost; toggleable.

---

## Build order
R1 (IBL) → R2 (material) → R3 (overlay+smoothing) → R4 (AA/exposure) → R5 (AO, optional).
R1+R2+R3 are the bulk of the win and are independent enough to parallelize after R1's
resource bundling lands. R5 is a separate, larger effort — gate it behind R1–R4 being
accepted by the owner (the owner is the judge: render and LOOK on
`app/RefabArtist/Tests/Fixtures/hand-scans/handStand_ex4.obj`).

## Verification (local only — no cloud CI)
```
swift build --package-path app/RefabArtist
swift test --package-path app/RefabArtist --scratch-path /tmp/refabartist-realism-test
bash tools/package_app.sh   # then relaunch build/Refab Artist.app and LOOK
```
Add a unit test that the EnvironmentResource bundles and loads (so a missing/renamed
asset fails CI-locally, not silently at runtime). The real gate is visual: the model
must read as a lit physical object, not flat CG clay — owner confirms in-app.

## References (RealityKit)
- Image-based lighting: `EnvironmentResource`, `ImageBasedLightComponent`,
  `ImageBasedLightReceiverComponent` (Apple RealityKit docs) — verify signatures against
  the installed SDK; APIs differ slightly across macOS releases.
- Material: `PhysicallyBasedMaterial` (`roughness`, `metallic`, `clearcoat`,
  `clearcoatRoughness`, `specular`, `baseColor`); `CustomMaterial`/`ShaderGraphMaterial`
  for vertex-AO modulation (WU-R5).
- HDRI: any neutral soft **studio** equirectangular `.exr`/`.hdr`, royalty-free or
  generated; bundle via `Package.swift` `resources:` and load with `Bundle.module`.
