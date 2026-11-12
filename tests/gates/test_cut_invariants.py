from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.gates import cut_invariants  # noqa: E402


def test_spur_gear_section_is_not_decimated_below_tooth_detail() -> None:
    mesh = cut_invariants.load_mesh(
        REPO_ROOT / "tests/fixtures/real-world/spur_gear_T20_M2.stl"
    )
    section = cut_invariants.mesh_section(mesh, "z", 4.0)[0]

    assert len(section) == 720
    assert cut_invariants.SECTION_DECIMATION_MAX_POINTS >= len(section)
    assert len(
        cut_invariants._decimate(
            section,
            cut_invariants.SECTION_DECIMATION_MAX_POINTS,
        )
    ) == len(section)


def _square(x0, y0, size):
    return [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]


def _segments(points, closed=True):
    pairs = list(zip(points, points[1:] + (points[:1] if closed else [])))
    return [(a[0], a[1], b[0], b[1]) for a, b in pairs]


def test_chaining_closes_loops_in_file_order_and_keeps_open_paths() -> None:
    segs = _segments(_square(0, 0, 10)) + _segments(_square(2, 2, 3)) + _segments([(20, 0), (25, 0), (25, 5)], closed=False)
    loops, open_chains = cut_invariants.chain_segments(segs)
    assert [len(l) for l in loops] == [4, 4]
    assert [len(c) for c in open_chains] == [3]


def test_a_chain_written_in_two_pieces_is_joined() -> None:
    square = _segments(_square(0, 0, 10))
    loops, open_chains = cut_invariants.chain_segments(square[2:] + square[:2])
    assert len(loops) == 1 and not open_chains


def test_nested_loops_become_a_part_with_a_hole_and_crossing_loops_a_notch() -> None:
    outline = np.array(_square(0, 0, 20), dtype=float)
    hole = np.array(_square(5, 5, 4), dtype=float)
    notch = np.array(_square(14, -1, 4), dtype=float)  # crosses the bottom edge, mostly inside
    island = np.array(_square(30, 0, 5), dtype=float)
    parts, orphans = cut_invariants.group_layer("L", [outline, hole, notch, island])
    assert not orphans
    assert len(parts) == 2
    big = max(parts, key=lambda p: abs(cut_invariants.polygon_area(p.outline)))
    assert len(big.holes) == 1 and len(big.notches) == 1


def _layout(lines: dict) -> cut_invariants.Layout:
    lines = dict(lines)
    lines["sheet_boundary"] = _segments(_square(-50, -50, 300))
    return cut_invariants.build_layout(cut_invariants.DxfEntities(lines=lines))


def test_crossing_pieces_on_one_layer_are_two_overlapping_parts() -> None:
    # The second square overlaps a corner of the first: mostly outside it, so
    # it is a piece cut on top of the first, not a notch.
    layout = _layout({"L": _segments(_square(0, 0, 20)) + _segments(_square(15, 15, 20))})
    assert len(layout.parts) == 2
    overlap = cut_invariants.check_no_overlap(layout)
    assert not overlap.passed
    assert [v.where for v in overlap.violations] == ["L#1<->L#2"]


def test_part_count_fails_when_parts_are_missing_or_extra() -> None:
    layout = _layout({"A": _segments(_square(0, 0, 10)), "B": _segments(_square(20, 0, 10))})
    assert cut_invariants.check_part_count(layout, 2).passed
    missing = cut_invariants.check_part_count(layout, 3)
    assert not missing.passed and missing.violations[0].detail == "2 parts, expected 3"
    assert cut_invariants.check_part_count(layout, None).passed


def _comb(slot_width: float, pitch: float = 10.0, slots: int = 3, depth: float = 20.0) -> list[tuple[float, float]]:
    """A 40 mm deep part with `slots` slots cut down from its top edge."""
    width = pitch * slots
    points = [(0.0, 0.0), (width, 0.0), (width, 40.0)]
    for k in reversed(range(slots)):
        centre = pitch * (k + 0.5)
        points += [(centre + slot_width / 2, 40.0), (centre + slot_width / 2, 40.0 - depth),
                   (centre - slot_width / 2, 40.0 - depth), (centre - slot_width / 2, 40.0)]
    points.append((0.0, 40.0))
    return points


def test_slot_widths_measure_each_slot_between_its_walls() -> None:
    widths = cut_invariants.slot_widths(np.array(_comb(3.0), dtype=float))
    assert len(widths) == 3
    assert all(abs(w - 3.0) < 1e-9 for _, w in widths)


