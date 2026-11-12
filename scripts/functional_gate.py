#!/usr/bin/env python3
"""Refab Artist functional-correctness gate: can the exported parts be cut?

Runs the cuttability invariants (`tools/gates/cut_invariants.py`) over the
DXF each case exports: the file a user gets from Export, which the headless
CLI writes with `--headless-export --format dxf` through the same writers.

  * GATED invariants decide whether the parts cut and assemble; a failure
    fails the gate:
        - FITS-SHEET            every part lies inside its sheet
        - NO-OVERLAP            no part's cuts reach into another part
        - VALIDITY              closed, non-self-intersecting outlines, none
                                left open or cut twice, none pinched (two
                                pieces held only at a point)
        - BISCUITS-IN-MATERIAL  holes lie inside the part's material, clear
                                of its edge
        - PART-COUNT            the file holds the parts the case exports
        - SLOTS-FIT-MATERIAL    slots are at least as wide as the stock
                                (slotted modes)
        - SLOT-COUNT            the file holds the slots the case exports
                                (slotted modes and Folded Panels)
        - SLOTS-MATE            put back in the model, parts that cross are
                                joined by mating slots (cases with part frames;
                                Folded Panels: every net has its frames, and
                                folded up every slot hole holds a panel and
                                every tab or lug meets one)
        - PARTS-CLEAR           put back in the model, no two parts pass
                                through each other unjoined (same cases;
                                Folded Panels: each net's material lies in
                                its panels, and folded up no two panels'
                                stock passes into each other)
        - PARTS-JOINED          put back in the model, the joints hold every
                                part to the rest, but for parts the export
                                marks detached (shown blue, to glue) (same
                                cases; not Folded Panels nets)
        - MATERIAL-IN-MODEL     put back in the model, every part's material
                                lies in the model's section on its plane: no
                                hole of the model cut solid (Radial and
                                Curve cases on closed meshes)
  * The METRIC is reported as a quality number and does not gate:
        - CONTOUR-MATCHES-MESH  Hausdorff of each part outline vs the closest
                                cross-section of the source mesh

Usage:
    # Validate the committed candidates (no Swift build needed):
    python3 scripts/functional_gate.py

    # Export fresh candidates from the built app, then validate:
    swift build --package-path app/RefabArtist
    python3 scripts/functional_gate.py --generate

Exit code is non-zero iff a gated invariant fails beyond the known-defect
allowlist, or an allowlisted case no longer fails (its entry is stale).
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from tools.gates import cut_invariants  # noqa: E402

GATED = ("FITS-SHEET", "NO-OVERLAP", "VALIDITY", "BISCUITS-IN-MATERIAL", "PART-COUNT", "SLOTS-FIT-MATERIAL",
         "SLOT-COUNT", "SLOTS-MATE", "PARTS-CLEAR", "PARTS-JOINED", "MATERIAL-IN-MODEL")
METRIC = ("CONTOUR-MATCHES-MESH",)

# Concave, hollow, organic and self-intersecting models Curve Slices is gated
# on beyond the sphere, each with first axis Z and Y, in 3 and 5 mm stock.
CURVE_MODELS = {
    "torus": "tests/fixtures/primitives/torus_R30_r10mm.stl",
    "gear": "tests/fixtures/real-world/spur_gear_T20_M2.stl",
    "hollowbox": "tests/fixtures/stress/hollow_box_50mm.stl",
    "chair": "tests/fixtures/real-world/simple_chair.stl",
    "blob": "tests/fixtures/organic/lumpy_blob.stl",
    # Two cubes that run into each other: their overlap is model, not a hole.
    "overlap-cubes": "tests/fixtures/pathological/cube_self_intersecting.stl",
    # The lumpy blob cracked open at both poles, as real scans often are:
    # sections through a pole are open chains closed across the cracks.
    "cracked-blob": "tests/fixtures/pathological/lumpy_blob_open_poles.stl",
    # The torus with a third of its triangles wound inward: the same parts
    # as the torus (joints checked against it, `REFERENCE_MESH`).
    "torus-mixed-winding": "tests/fixtures/pathological/torus_mixed_winding.stl",
}

# The cracked blob (`CURVE_MODELS`), gated in every mode that cuts sections
# at 3 and 5 mm stock.
CRACKED_BLOB = "tests/fixtures/pathological/lumpy_blob_open_poles.stl"

# The torus wound wholly inside out: every triangle faces into the solid.
INVERTED_TORUS = "tests/fixtures/pathological/torus_inverted.stl"

# A square block and a kite-shaped block meeting along one edge: every
# horizontal section is two pieces touching at a corner, which the contourer
# joins into one figure of eight. Stacked must cut them as two pieces.
CORNER_BLOCKS = "tests/fixtures/pathological/blocks_touching_at_corner.stl"

# Meshes whose own winding cannot say where the model is: the gate checks
# the parts cut from them (SLOTS-MATE, PARTS-CLEAR, PARTS-JOINED and
# MATERIAL-IN-MODEL read inside and outside from the winding, `mesh_spans`)
# against the same surface wound consistently and facing out.
REFERENCE_MESH = {
    "tests/fixtures/pathological/torus_mixed_winding.stl": "tests/fixtures/primitives/torus_R30_r10mm.stl",
    INVERTED_TORUS: "tests/fixtures/primitives/torus_R30_r10mm.stl",
}

# Meshes that are not closed: their inside cannot be read from the winding,
# so MATERIAL-IN-MODEL is not armed for the cases cut from them.
OPEN_MESHES = {CRACKED_BLOB}

# Folded Panels models and joint types. A case is labelled by model, joint
# (none for Tab, the CLI's default) and stock ("-3mm"; none for 5 mm).
FOLDED_MODELS = (
    ("cube", "tests/fixtures/primitives/cube_50mm_binary.stl"),
    ("pyramid", "tests/fixtures/square_pyramid_ascii.stl"),
    ("chair", "tests/fixtures/real-world/simple_chair.stl"),
)
FOLDED_JOINTS = ("tab", "diamond", "multitab", "tongue", "rivet", "gear", "puzzle", "ticked", "laced")


def folded_label(model: str, joint: str, stock: str) -> str:
    return model + ("" if joint == "tab" else f"-{joint}") + stock


# (mode, fixture path relative to repo, label, slice axis for the metric)
CASES = [
    ("stacked", "tests/fixtures/primitives/cube_50mm_binary.stl", "cube", "z"),
    ("stacked", "tests/fixtures/primitives/sphere_d50mm.stl", "sphere", "z"),
    ("stacked", "tests/fixtures/primitives/cylinder_d40_h80mm.stl", "cylinder", "z"),
    ("stacked", "tests/fixtures/primitives/torus_R30_r10mm.stl", "torus", "z"),
    ("stacked", "tests/fixtures/real-world/simple_chair.stl", "chair", "z"),
    ("stacked", "tests/fixtures/real-world/spur_gear_T20_M2.stl", "gear", "z"),
    ("interlocked", "tests/fixtures/primitives/cube_50mm_binary.stl", "cube", "z"),
    ("interlocked", "tests/fixtures/primitives/sphere_d50mm.stl", "sphere", "z"),
    ("interlocked", "tests/fixtures/primitives/cylinder_d40_h80mm.stl", "cylinder", "z"),
    # The cracked blob in Stacked and Interlocked, at 3 and 5 mm.
    ("stacked", CRACKED_BLOB, "cracked-blob", "z"),
    ("stacked", CRACKED_BLOB, "cracked-blob-3mm", "z"),
    ("interlocked", CRACKED_BLOB, "cracked-blob", "z"),
    ("interlocked", CRACKED_BLOB, "cracked-blob-5mm", "z"),
    # Two blocks meeting at a corner in every section: Stacked cuts each
    # section as two pieces, not one figure of eight (VALIDITY, PART-COUNT).
    ("stacked", CORNER_BLOCKS, "corner-blocks", "z"),
    ("stacked", CORNER_BLOCKS, "corner-blocks-3mm", "z"),
    ("radial", "tests/fixtures/primitives/cylinder_d40_h80mm.stl", "cylinder", "z"),
    ("radial", "tests/fixtures/primitives/sphere_d50mm.stl", "sphere", "z"),
    # Radial on a short, a concave, an organic and two multi-shell models, at
    # the CLI's defaults (5 mm stock, 12 fins) and the app's (3 mm, 6 fins;
    # "-3mm", `RADIAL_MODELS`): the torus, shorter than ten rings of stock;
    # the chair; the lumpy blob; the low-poly head, whose blocks touch along
    # their faces; two cubes that run into each other; the lumpy blob
    # cracked open at its poles; and the torus with a third of its
    # triangles wound inward.
    *[("radial", fixture, f"{name}{stock}", "z")
      for name, fixture in (
          ("torus", "tests/fixtures/primitives/torus_R30_r10mm.stl"),
          ("chair", "tests/fixtures/real-world/simple_chair.stl"),
          ("blob", "tests/fixtures/organic/lumpy_blob.stl"),
          ("head", "tests/fixtures/organic/low_poly_head.stl"),
          ("overlap-cubes", "tests/fixtures/pathological/cube_self_intersecting.stl"),
          ("cracked-blob", CRACKED_BLOB),
          ("torus-mixed-winding", "tests/fixtures/pathological/torus_mixed_winding.stl"),
      )
      for stock in ("", "-3mm")],
    # The torus wound wholly inside out, at the CLI's defaults: its rings
    # keep their hole. (In the app's 3 mm and 6 fins it cuts the same parts
    # with or without reading the winding right, so that is not a case.)
    ("radial", INVERTED_TORUS, "torus-inverted", "z"),
    # Folded Panels: every joint type that cuts geometry, in 5 and 3 mm
    # stock, on the cube, the square pyramid and the chair; the torus at the
    # app's detail; the spur gear at full detail, whose teeth are thinner
    # than the stock is deep (its edges are all too short for joints)
    # (`FOLDED_MODELS`, `FOLDED_JOINTS`).
    *[("folded", fixture, folded_label(name, joint, stock), "z")
      for name, fixture in FOLDED_MODELS
      for joint in FOLDED_JOINTS
      for stock in ("", "-3mm")],
    ("folded", "tests/fixtures/primitives/torus_R30_r10mm.stl", "torus", "z"),
    ("folded", "tests/fixtures/primitives/torus_R30_r10mm.stl", "torus-3mm", "z"),
    ("folded", "tests/fixtures/real-world/spur_gear_T20_M2.stl", "gear", "z"),
    ("folded", "tests/fixtures/real-world/spur_gear_T20_M2.stl", "gear-3mm", "z"),
    ("curve", "tests/fixtures/primitives/sphere_d50mm.stl", "sphere", "z"),
    ("curve", "tests/fixtures/primitives/sphere_d50mm.stl", "sphere-y", "z"),
    ("curve", "tests/fixtures/primitives/sphere_d50mm.stl", "sphere-5mm", "z"),
    ("curve", "tests/fixtures/primitives/sphere_d50mm.stl", "sphere-y-5mm", "z"),
    # Concave, hollow, organic and self-intersecting models, with first axis
    # Z and Y, in 3 and 5 mm stock (`CURVE_MODELS`).
    *[("curve", fixture, f"{name}{axis}{stock}", "z")
      for name, fixture in CURVE_MODELS.items()
      for axis in ("", "-y")
      for stock in ("", "-5mm")],
    # The torus wound inside out, first axis Z, in 3 and 5 mm: its Z ribs
    # keep their hole. (With first axis Y its sections have no hole to
    # fill, and it cuts the same parts with or without reading the winding
    # right, so it is not a case.)
    ("curve", INVERTED_TORUS, "torus-inverted", "z"),
    ("curve", INVERTED_TORUS, "torus-inverted-5mm", "z"),
]

# The fixture each case is cut from.
CASE_FIXTURE = {f"{mode}/{label}": fixture for mode, fixture, label, _axis in CASES}

# Radial models gated beyond the cylinder and sphere (`CASES`).
RADIAL_MODELS = ("torus", "chair", "blob", "head", "overlap-cubes", "cracked-blob", "torus-mixed-winding")

# Extra export arguments per case, keyed by f"{mode}/{label}". The app's
# Curve Slices default first axis is Y (the CLI's is Z); both are gated.
# Folded Panels exports Tab joinery by default; every other joint type that
# cuts geometry is named. The torus is simplified to the app's 250-face
# detail first, as the app does.
CASE_ARGS = {
    "curve/sphere-y": ["--axis", "y"],
    "curve/sphere-y-5mm": ["--axis", "y"],
    **{f"curve/{name}-y{stock}": ["--axis", "y"]
       for name in CURVE_MODELS for stock in ("", "-5mm")},
    **{f"folded/{folded_label(name, joint, stock)}": ["--joinery-type", joint]
       for name, _fixture in FOLDED_MODELS for joint in FOLDED_JOINTS if joint != "tab"
       for stock in ("", "-3mm")},
    "folded/torus": ["--folded-target-faces", "250"],
    "folded/torus-3mm": ["--folded-target-faces", "250"],
    **{f"radial/{name}-3mm": ["--n-radial", "6"] for name in RADIAL_MODELS},
}

DEFAULT_THICKNESS_MM = 5.0

# Stock thickness for modes that need their own. Interlocked cuts ten slices
# per family whatever the stock, so on these 40-50 mm models 5 mm slots would
# fill the 5 mm slice spacing; 3 mm is the app's default stock. Curve Slices
# is gated at the app's 3 mm and at the CLI's 5 mm (CASE_THICKNESS_MM); in
# either it cuts only as many ribs as leave a stock-thick web between slots.
MODE_THICKNESS_MM = {"interlocked": 3.0, "curve": 3.0}

# Stock thickness for single cases, over their mode's.
CASE_THICKNESS_MM = {
    "curve/sphere-5mm": 5.0,
    "curve/sphere-y-5mm": 5.0,
    **{f"curve/{name}{axis}-5mm": 5.0
       for name in CURVE_MODELS for axis in ("", "-y")},
    **{f"folded/{folded_label(name, joint, '-3mm')}": 3.0
       for name, _fixture in FOLDED_MODELS for joint in FOLDED_JOINTS},
    "folded/torus-3mm": 3.0,
    "folded/gear-3mm": 3.0,
    **{f"radial/{name}-3mm": 3.0 for name in RADIAL_MODELS},
    "stacked/cracked-blob-3mm": 3.0,
    "interlocked/cracked-blob-5mm": 5.0,
    "stacked/corner-blocks-3mm": 3.0,
    "curve/torus-inverted-5mm": 5.0,
}

# Modes whose parts join through slots cut into their edges. Their slots must
# be at least as wide as the stock (the CLI's default slot offset is 0).
SLOTTED_MODES = {"interlocked", "radial", "curve"}

# Parts each case exports. A file with fewer (a dropped page, a lost piece)
# or more fails PART-COUNT. Update with the candidates when an export change
# is meant to change the count.
EXPECTED_PARTS = {
    "stacked/cube": 10,
    "stacked/sphere": 10,
    "stacked/cylinder": 16,
    "stacked/torus": 4,
    "stacked/chair": 178,
    "stacked/gear": 1,
    "interlocked/cube": 20,
    "interlocked/sphere": 20,
    "interlocked/cylinder": 20,
    "stacked/cracked-blob": 15,
    "stacked/cracked-blob-3mm": 23,
    "interlocked/cracked-blob": 17,
    "interlocked/cracked-blob-5mm": 17,
    # Two pieces in each of 6 (10) sections.
    "stacked/corner-blocks": 12,
    "stacked/corner-blocks-3mm": 20,
    "radial/cylinder": 22,
    "radial/sphere": 22,
    "radial/torus": 15,
    "radial/torus-3mm": 12,
    "radial/chair": 17,
    "radial/chair-3mm": 11,
    "radial/blob": 23,
    "radial/blob-3mm": 16,
    "radial/head": 22,
    "radial/head-3mm": 16,
    "radial/overlap-cubes": 22,
    "radial/overlap-cubes-3mm": 16,
    "radial/cracked-blob": 19,
    "radial/cracked-blob-3mm": 13,
    "radial/torus-mixed-winding": 15,
    "radial/torus-mixed-winding-3mm": 12,
    "radial/torus-inverted": 15,
    "folded/cube": 1,
    "folded/cube-3mm": 1,
    "folded/cube-diamond": 1,
    "folded/cube-diamond-3mm": 1,
    "folded/cube-multitab": 1,
    "folded/cube-multitab-3mm": 1,
    "folded/cube-tongue": 1,
    "folded/cube-tongue-3mm": 1,
    "folded/cube-rivet": 1,
    "folded/cube-rivet-3mm": 1,
    "folded/cube-gear": 1,
    "folded/cube-gear-3mm": 1,
    "folded/cube-puzzle": 1,
    "folded/cube-puzzle-3mm": 1,
    "folded/cube-ticked": 1,
    "folded/cube-ticked-3mm": 1,
    "folded/cube-laced": 1,
    "folded/cube-laced-3mm": 1,
    "folded/pyramid": 1,
    "folded/pyramid-3mm": 1,
    "folded/pyramid-diamond": 1,
    "folded/pyramid-diamond-3mm": 1,
    "folded/pyramid-multitab": 1,
    "folded/pyramid-multitab-3mm": 1,
    "folded/pyramid-tongue": 1,
    "folded/pyramid-tongue-3mm": 1,
    "folded/pyramid-rivet": 1,
    "folded/pyramid-rivet-3mm": 1,
    "folded/pyramid-gear": 1,
    "folded/pyramid-gear-3mm": 1,
    "folded/pyramid-puzzle": 1,
    "folded/pyramid-puzzle-3mm": 1,
    "folded/pyramid-ticked": 1,
    "folded/pyramid-ticked-3mm": 1,
    "folded/pyramid-laced": 1,
    "folded/pyramid-laced-3mm": 1,
    "folded/chair": 6,
    "folded/chair-3mm": 6,
    "folded/chair-diamond": 6,
    "folded/chair-diamond-3mm": 6,
    "folded/chair-multitab": 6,
    "folded/chair-multitab-3mm": 6,
    "folded/chair-tongue": 6,
    "folded/chair-tongue-3mm": 6,
    "folded/chair-rivet": 6,
    "folded/chair-rivet-3mm": 6,
    "folded/chair-gear": 6,
    "folded/chair-gear-3mm": 6,
    "folded/chair-puzzle": 6,
    "folded/chair-puzzle-3mm": 6,
    "folded/chair-ticked": 6,
    "folded/chair-ticked-3mm": 6,
    "folded/chair-laced": 6,
    "folded/chair-laced-3mm": 6,
    "folded/gear": 49,
    "folded/gear-3mm": 62,
    "folded/torus": 45,
    "folded/torus-3mm": 27,
    "curve/sphere": 15,
    "curve/sphere-y": 14,
    "curve/sphere-5mm": 10,
    "curve/sphere-y-5mm": 7,
    "curve/torus": 15,
    "curve/torus-5mm": 9,
    "curve/torus-y": 22,
    "curve/torus-y-5mm": 14,
    "curve/gear": 9,
    "curve/gear-5mm": 5,
    "curve/gear-y": 12,
    "curve/gear-y-5mm": 6,
    "curve/hollowbox": 17,
    "curve/hollowbox-5mm": 10,
    "curve/hollowbox-y": 19,
    "curve/hollowbox-y-5mm": 7,
    "curve/chair": 28,
    "curve/chair-5mm": 28,
    "curve/chair-y": 19,
    "curve/chair-y-5mm": 19,
    "curve/blob": 15,
    "curve/blob-5mm": 10,
    "curve/blob-y": 13,
    "curve/blob-y-5mm": 9,
    "curve/overlap-cubes": 19,
    "curve/overlap-cubes-5mm": 14,
    "curve/overlap-cubes-y": 16,
    "curve/overlap-cubes-y-5mm": 12,
    "curve/cracked-blob": 15,
    "curve/cracked-blob-5mm": 11,
    "curve/cracked-blob-y": 13,
    "curve/cracked-blob-y-5mm": 9,
    "curve/torus-mixed-winding": 15,
    "curve/torus-mixed-winding-5mm": 9,
    "curve/torus-mixed-winding-y": 22,
    "curve/torus-mixed-winding-y-5mm": 14,
    "curve/torus-inverted": 15,
    "curve/torus-inverted-5mm": 9,
}

# Joint cuts each case exports: slots cut into part edges, plus, for Folded
# Panels, every hole cut into a net. A slotted case whose slots go missing
# (parts that should interlock but cannot) fails SLOT-COUNT. Update with the
# candidates when an export change is meant to change the count. A Folded
# net counts its holes (slots for tabs, pin holes, lacing holes, and any hole
# the net closes around, as on the torus) plus the slot shapes its outline
# makes where a tab or lug stands near another, or where a Gear or Puzzle
# notch opens: the 5 mm cube with Tab joints has 7 slot holes and 10 such
# shapes. Joints that a seam's angle or the stock rules out are not cut
# (the Folded spec's joint census), so the counts differ between 3 and
# 5 mm stock. Radial counts each ring's
# twelve notches and each fin's ten slots on the cylinder; on the sphere the
# 5 mm rings stand 5 mm apart, so each fin's slots run together into one
# stepped cut that is not counted as slots (SLOTS-MATE checks those joints).
EXPECTED_SLOTS = {
    "interlocked/cube": 200,
    "interlocked/sphere": 136,
    "interlocked/cylinder": 144,
    "interlocked/cracked-blob": 111,
    "interlocked/cracked-blob-5mm": 59,
    "radial/cylinder": 240,
    "radial/sphere": 100,
    "radial/torus": 48,
    "radial/torus-3mm": 36,
    "radial/chair": 48,
    "radial/chair-3mm": 28,
    "radial/blob": 147,
    "radial/blob-3mm": 90,
    "radial/head": 116,
    "radial/head-3mm": 120,
    "radial/overlap-cubes": 240,
    "radial/overlap-cubes-3mm": 120,
    "radial/cracked-blob": 135,
    "radial/cracked-blob-3mm": 70,
    "radial/torus-mixed-winding": 48,
    "radial/torus-mixed-winding-3mm": 36,
    "radial/torus-inverted": 48,
    "folded/cube": 17,
    "folded/cube-3mm": 17,
    "folded/cube-diamond": 11,
    "folded/cube-diamond-3mm": 11,
    "folded/cube-multitab": 59,
    "folded/cube-multitab-3mm": 59,
    "folded/cube-tongue": 17,
    "folded/cube-tongue-3mm": 17,
    "folded/cube-rivet": 24,
    "folded/cube-rivet-3mm": 24,
    "folded/cube-gear": 13,
    "folded/cube-gear-3mm": 13,
    "folded/cube-puzzle": 13,
    "folded/cube-puzzle-3mm": 13,
    "folded/cube-ticked": 0,
    "folded/cube-ticked-3mm": 0,
    "folded/cube-laced": 16,
    "folded/cube-laced-3mm": 16,
    "folded/pyramid": 4,
    "folded/pyramid-3mm": 4,
    "folded/pyramid-diamond": 8,
    "folded/pyramid-diamond-3mm": 5,
    "folded/pyramid-multitab": 0,
    "folded/pyramid-multitab-3mm": 0,
    "folded/pyramid-tongue": 4,
    "folded/pyramid-tongue-3mm": 4,
    "folded/pyramid-rivet": 24,
    "folded/pyramid-rivet-3mm": 23,
    "folded/pyramid-gear": 12,
    "folded/pyramid-gear-3mm": 12,
    "folded/pyramid-puzzle": 4,
    "folded/pyramid-puzzle-3mm": 4,
    "folded/pyramid-ticked": 0,
    "folded/pyramid-ticked-3mm": 0,
    "folded/pyramid-laced": 12,
    "folded/pyramid-laced-3mm": 16,
    "folded/chair": 69,
    "folded/chair-3mm": 69,
    "folded/chair-diamond": 42,
    "folded/chair-diamond-3mm": 42,
    "folded/chair-multitab": 101,
    "folded/chair-multitab-3mm": 472,
    "folded/chair-tongue": 45,
    "folded/chair-tongue-3mm": 69,
    "folded/chair-rivet": 329,
    "folded/chair-rivet-3mm": 303,
    "folded/chair-gear": 195,
    "folded/chair-gear-3mm": 195,
    "folded/chair-puzzle": 65,
    "folded/chair-puzzle-3mm": 65,
    "folded/chair-ticked": 1,
    "folded/chair-ticked-3mm": 1,
    "folded/chair-laced": 175,
    "folded/chair-laced-3mm": 273,
    "folded/gear": 2,
    "folded/gear-3mm": 4,
    "folded/torus": 19,
    "folded/torus-3mm": 35,
    "curve/sphere": 88,
    "curve/sphere-y": 42,
    "curve/sphere-5mm": 36,
    "curve/sphere-y-5mm": 13,
    "curve/torus": 76,
    "curve/torus-5mm": 16,
    "curve/torus-y": 62,
    "curve/torus-y-5mm": 23,
    "curve/gear": 16,
    "curve/gear-5mm": 8,
    "curve/gear-y": 25,
    "curve/gear-y-5mm": 6,
    "curve/hollowbox": 118,
    "curve/hollowbox-5mm": 50,
    "curve/hollowbox-y": 63,
    "curve/hollowbox-y-5mm": 18,
    "curve/chair": 90,
    "curve/chair-5mm": 90,
    "curve/chair-y": 164,
    "curve/chair-y-5mm": 164,
    "curve/blob": 78,
    "curve/blob-5mm": 32,
    "curve/blob-y": 32,
    "curve/blob-y-5mm": 15,
    "curve/overlap-cubes": 130,
    "curve/overlap-cubes-5mm": 70,
    "curve/overlap-cubes-y": 54,
    "curve/overlap-cubes-y-5mm": 36,
    "curve/cracked-blob": 78,
    "curve/cracked-blob-5mm": 32,
    "curve/cracked-blob-y": 32,
    "curve/cracked-blob-y-5mm": 15,
    "curve/torus-mixed-winding": 76,
    "curve/torus-mixed-winding-5mm": 16,
    "curve/torus-mixed-winding-y": 62,
    "curve/torus-mixed-winding-y-5mm": 23,
    "curve/torus-inverted": 76,
    "curve/torus-inverted-5mm": 16,
}

# Cases whose export writes part frames (`--part-frames`), so the parts can be
# put back in the model: the joints SLOTS-MATE checks there. Update with the
# candidates when an export change is meant to change the count. Radial
# counts each ring against each plane of fins (twelve fins, six planes).
# On the other Radial models fewer rings fit, or some rings and fins do not
# meet, so the counts are their own. Folded Panels counts the panels its nets
# fold into (the cube's six faces, the pyramid's five); PARTS-CLEAR folds them
# up and checks their stock.
EXPECTED_JOINTS = {
    "radial/cylinder": 60,
    "radial/sphere": 60,
    "radial/torus": 36,
    "radial/torus-3mm": 36,
    "radial/chair": 18,
    "radial/chair-3mm": 11,
    "radial/blob": 47,
    "radial/blob-3mm": 26,
    "radial/head": 62,
    "radial/head-3mm": 31,
    "radial/overlap-cubes": 60,
    "radial/overlap-cubes-3mm": 30,
    "radial/cracked-blob": 36,
    "radial/cracked-blob-3mm": 18,
    "radial/torus-mixed-winding": 36,
    "radial/torus-mixed-winding-3mm": 36,
    "radial/torus-inverted": 36,
    "folded/cube": 6,
    "folded/cube-3mm": 6,
    "folded/cube-diamond": 6,
    "folded/cube-diamond-3mm": 6,
    "folded/cube-multitab": 6,
    "folded/cube-multitab-3mm": 6,
    "folded/cube-tongue": 6,
    "folded/cube-tongue-3mm": 6,
    "folded/cube-rivet": 6,
    "folded/cube-rivet-3mm": 6,
    "folded/cube-gear": 6,
    "folded/cube-gear-3mm": 6,
    "folded/cube-puzzle": 6,
    "folded/cube-puzzle-3mm": 6,
    "folded/cube-ticked": 6,
    "folded/cube-ticked-3mm": 6,
    "folded/cube-laced": 6,
    "folded/cube-laced-3mm": 6,
    "folded/pyramid": 5,
    "folded/pyramid-3mm": 5,
    "folded/pyramid-diamond": 5,
    "folded/pyramid-diamond-3mm": 5,
    "folded/pyramid-multitab": 5,
    "folded/pyramid-multitab-3mm": 5,
    "folded/pyramid-tongue": 5,
    "folded/pyramid-tongue-3mm": 5,
    "folded/pyramid-rivet": 5,
    "folded/pyramid-rivet-3mm": 5,
    "folded/pyramid-gear": 5,
    "folded/pyramid-gear-3mm": 5,
    "folded/pyramid-puzzle": 5,
    "folded/pyramid-puzzle-3mm": 5,
    "folded/pyramid-ticked": 5,
    "folded/pyramid-ticked-3mm": 5,
    "folded/pyramid-laced": 5,
    "folded/pyramid-laced-3mm": 5,
    "folded/chair": 35,
    "folded/chair-3mm": 35,
    "folded/chair-diamond": 35,
    "folded/chair-diamond-3mm": 35,
    "folded/chair-multitab": 35,
    "folded/chair-multitab-3mm": 35,
    "folded/chair-tongue": 35,
    "folded/chair-tongue-3mm": 35,
    "folded/chair-rivet": 35,
    "folded/chair-rivet-3mm": 35,
    "folded/chair-gear": 35,
    "folded/chair-gear-3mm": 35,
    "folded/chair-puzzle": 35,
    "folded/chair-puzzle-3mm": 35,
    "folded/chair-ticked": 35,
    "folded/chair-ticked-3mm": 35,
    "folded/chair-laced": 35,
    "folded/chair-laced-3mm": 35,
    "folded/gear": 56,
    "folded/gear-3mm": 80,
    "folded/torus": 115,
    "folded/torus-3mm": 160,
    "curve/sphere": 52,
    "curve/sphere-y": 27,
    "curve/sphere-5mm": 21,
    "curve/sphere-y-5mm": 7,
    "curve/torus": 40,
    "curve/torus-5mm": 8,
    "curve/torus-y": 34,
    "curve/torus-y-5mm": 13,
    "curve/gear": 8,
    "curve/gear-5mm": 4,
    "curve/gear-y": 15,
    "curve/gear-y-5mm": 4,
    "curve/hollowbox": 66,
    "curve/hollowbox-5mm": 25,
    "curve/hollowbox-y": 41,
    "curve/hollowbox-y-5mm": 11,
    "curve/chair": 54,
    "curve/chair-5mm": 54,
    "curve/chair-y": 94,
    "curve/chair-y-5mm": 92,
    "curve/blob": 41,
    "curve/blob-5mm": 19,
    "curve/blob-y": 17,
    "curve/blob-y-5mm": 8,
    "curve/overlap-cubes": 72,
    "curve/overlap-cubes-5mm": 41,
    "curve/overlap-cubes-y": 27,
    "curve/overlap-cubes-y-5mm": 18,
    "curve/cracked-blob": 41,
    "curve/cracked-blob-5mm": 19,
    "curve/cracked-blob-y": 17,
    "curve/cracked-blob-y-5mm": 8,
    "curve/torus-mixed-winding": 40,
    "curve/torus-mixed-winding-5mm": 8,
    "curve/torus-mixed-winding-y": 34,
    "curve/torus-mixed-winding-y-5mm": 13,
    "curve/torus-inverted": 40,
    "curve/torus-inverted-5mm": 8,
}

# Cases with a known cuttability defect in today's export: the gated
# invariants they fail, and why. They are reported but do not fail the gate,
# as long as they fail exactly these invariants. Keyed by f"{mode}/{label}".
KNOWN_DEFECTS: dict[str, tuple[tuple[str, ...], str]] = {}

CONTOUR_FIDELITY_LIMITATIONS = {
    # Where the contour metric does not apply, rather than a defect.
    "folded": "nets are unfolded surfaces, not cross-sections",
    "interlocked": "slots are cut into the outlines; sections of a second axis",
    "radial": "fins are sections of rotated planes; joints are cut into the rings and fins",
    "curve": "slots are cut into the outlines; curve slices follow a spline",
}


def case_mesh(fixture: str) -> Path:
    """The mesh a case's parts are checked against: its fixture, or the same
    surface wound consistently (`REFERENCE_MESH`)."""
    return REPO / REFERENCE_MESH.get(fixture, fixture)


def candidate_path(base: Path, mode: str, label: str) -> Path:
    return base / f"{mode}__{label}" / "parts.dxf"


def frames_path(base: Path, mode: str, label: str) -> Path:
    return base / f"{mode}__{label}" / "parts.frames.json"


def case_thickness(mode: str, label: str, default: float = DEFAULT_THICKNESS_MM) -> float:
    return CASE_THICKNESS_MM.get(f"{mode}/{label}", MODE_THICKNESS_MM.get(mode, default))


def case_checks(mode: str, label: str, default_thickness: float = DEFAULT_THICKNESS_MM,
                base: Path | None = None) -> dict:
    """The PART-COUNT, SLOTS-FIT-MATERIAL and SLOT-COUNT arguments for one
    case, plus, given the candidate root `base`, the SLOTS-MATE and
    PARTS-CLEAR ones."""
    key = f"{mode}/{label}"
    checks = {
        "expected_parts": EXPECTED_PARTS[key],
        "slot_width": case_thickness(mode, label, default_thickness) if mode in SLOTTED_MODES else None,
        "expected_slots": EXPECTED_SLOTS.get(key),
    }
    if mode == "folded":
        # Folded nets carry their joint holes on the part's own layer. Laced
        # joints' holes are for a cord: nothing of the nets passes through.
        checks["count_part_holes"] = True
        checks["stock"] = case_thickness(mode, label, default_thickness)
        checks["folded_holes_hold_joints"] = CASE_ARGS.get(key, [])[1:2] != ["laced"]
    if base is not None and key in EXPECTED_JOINTS:
        checks["part_frames"] = frames_path(base, mode, label)
        checks["expected_joints"] = EXPECTED_JOINTS[key]
        # Radial and Curve parts are sections of the model: put back, their
        # material must lie in it. Not on an open mesh, whose inside the
        # winding cannot say.
        checks["material_in_model"] = mode in ("radial", "curve") and CASE_FIXTURE.get(key) not in OPEN_MESHES
    return checks


def find_binary() -> Path:
    candidates = [
        REPO / "app/RefabArtist/.build/debug/RefabArtist",
        REPO / "app/RefabArtist/.build/arm64-apple-macosx/debug/RefabArtist",
        REPO / "app/RefabArtist/.build/release/RefabArtist",
    ]
    for c in candidates:
        if c.exists():
            return c
    raise SystemExit(
        "Built app not found. Run: swift build --package-path app/RefabArtist"
    )


def generate(base: Path, thickness: float) -> None:
    """Export every case as the default DXF (what Export writes)."""
    binary = find_binary()
    for mode, fixture, label, _axis in CASES:
        out = candidate_path(base, mode, label)
        out.parent.mkdir(parents=True, exist_ok=True)
        key = f"{mode}/{label}"
        cmd = [
            str(binary), "--headless-export",
            "--mode", mode, "--format", "dxf",
            "--fixture", str(REPO / fixture),
            "--thickness", str(case_thickness(mode, label, thickness)),
            "--output", str(out),
            *CASE_ARGS.get(key, []),
        ]
        if key in EXPECTED_JOINTS:
            cmd += ["--part-frames", str(frames_path(base, mode, label))]
        res = subprocess.run(cmd, capture_output=True, text=True)
        ok = res.returncode == 0 and out.exists()
        status = "ok" if ok else "EXPORT_FAIL"
        print(f"  generate {mode}/{label}: {status}")
        if not ok:
            print((res.stderr or res.stdout).strip()[:200])


def run(base: Path, tol_mm: float, contour: bool = True, thickness: float = DEFAULT_THICKNESS_MM) -> int:
    rows = []
    gate_failures = []
    for mode, fixture, label, axis in CASES:
        key = f"{mode}/{label}"
        cand = candidate_path(base, mode, label)
        row = {"case": key, "mode": mode, "label": label}
        if not cand.exists():
            row["error"] = "candidate missing"
            rows.append(row)
            gate_failures.append((key, row["error"]))
            continue
        try:
            # The contour metric does not apply to Folded nets (see
            # CONTOUR_FIDELITY_LIMITATIONS), so it is not measured for them.
            result = cut_invariants.validate(cand, case_mesh(fixture), axis, tol_mm=tol_mm,
                                             contour=contour and mode != "folded",
                                             **case_checks(mode, label, thickness, base))
        except Exception as exc:  # noqa: BLE001
            row["error"] = f"{type(exc).__name__}: {exc}"
            rows.append(row)
            gate_failures.append((key, row["error"]))
            continue
        by_name = {inv.name: inv for inv in result["invariants"]}
        row["n_parts"] = result["n_parts"]
        row["n_sheets"] = result["n_sheets"]
        for name in GATED:
            inv = by_name[name]
            row[name] = "PASS" if inv.passed else "FAIL"
            if not inv.passed:
                row.setdefault("violations", {})[name] = [
                    f"{v.where}: {v.detail}" for v in inv.violations
                ]
        for name in METRIC:
            inv = by_name.get(name)
            row[name] = None if inv is None else round(inv.worst_value, 3)
        failed = tuple(n for n in GATED if row[n] == "FAIL")
        row["gate"] = "PASS" if not failed else "FAIL"
        expected = KNOWN_DEFECTS.get(key, ((), ""))[0]
        if set(failed) - set(expected):
            gate_failures.append((key, f"gated invariants failed: {', '.join(sorted(set(failed) - set(expected)))}"))
        elif expected and not failed:
            gate_failures.append((key, "listed in KNOWN_DEFECTS but now passes: remove the entry"))
        rows.append(row)

    _print_table(rows)
    _summary(rows, gate_failures)

    out_json = base / "functional_gate.json"
    out_json.write_text(json.dumps(rows, indent=2) + "\n")
    print(f"\nJSON: {out_json}")
    return 1 if gate_failures else 0


def _print_table(rows) -> None:
    hdr = ["case", "parts", "sheets", "fits", "overlap", "valid", "biscuits", "count", "slots", "slot#",
           "mate", "clear", "joined", "model", "gate", "contour(mm)"]
    print("\n{:<20} {:>5} {:>6} {:>5} {:>7} {:>5} {:>8} {:>5} {:>5} {:>5} {:>5} {:>5} {:>6} {:>5} {:>5} {:>11}".format(*hdr))
    print("-" * 126)
    for r in rows:
        if "error" in r:
            print(f"{r['case']:<20} {'ERROR: ' + r['error']}")
            continue
        kd = " *" if r["case"] in KNOWN_DEFECTS else ""
        contour = r.get("CONTOUR-MATCHES-MESH")
        print("{:<20} {:>5} {:>6} {:>5} {:>7} {:>5} {:>8} {:>5} {:>5} {:>5} {:>5} {:>5} {:>6} {:>5} {:>5} {:>11}{}".format(
            r["case"], r.get("n_parts", "-"), r.get("n_sheets", "-"),
            r.get("FITS-SHEET", "-"), r.get("NO-OVERLAP", "-"),
            r.get("VALIDITY", "-"), r.get("BISCUITS-IN-MATERIAL", "-"),
            r.get("PART-COUNT", "-"), r.get("SLOTS-FIT-MATERIAL", "-"),
            r.get("SLOT-COUNT", "-"), r.get("SLOTS-MATE", "-"), r.get("PARTS-CLEAR", "-"),
            r.get("PARTS-JOINED", "-"), r.get("MATERIAL-IN-MODEL", "-"), r.get("gate", "-"),
            "-" if contour is None else f"{contour}",
            kd,
        ))
        for name, lines in r.get("violations", {}).items():
            for line in lines[:4]:
                print(f"{'':22}{name}: {line}")
            if len(lines) > 4:
                print(f"{'':22}{name}: ... +{len(lines) - 4} more")


def _summary(rows, gate_failures) -> None:
    passing = [r for r in rows if r.get("gate") == "PASS"]
    print(f"\nGATE: {len(passing)}/{len([r for r in rows if 'gate' in r])} cases pass the cuttability invariants.")
    if KNOWN_DEFECTS:
        print("Known defects (reported, not gating):")
        for k, (names, why) in KNOWN_DEFECTS.items():
            print(f"  - {k} [{', '.join(names)}]: {why}")
        print("* = known-defect case.")
    print("contour(mm) is a quality metric, not gated (see docs/functional-gate.md); it does not apply to:")
    for mode, why in CONTOUR_FIDELITY_LIMITATIONS.items():
        print(f"  - {mode}: {why}")
    if gate_failures:
        print("\nGATE FAILURES:")
        for k, why in gate_failures:
            print(f"  - {k}: {why}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--generate", action="store_true",
                    help="export fresh candidates from the built app before validating")
    ap.add_argument("--candidates", type=Path,
                    default=REPO / "tests/fixtures/functional-gate",
                    help="candidate root (default: the committed candidates)")
    ap.add_argument("--thickness", type=float, default=DEFAULT_THICKNESS_MM,
                    help="stock thickness (mm) for modes without their own (Interlocked: 3 mm)")
    ap.add_argument("--tol", type=float, default=cut_invariants.DEFAULT_HAUSDORFF_TOL_MM)
    ap.add_argument("--no-contour", action="store_true",
                    help="skip the contour metric (the gated invariants only)")
    args = ap.parse_args(argv)

    args.candidates.mkdir(parents=True, exist_ok=True)
    if args.generate:
        print("Exporting candidates from the built app:")
        generate(args.candidates, args.thickness)
    return run(args.candidates, args.tol, contour=not args.no_contour, thickness=args.thickness)


if __name__ == "__main__":
    raise SystemExit(main())
