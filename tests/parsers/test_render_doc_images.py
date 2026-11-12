"""Tests for `tools/render_doc_images.py`, which draws the images in docs/images.

They check the two readers (OBJ and cut-sheet SVG) and the two renderers on
small hand-written inputs, so they need no built app.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image

from tools import render_doc_images as rdi

CUBE_OBJ = """\
# unit cube as two objects, one face quad split into triangles
o first_001
v 0 0 0
v 10 0 0
v 10 10 0
v 0 10 0
v 0 0 10
v 10 0 10
v 10 10 10
v 0 10 10
f 1 2 3 4
f 5 6 7 8
o second_002
f 1 2 6 5
f 2 3 7 6
f 3 4 8 7
f 4 1 5 8
"""

SHEET_SVG = """\
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="300mm" height="200mm" viewBox="0 0 300 200">
<g id="sheet-1" transform="translate(0 0)">
<rect x="0" y="0" width="300" height="200" fill="none" stroke="#888888" stroke-width="0.1"/>
<g id="part-1">
<path d="M 10 10 L 60 10 L 60 40 L 10 40 Z" fill="none" stroke="#0000FF" stroke-width="0.1"/>
<circle cx="35" cy="25" r="5" fill="none" stroke="#0000FF" stroke-width="0.1"/>
<text x="35" y="25" fill="#FF0000" font-size="8" text-anchor="middle">1</text>
</g>
</g>
<g id="sheet-2" transform="translate(0 200)">
<rect x="0" y="0" width="300" height="200" fill="none" stroke="#888888" stroke-width="0.1"/>
<g id="part-2">
<path d="M 20 20 L 40 20 L 40 30 Z" fill="none" stroke="#0000FF" stroke-width="0.1"/>
</g>
</g>
</svg>
"""


def write(tmp_path: Path, name: str, text: str) -> Path:
    path = tmp_path / name
    path.write_text(text)
    return path


def test_read_obj_keeps_objects_and_triangulates_quads(tmp_path):
    groups = rdi.read_obj(write(tmp_path, "cube.obj", CUBE_OBJ))
    assert [name for name, _ in groups] == ["first_001", "second_002"]
    # Two quads (the cube's top and bottom) become four triangles; four more quads, eight more.
    assert groups[0][1].shape == (4, 3, 3)
    assert groups[1][1].shape == (8, 3, 3)


def test_read_obj_accepts_negative_and_slashed_indices(tmp_path):
    obj = "o a\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1/1/1 2/2/2 3/3/3\nf -3 -2 -1\n"
    (_, tris), = rdi.read_obj(write(tmp_path, "tri.obj", obj))
    assert tris.shape == (2, 3, 3)
    assert np.allclose(tris[0], tris[1])


def test_render_mesh_draws_the_model_on_a_plain_background(tmp_path):
    groups = rdi.read_obj(write(tmp_path, "cube.obj", CUBE_OBJ))
    img = rdi.render_mesh(groups, size=(160, 120), supersample=2)
    assert img.size == (160, 120) and img.mode == "RGB"
    pixels = np.asarray(img)
    # The corner is background, the centre is model.
    assert tuple(pixels[2, 2]) == rdi.BACKGROUND
    assert tuple(pixels[60, 80]) != rdi.BACKGROUND


def test_render_mesh_is_deterministic(tmp_path):
    groups = rdi.read_obj(write(tmp_path, "cube.obj", CUBE_OBJ))
    a = np.asarray(rdi.render_mesh(groups, size=(96, 72), supersample=2))
    b = np.asarray(rdi.render_mesh(groups, size=(96, 72), supersample=2))
    assert np.array_equal(a, b)


def test_family_colors_tell_the_two_part_families_apart():
    colors = rdi._group_colors(
        [("primary_001", np.zeros((1, 3, 3))), ("primary_002", np.zeros((1, 3, 3))),
         ("secondary_003", np.zeros((1, 3, 3)))],
        families=True,
    )
    assert tuple(colors[0]) == rdi.PALETTE_A[0]
    assert tuple(colors[1]) == rdi.PALETTE_A[1]
    assert tuple(colors[2]) == rdi.PALETTE_B[0]


def test_read_sheets_splits_sheets_and_reads_shapes(tmp_path):
    sheets = rdi.read_sheets(write(tmp_path, "sheet.svg", SHEET_SVG))
    assert len(sheets) == 2
    first = sheets[0]
    assert (first.width, first.height) == (300.0, 200.0)
    kinds = sorted(s.kind for s in first.shapes)
    assert kinds == ["circle", "poly", "text"]
    outline = next(s for s in first.shapes if s.kind == "poly")
    assert outline.closed and len(outline.points) == 4
    # The second sheet is translated down by one sheet height.
    moved = next(s for s in sheets[1].shapes if s.kind == "poly")
    assert moved.points[:, 1].min() == 220.0


def test_render_sheet_crops_to_the_first_sheet(tmp_path):
    img = rdi.render_sheet(write(tmp_path, "sheet.svg", SHEET_SVG), width_px=400)
    assert img.size[0] == 400
    # The only part on sheet 1 is 50 x 30 mm, so the crop is wider than tall.
    assert img.size[0] > img.size[1]
    pixels = np.asarray(img).reshape(-1, 3)
    assert any(tuple(p) == (0, 0, 255) or p[2] > 200 and p[0] < 120 for p in pixels)


def test_save_png_writes_a_small_palette_image(tmp_path):
    out = tmp_path / "nested" / "x.png"
    rdi.save_png(Image.new("RGB", (64, 48), rdi.BACKGROUND), out)
    assert out.exists()
    assert Image.open(out).size == (64, 48)