def test_a_slot_at_the_end_of_a_part_is_not_measured() -> None:
    # The last slot runs off the part's right end: it has one wall only.
    points = [(0.0, 0.0), (30.0, 0.0), (30.0, 20.0), (28.5, 20.0), (28.5, 40.0),
              (16.5, 40.0), (16.5, 20.0), (13.5, 20.0), (13.5, 40.0), (0.0, 40.0)]
    widths = cut_invariants.slot_widths(np.array(points, dtype=float))
    assert [round(w, 6) for _, w in widths] == [3.0]


def test_slots_narrower_than_the_stock_fail() -> None:
    narrow = _layout({"A": _segments(_comb(1.0))})
    result = cut_invariants.check_slots_fit_material(narrow, 3.0)
    assert not result.passed and len(result.violations) == 3
    assert "1.000mm wide, narrower than the 3.000mm stock" in result.violations[0].detail
    assert cut_invariants.check_slots_fit_material(_layout({"A": _segments(_comb(3.0))}), 3.0).passed
    assert cut_invariants.check_slots_fit_material(narrow, None).passed


def test_a_loop_written_twice_is_reported() -> None:
    square = _square(0, 0, 10)
    entities = cut_invariants.DxfEntities(lines={
        "L": _segments(square) + _segments(square),
        "sheet_boundary": _segments(_square(-5, -5, 100)),
    })
    layout = cut_invariants.build_layout(entities)
    validity = cut_invariants.check_validity(layout)
    assert not validity.passed
    assert "cut twice" in validity.violations[0].detail


def test_an_outline_that_pinches_fails_validity() -> None:
    # Two squares meeting at the corner (10, 10), drawn as one figure of
    # eight that crosses over there: two pieces held only at a point.
    eight = [(0, 0), (10, 0), (10, 10), (20, 10), (20, 20), (10, 20), (10, 10), (0, 10)]
    assert cut_invariants.pinch_point(np.array(eight, dtype=float)) is not None
    crossing = [(15, 30), (10, 10), (10, 0), (0, 0), (0, 10), (10, 10), (30, 15), (30, 30)]
    assert cut_invariants.pinch_point(np.array(crossing, dtype=float)) is not None
    layout = _layout({"L": _segments(crossing)})
    validity = cut_invariants.check_validity(layout)
    assert not validity.passed
    assert any("pinches at (10.000, 10.000)" in v.detail for v in validity.violations)


def test_two_pieces_meeting_at_a_corner_drawn_apart_pass_validity() -> None:
    # The same two pieces, each written as its own loop, are two parts.
    layout = _layout({"L": _segments(_square(0, 0, 10)) + _segments(_square(10, 10, 10))})
    assert len(layout.parts) == 2
    assert cut_invariants.check_validity(layout).passed


def test_a_hole_reaching_the_edge_is_not_a_pinch() -> None:
    keyhole = [(0, 0), (40, 0), (40, 40), (20, 40), (10, 30), (30, 30), (20, 40), (0, 40)]
    assert cut_invariants.pinch_point(np.array(keyhole, dtype=float)) is None


def test_material_in_model_reads_the_section_on_each_parts_plane() -> None:
    torus = cut_invariants.load_mesh(REPO_ROOT / "tests/fixtures/primitives/torus_R30_r10mm.stl")
    assert cut_invariants.mesh_is_closed(torus)
    cracked = cut_invariants.load_mesh(REPO_ROOT / "tests/fixtures/pathological/lumpy_blob_open_poles.stl")
    assert not cut_invariants.mesh_is_closed(cracked)
    # A ring on the torus's middle plane, DXF (x, y) -> model (x, y, 0).
    frame = np.array([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 0.0]])
    ring = [(40.0 * np.cos(a), 40.0 * np.sin(a)) for a in np.linspace(0, 2 * np.pi, 64, endpoint=False)]
    hole = [(20.0 * np.cos(a), 20.0 * np.sin(a)) for a in np.linspace(0, 2 * np.pi, 64, endpoint=False)][::-1]
    annulus = _layout({"Z-1": _segments(ring) + _segments(hole)})
    good = cut_invariants.check_material_in_model(annulus, {"Z-1": frame}, torus, True)
    assert good.passed, [v.detail for v in good.violations]
    # The torus's hole cut solid: material up to 20 mm outside the model.
    disc = _layout({"Z-1": _segments(ring)})
    filled = cut_invariants.check_material_in_model(disc, {"Z-1": frame}, torus, True)
    assert not filled.passed
    assert filled.worst_value > 19
    # Unarmed it passes; armed on an open mesh it fails rather than guess.
    assert cut_invariants.check_material_in_model(disc, {"Z-1": frame}, torus, False).passed
    assert not cut_invariants.check_material_in_model(disc, {"Z-1": frame}, cracked, True).passed
