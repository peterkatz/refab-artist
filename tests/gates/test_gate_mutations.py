"""The gate has teeth: break a real export on purpose and the gate fails.

Each test takes a committed candidate (a DXF the app exports), checks that
the untouched file passes the invariant under test, then edits the DXF the
way a defect would (a part pushed off its sheet, two parts on top of each
other, a hole cut where there is no material, an outline left open) and
checks that the invariant fails on that part and the gate exits non-zero.
"""
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

import numpy as np
import pytest

REPO = Path(__file__).resolve().parents[2]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from scripts import functional_gate  # noqa: E402
from tools.gates import cut_invariants  # noqa: E402

CANDIDATES = REPO / "tests/fixtures/functional-gate"


# ---------------------------------------------------------------------------
# DXF editing: the ENTITIES section as a list of (code, value) records
# ---------------------------------------------------------------------------

class Dxf:
    def __init__(self, path: Path):
        rows = path.read_text(encoding="utf-8").splitlines()
        pairs = [(rows[i], rows[i + 1]) for i in range(0, len(rows) - 1, 2)]
        start = next(i for i, (c, v) in enumerate(pairs) if c.strip() == "2" and v.strip() == "ENTITIES") + 1
        end = next(i for i in range(start, len(pairs)) if pairs[i] == ("0", "ENDSEC"))
        self.head, self.tail = pairs[:start], pairs[end:]
        self.entities: list[list[list[str]]] = []
        for code, value in pairs[start:end]:
            if code.strip() == "0":
                self.entities.append([])
            self.entities[-1].append([code, value])

    @staticmethod
    def layer(entity) -> str:
        return next(v for c, v in entity if c.strip() == "8")

    def on_layer(self, layer: str):
        return [e for e in self.entities if self.layer(e) == layer]

    def bbox(self, layer: str) -> tuple[float, float, float, float]:
        xs, ys = [], []
        for e in self.on_layer(layer):
            for c, v in e:
                if c.strip() in ("10", "11"):
                    xs.append(float(v))
                elif c.strip() in ("20", "21"):
                    ys.append(float(v))
        return min(xs), min(ys), max(xs), max(ys)

    def move(self, layer: str, dx: float, dy: float) -> None:
        for e in self.on_layer(layer):
            for pair in e:
                code = pair[0].strip()
                if code in ("10", "11"):
                    pair[1] = f"{float(pair[1]) + dx:.6f}"
                elif code in ("20", "21"):
                    pair[1] = f"{float(pair[1]) + dy:.6f}"

    def add_circle(self, layer: str, cx: float, cy: float, r: float) -> None:
        self.entities.append([["0", "CIRCLE"], ["8", layer], ["10", f"{cx:.6f}"], ["20", f"{cy:.6f}"],
                              ["30", "0.000000"], ["40", f"{r:.6f}"]])

    def drop_first_line(self, layer: str) -> None:
        self.entities.remove(next(e for e in self.on_layer(layer) if e[0][1].strip() == "LINE"))

    def drop_layer(self, layer: str) -> None:
        self.entities = [e for e in self.entities if self.layer(e) != layer]

    def copy_layer(self, layer: str, dx: float, dy: float) -> None:
        """Add a shifted copy of the layer's entities to the same layer."""
        for e in self.on_layer(layer):
            copy = [list(pair) for pair in e]
            for pair in copy:
                code = pair[0].strip()
                if code in ("10", "11"):
                    pair[1] = f"{float(pair[1]) + dx:.6f}"
                elif code in ("20", "21"):
                    pair[1] = f"{float(pair[1]) + dy:.6f}"
            self.entities.append(copy)

    def write(self, path: Path) -> None:
        pairs = self.head + [p for e in self.entities for p in e] + self.tail
        path.write_text("".join(f"{c}\n{v}\n" for c, v in pairs), encoding="utf-8")


def candidate(case: str) -> Path:
    return CANDIDATES / case / "parts.dxf"


def result_of(path: Path, **checks) -> dict[str, cut_invariants.InvariantResult]:
    result = cut_invariants.validate(path, None, contour=False, **checks)
    return {inv.name: inv for inv in result["invariants"]}


def mutated(tmp_path: Path, case: str, edit) -> Path:
    dxf = Dxf(candidate(case))
    edit(dxf)
    out = tmp_path / case / "parts.dxf"
    out.parent.mkdir(parents=True, exist_ok=True)
    dxf.write(out)
    return out


def failing_places(inv: cut_invariants.InvariantResult) -> str:
    return " | ".join(f"{v.where}: {v.detail}" for v in inv.violations)


# ---------------------------------------------------------------------------
# The untouched sources pass everything these tests break
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("case", ["stacked__cube", "stacked__sphere", "stacked__torus", "interlocked__cube",
                                  "radial__cylinder", "radial__sphere",
                                  "folded__cube", "folded__cube-diamond", "folded__cube-tongue", "folded__cube-rivet",
                                  "folded__pyramid-gear", "folded__chair"])
def test_untouched_candidates_pass_every_gated_invariant(case) -> None:
    for name, inv in result_of(candidate(case)).items():
        assert inv.passed, f"{case} {name}: {failing_places(inv)}"


def test_rewriting_an_untouched_candidate_keeps_it_identical(tmp_path) -> None:
    out = mutated(tmp_path, "stacked__cube", lambda dxf: None)
    assert out.read_bytes() == candidate("stacked__cube").read_bytes()


# ---------------------------------------------------------------------------
# FITS-SHEET
# ---------------------------------------------------------------------------

def test_part_moved_off_its_sheet_fails_fits_sheet(tmp_path) -> None:
    # Row layout (Stacked): push one slice past the sheet's right edge.
    path = mutated(tmp_path, "stacked__cube", lambda dxf: dxf.move("slice_003", 600.0, 0.0))
    fits = result_of(path)["FITS-SHEET"]
    assert not fits.passed
    assert [v.where for v in fits.violations] == ["slice_003"]


def test_part_straddling_the_sheet_edge_fails_fits_sheet(tmp_path) -> None:
    # Cut-sheet layout (Interlocked): slide one part half off the bottom.
    def edit(dxf):
        x0, y0, x1, y1 = dxf.bbox("Z-1")
        dxf.move("Z-1", 0.0, -(y0 + (y1 - y0) / 2))
    fits = result_of(mutated(tmp_path, "interlocked__cube", edit))["FITS-SHEET"]
    assert not fits.passed
    assert [v.where for v in fits.violations] == ["Z-1"]


# ---------------------------------------------------------------------------
# NO-OVERLAP
# ---------------------------------------------------------------------------

def test_two_parts_overlapping_fail_no_overlap(tmp_path) -> None:
    def edit(dxf):
        ax0, ay0, _, _ = dxf.bbox("slice_001")
        bx0, by0, _, _ = dxf.bbox("slice_002")
        dxf.move("slice_002", ax0 - bx0 + 10.0, ay0 - by0 + 10.0)
    overlap = result_of(mutated(tmp_path, "stacked__cube", edit))["NO-OVERLAP"]
    assert not overlap.passed
    assert [v.where for v in overlap.violations] == ["slice_001<->slice_002"]


def test_a_part_dropped_inside_another_fails_no_overlap(tmp_path) -> None:
    # No edges cross: a small pole slice sits wholly inside the equator slice.
    def edit(dxf):
        ax0, ay0, ax1, ay1 = dxf.bbox("slice_005")
        bx0, by0, bx1, by1 = dxf.bbox("slice_001")
        dxf.move("slice_001", (ax0 + ax1) / 2 - (bx0 + bx1) / 2, (ay0 + ay1) / 2 - (by0 + by1) / 2)
    overlap = result_of(mutated(tmp_path, "stacked__sphere", edit))["NO-OVERLAP"]
    assert not overlap.passed
    assert [v.where for v in overlap.violations] == ["slice_001<->slice_005"]
    assert "material" in overlap.violations[0].detail


def test_a_second_piece_cut_over_a_part_on_its_layer_fails_no_overlap(tmp_path) -> None:
    # A copy of slice_001 on its own layer, overlapping the original's left
    # side: the loops cross but neither is a notch in the other.
    overlap = result_of(mutated(tmp_path, "stacked__cube", lambda dxf: dxf.copy_layer("slice_001", -30.0, 5.0)))["NO-OVERLAP"]
    assert not overlap.passed
    assert [v.where for v in overlap.violations] == ["slice_001#1<->slice_001#2"]


# ---------------------------------------------------------------------------
# PART-COUNT
# ---------------------------------------------------------------------------

def test_parts_missing_from_the_file_fail_part_count(tmp_path) -> None:
    def edit(dxf):
        dxf.drop_layer("Z-3")
        dxf.drop_layer("X-7")
    path = mutated(tmp_path, "interlocked__cube", edit)
    checks = functional_gate.case_checks("interlocked", "cube")
    results = result_of(path, **checks)
    assert all(results[name].passed for name in ("FITS-SHEET", "NO-OVERLAP", "VALIDITY", "BISCUITS-IN-MATERIAL"))
    assert not results["PART-COUNT"].passed
    assert results["PART-COUNT"].violations[0].detail == "18 parts, expected 20"


# ---------------------------------------------------------------------------
# SLOTS-FIT-MATERIAL
# ---------------------------------------------------------------------------

def test_slots_fit_the_stock_they_seat() -> None:
    for mode, label in (("interlocked", "cube"), ("radial", "cylinder"), ("radial", "sphere")):
        result = result_of(candidate(f"{mode}__{label}"), **functional_gate.case_checks(mode, label))
        assert result["SLOTS-FIT-MATERIAL"].passed, failing_places(result["SLOTS-FIT-MATERIAL"])
        assert not result["SLOTS-FIT-MATERIAL"].note  # it measured slots
    # The same Radial parts checked as if cut for 6 mm stock: every ring
    # notch and fin slot is 1 mm too narrow.
    checks = functional_gate.case_checks("radial", "cylinder")
    checks["slot_width"] = 6.0
    narrow = result_of(candidate("radial__cylinder"), **checks)["SLOTS-FIT-MATERIAL"]
    assert not narrow.passed
    assert len(narrow.violations) == functional_gate.EXPECTED_SLOTS["radial/cylinder"]


# ---------------------------------------------------------------------------
# SLOT-COUNT: parts that should interlock keep their slots
# ---------------------------------------------------------------------------

def _hull(points) -> list[tuple[float, float]]:
    pts = sorted(set(points))
    def half(seq):
        out = []
        for p in seq:
            while len(out) >= 2 and ((out[-1][0] - out[-2][0]) * (p[1] - out[-2][1])
                                     - (out[-1][1] - out[-2][1]) * (p[0] - out[-2][0])) <= 0:
                out.pop()
            out.append(p)
        return out
    lower, upper = half(pts), half(reversed(pts))
    return lower[:-1] + upper[:-1]


def fill_slots(dxf: Dxf, layer: str) -> None:
    """Redraw a convex part without its slots: its outline becomes the hull."""
    lines = [e for e in dxf.on_layer(layer) if e[0][1].strip() == "LINE"]
    points = []
    for e in lines:
        values = {c.strip(): float(v) for c, v in e if c.strip() in ("10", "20", "11", "21")}
        points += [(values["10"], values["20"]), (values["11"], values["21"])]
    hull = _hull(points)
    dxf.entities = [e for e in dxf.entities if not any(e is line for line in lines)]
    for a, b in zip(hull, hull[1:] + hull[:1]):
        dxf.entities.append([["0", "LINE"], ["8", layer], ["10", f"{a[0]:.6f}"], ["20", f"{a[1]:.6f}"],
                             ["30", "0.000000"], ["11", f"{b[0]:.6f}"], ["21", f"{b[1]:.6f}"], ["31", "0.000000"]])


def test_parts_that_lose_their_slots_fail_slot_count(tmp_path) -> None:
    path = mutated(tmp_path, "interlocked__cube", lambda dxf: fill_slots(dxf, "Z-3"))
    count = result_of(path, **functional_gate.case_checks("interlocked", "cube"))["SLOT-COUNT"]
    assert not count.passed
    assert count.violations[0].detail == "190 slots, expected 200"


# ---------------------------------------------------------------------------
# SLOTS-MATE / PARTS-CLEAR: the parts put back in the model
# ---------------------------------------------------------------------------

def curve_checks(label: str = "sphere", frames: Path | None = None, **overrides) -> dict:
    checks = functional_gate.case_checks("curve", label, base=CANDIDATES)
    if frames is not None:
        checks["part_frames"] = frames
    checks.update(overrides)
    return checks


CURVE_FIXTURES = {label: functional_gate.case_mesh(fixture)
                  for mode, fixture, label, _axis in functional_gate.CASES if mode == "curve"}
CURVE_LABELS = sorted(CURVE_FIXTURES)


def curve_result(path: Path, label: str = "sphere", frames: Path | None = None, **overrides):
    result = cut_invariants.validate(path, CURVE_FIXTURES[label], contour=False,
                                     **curve_checks(label, frames, **overrides))
    return {inv.name: inv for inv in result["invariants"]}


def move_in_model(dxf: Dxf, layer: str, frames: Path, shift) -> None:
    """Move a part on its sheet so it lands `shift` (model mm) off its place."""
    import numpy as np
    m = cut_invariants.load_part_frames(frames)[layer]
    dx, dy = np.linalg.pinv(m[:, :2]) @ np.asarray(shift, dtype=float)
    dxf.move(layer, float(dx), float(dy))


@pytest.mark.parametrize("label", CURVE_LABELS)
def test_untouched_curve_joints_all_mate(label) -> None:
    # Every Curve case, the concave, hollow and organic models too: each
    # crossing is a mating half-lap, no slot leaves the model empty, and the
    # outlines are closed.
    results = curve_result(candidate(f"curve__{label}"), label)
    mate = results["SLOTS-MATE"]
    assert mate.passed, failing_places(mate)
    assert mate.note == f"{functional_gate.EXPECTED_JOINTS[f'curve/{label}']} joints checked"
    # Curve ribs stop short of each other: none pass through another.
    clear = results["PARTS-CLEAR"]
    assert clear.passed, failing_places(clear)
    assert results["VALIDITY"].passed, failing_places(results["VALIDITY"])
    # The joints hold every part to the rest, but for parts marked detached.
    joined = results["PARTS-JOINED"]
    assert joined.passed, failing_places(joined)


# The torus, first axis Y, 5 mm stock: the curve ribs that reach the low
# first-axis ribs stop short of the high ones, so these six parts are joined
# to each other but not to the rest (no first-axis rib can be moved to join
# them: docs/specs/curve.md § 3.1.1).
TORUS_Y_5MM_UNJOINED = ["C-4", "C-5", "C-7", "Y-5", "Y-6", "Y-7"]


def frames_marking(tmp_path: Path, case: str, detached: set[str]) -> Path:
    """The case's part frames, with exactly `detached` marked detached."""
    import json
    data = json.loads((CANDIDATES / case / "parts.frames.json").read_text())
    for part in data["parts"]:
        part.pop("detached", None)
        if part["label"] in detached:
            part["detached"] = True
    path = tmp_path / f"{case}.frames.json"
    path.write_text(json.dumps(data))
    return path


def test_parts_the_joints_do_not_hold_to_the_rest_must_be_marked_detached(tmp_path) -> None:
    # The torus, first axis Y, 5 mm: six parts are joined to each other and
    # to nothing else. The export marks them detached (blue on the cut sheet).
    case, label = "curve__torus-y-5mm", "torus-y-5mm"
    untouched = curve_result(candidate(case), label)["PARTS-JOINED"]
    assert untouched.passed, failing_places(untouched)
    assert cut_invariants.load_detached_labels(CANDIDATES / case / "parts.frames.json") == set(TORUS_Y_5MM_UNJOINED)
    assert "joint groups [8, 6]" in untouched.note
    # Unmarked, they fail.
    unmarked = curve_result(candidate(case), label, frames_marking(tmp_path, case, set()))
    joined = unmarked["PARTS-JOINED"]
    assert not joined.passed
    assert sorted(v.where for v in joined.violations) == sorted(TORUS_Y_5MM_UNJOINED), failing_places(joined)
    # A part the joints hold to the rest, marked detached, fails too.
    wrong = curve_result(candidate(case), label,
                         frames_marking(tmp_path, case, set(TORUS_Y_5MM_UNJOINED) | {"C-3"}))["PARTS-JOINED"]
    assert not wrong.passed
    assert [v.where for v in wrong.violations] == ["C-3"], failing_places(wrong)


def test_the_chairs_legs_are_joined_through_the_seat(tmp_path) -> None:
    # The simple chair, first axis Z: at even spacing no first-axis rib
    # crosses the seat and each side curve rib, with the four leg pieces it
    # runs through, is joined to nothing else. Z-4 is moved into the seat
    # (docs/specs/curve.md § 3.1.1): one group, nothing marked detached.
    untouched = curve_result(candidate("curve__chair"), "chair")["PARTS-JOINED"]
    assert untouched.passed, failing_places(untouched)
    assert untouched.note == "joint groups [28]"
    assert cut_invariants.load_detached_labels(CANDIDATES / "curve__chair" / "parts.frames.json") == set()
    # Marking a leg detached now fails: the seat holds it.
    wrong = curve_result(candidate("curve__chair"), "chair",
                         frames_marking(tmp_path, "curve__chair", {"C-1"}))["PARTS-JOINED"]
    assert not wrong.passed
    assert [v.where for v in wrong.violations] == ["C-1"], failing_places(wrong)


def test_a_curve_rib_left_off_the_sheet_leaves_its_first_axis_ribs_unjoined(tmp_path) -> None:
    # Torus, first axis Y, 3 mm: the curve ribs join every first-axis rib
    # into one model. Leave out every curve rib but one: the first-axis
    # ribs it does not cross are held by nothing.
    curve_ribs = sorted({p.layer for p in cut_invariants.build_layout(
        cut_invariants.read_dxf(candidate("curve__torus-y"))).parts if p.layer.startswith("C-")})

    def keep_one(dxf: Dxf) -> None:
        for layer in curve_ribs[1:]:
            dxf.drop_layer(layer)

    path = mutated(tmp_path, "curve__torus-y", keep_one)
    joined = curve_result(path, "torus-y")["PARTS-JOINED"]
    assert not joined.passed
    assert joined.violations and all(v.where.startswith("Y-") for v in joined.violations), failing_places(joined)


def test_two_parts_that_do_not_cross_are_two_groups(tmp_path) -> None:
    # B ends 2 mm short of A's plane: no joint holds it, so it must be marked.
    _, _, joined = crossing_checks(tmp_path, [SQUARE], [box(2, -25, 25, 25)], 0)
    assert not joined.passed
    assert [v.where for v in joined.violations] == ["B-1"], failing_places(joined)
    _, _, joined = crossing_checks(tmp_path, [SQUARE], [box(2, -25, 25, 25)], 0, detached=("B-1",))
    assert joined.passed, failing_places(joined)
    # A half-lap joins them.
    _, _, joined = crossing_checks(tmp_path, [SLOTTED_FROM_TOP], [SLOTTED_FROM_BOTTOM], 1)
    assert joined.passed and "joint groups [2]" in joined.note, failing_places(joined)


def test_a_ring_piece_left_off_the_sheet_leaves_its_crossings_empty(tmp_path) -> None:
    # Hollow box, first axis Y: a slot through the bottom wall cuts curve rib
    # C-2 in two, and the piece C-2-2 holds the bottom wall's joints. Without
    # it the Y ribs' slots there hold nothing.
    path = mutated(tmp_path, "curve__hollowbox-y", lambda dxf: dxf.drop_layer("C-2-2"))
    results = curve_result(path, "hollowbox-y")
    assert not results["PART-COUNT"].passed
    mate = results["SLOTS-MATE"]
    assert not mate.passed
    empty = [v for v in mate.violations if "empty" in v.detail]
    assert empty and all("C-2" in v.where for v in empty), failing_places(mate)


def test_a_torus_rib_without_its_slots_collides(tmp_path) -> None:
    # Torus, first axis Z: C-3 crosses the three Z rings on both sides of the
    # hole; redrawn without its slots it collides with all three.
    path = mutated(tmp_path, "curve__torus", lambda dxf: fill_slots(dxf, "C-3"))
    mate = curve_result(path, "torus")["SLOTS-MATE"]
    assert not mate.passed
    collisions = {v.where for v in mate.violations if "collide" in v.detail}
    assert collisions and all("C-3" in where for where in collisions), failing_places(mate)


def test_an_open_outline_on_the_organic_blob_fails_validity(tmp_path) -> None:
    path = mutated(tmp_path, "curve__blob", lambda dxf: dxf.drop_first_line("C-4"))
    validity = curve_result(path, "blob")["VALIDITY"]
    assert not validity.passed
    assert any("C-4" in v.where for v in validity.violations), failing_places(validity)


def test_a_part_without_its_slots_collides_with_the_parts_it_crosses(tmp_path) -> None:
    path = mutated(tmp_path, "curve__sphere", lambda dxf: fill_slots(dxf, "C-6"))
    results = curve_result(path)
    assert not results["SLOT-COUNT"].passed
    mate = results["SLOTS-MATE"]
    assert not mate.passed
    collisions = [v for v in mate.violations if "collide" in v.detail]
    assert collisions and all("C-6" in v.where for v in collisions), failing_places(mate)


def test_a_slot_cut_too_deep_leaves_the_joint_loose(tmp_path) -> None:
    # Y-4 lands 2 mm low: its slots reach 2 mm past where the curve ribs'
    # slots stop, and each crossing has a 2 mm hole in it.
    frames = CANDIDATES / "curve__sphere-y" / "parts.frames.json"
    path = mutated(tmp_path, "curve__sphere-y", lambda dxf: move_in_model(dxf, "Y-4", frames, (0, 0, -2.0)))
    mate = curve_result(path, "sphere-y")["SLOTS-MATE"]
    assert not mate.passed
    gaps = [v for v in mate.violations if "depths do not add up" in v.detail]
    assert gaps and all(v.where.startswith("Y-4x") for v in gaps), failing_places(mate)
    assert all(abs(v.value - 2.0) < 0.05 for v in gaps)


def test_a_slot_in_the_wrong_place_collides(tmp_path) -> None:
    # Z-4 shifted 1 mm sideways on the sheet: its slots no longer line up
    # with the curve ribs.
    frames = CANDIDATES / "curve__sphere" / "parts.frames.json"
    path = mutated(tmp_path, "curve__sphere", lambda dxf: move_in_model(dxf, "Z-4", frames, (1.0, 0, 0)))
    mate = curve_result(path)["SLOTS-MATE"]
    assert not mate.passed
    assert all("Z-4" in v.where for v in mate.violations), failing_places(mate)


def test_slots_too_narrow_for_the_stock_collide() -> None:
    # The same parts checked as if cut for 4 mm stock: the slots are 3 mm.
    results = curve_result(candidate("curve__sphere"), slot_width=4.0)
    assert not results["SLOTS-FIT-MATERIAL"].passed
    mate = results["SLOTS-MATE"]
    assert not mate.passed
    assert any("collide" in v.detail for v in mate.violations)


def narrow_slots(dxf: Dxf, case: str, layer: str, delta: float) -> None:
    """Narrow every slot cut into the part on `layer` by `delta` mm on each
    side: both walls move in toward the middle of the slot."""
    import numpy as np
    layout = cut_invariants.build_layout(cut_invariants.read_dxf(candidate(case)))
    part = next(p for p in layout.parts if p.layer == layer)
    assert not part.holes and not part.notches
    poly = np.asarray(part.outline, dtype=float)
    if cut_invariants.polygon_area(poly) < 0:
        poly = poly[::-1]
    poly = poly.copy()
    n = len(poly)
    for k, _width in cut_invariants.slot_widths(part.outline):
        bottom = poly[(k + 1) % n] - poly[k]
        step = delta * bottom / np.hypot(*bottom)
        for i in ((k - 1) % n, k):
            poly[i] += step
        for i in ((k + 1) % n, (k + 2) % n):
            poly[i] -= step
    dxf.drop_layer(layer)
    for a, b in zip(poly, np.roll(poly, -1, axis=0)):
        dxf.entities.append([["0", "LINE"], ["8", layer], ["10", f"{a[0]:.6f}"], ["20", f"{a[1]:.6f}"],
                             ["30", "0.000000"], ["11", f"{b[0]:.6f}"], ["21", f"{b[1]:.6f}"], ["31", "0.000000"]])


def test_angled_slots_a_little_too_narrow_collide(tmp_path) -> None:
    # First axis Y: C-7 crosses the Y ribs at a slant, so its slots are
    # 4.99 mm wide for 3 mm stock. Narrowed by 0.2 mm a side (4.59 mm) they
    # are still wider than the stock, but the Y ribs' stock no longer fits.
    path = mutated(tmp_path, "curve__sphere-y", lambda dxf: narrow_slots(dxf, "curve__sphere-y", "C-7", 0.2))
    results = curve_result(path, "sphere-y")
    for name in ("SLOTS-FIT-MATERIAL", "SLOT-COUNT", "PARTS-CLEAR"):
        assert results[name].passed, f"{name}: {failing_places(results[name])}"
    mate = results["SLOTS-MATE"]
    assert not mate.passed
    assert any(v.where == "Y-3xC-7" for v in mate.violations), failing_places(mate)
    assert all("C-7" in v.where and "collide" in v.detail for v in mate.violations), failing_places(mate)


def test_a_rib_turned_out_of_its_plane_hits_its_neighbours(tmp_path) -> None:
    import json
    import math
    data = json.loads((CANDIDATES / "curve__sphere-y" / "parts.frames.json").read_text())
    for part in data["parts"]:
        if part["label"] == "Y-3":
            m = part["dxfToModel"]
            c, s = math.cos(math.radians(30)), math.sin(math.radians(30))
            # Turn the rib's plane 30 degrees about the vertical.
            part["dxfToModel"] = [[c * m[0][k] - s * m[1][k] for k in range(3)],
                                  [s * m[0][k] + c * m[1][k] for k in range(3)],
                                  m[2]]
    frames = tmp_path / "parts.frames.json"
    frames.write_text(json.dumps(data))
    clear = curve_result(candidate("curve__sphere-y"), "sphere-y", frames)["PARTS-CLEAR"]
    assert any(v.where in ("Y-3xY-2", "Y-2xY-3", "Y-3xY-4", "Y-4xY-3") for v in clear.violations), failing_places(clear)


RADIAL_FIXTURES = {
    "cylinder": REPO / "tests/fixtures/primitives/cylinder_d40_h80mm.stl",
    "sphere": REPO / "tests/fixtures/primitives/sphere_d50mm.stl",
    **{f"{name}{stock}": functional_gate.case_mesh(fixture)
       for (mode, fixture, label, _axis) in functional_gate.CASES if mode == "radial"
       for name in [label.removesuffix("-3mm")] for stock in ("", "-3mm")},
}
RADIAL_LABELS = [label for (mode, _f, label, _a) in functional_gate.CASES if mode == "radial"]


def radial_result(path: Path, label: str = "cylinder", frames: Path | None = None, **overrides):
    checks = functional_gate.case_checks("radial", label, base=CANDIDATES)
    if frames is not None:
        checks["part_frames"] = frames
    checks.update(overrides)
    result = cut_invariants.validate(path, RADIAL_FIXTURES[label], contour=False, **checks)
    return {inv.name: inv for inv in result["invariants"]}


@pytest.mark.parametrize("label", RADIAL_LABELS)
def test_untouched_radial_joints_all_mate(label) -> None:
    results = radial_result(candidate(f"radial__{label}"), label)
    mate = results["SLOTS-MATE"]
    assert mate.passed, failing_places(mate)
    assert mate.note == f"{functional_gate.EXPECTED_JOINTS[f'radial/{label}']} joints checked"
    # Fins start where they clear each other at the hub.
    clear = results["PARTS-CLEAR"]
    assert clear.passed, failing_places(clear)


def test_a_ring_without_its_notches_collides_with_every_fin(tmp_path) -> None:
    path = mutated(tmp_path, "radial__cylinder", lambda dxf: fill_slots(dxf, "first_axis_005"))
    results = radial_result(path)
    assert not results["SLOT-COUNT"].passed
    mate = results["SLOTS-MATE"]
    collisions = [v for v in mate.violations if "collide" in v.detail]
    # Twelve fins in six planes cross the ring.
    assert len(collisions) == 6 and all("first_axis_005" in v.where for v in collisions), failing_places(mate)


def test_a_fin_set_too_far_out_leaves_its_joints_open(tmp_path) -> None:
    # radial_001 (the fin at 0 degrees) lands 2 mm farther from the hub: its
    # slots stop 2 mm past the rings' notch bottoms, so each crossing has a
    # 2 mm hole in it.
    frames = CANDIDATES / "radial__cylinder" / "parts.frames.json"
    path = mutated(tmp_path, "radial__cylinder", lambda dxf: move_in_model(dxf, "radial_001", frames, (2.0, 0, 0)))
    mate = radial_result(path)["SLOTS-MATE"]
    assert not mate.passed
    gaps = [v for v in mate.violations if "depths do not add up" in v.detail]
    assert len(gaps) == 10 and all("radial_001" in v.where for v in gaps), failing_places(mate)
    assert all(abs(v.value - 2.0) < 0.05 for v in gaps)


def test_fins_pushed_toward_the_hub_collide_with_the_rings_and_each_other(tmp_path) -> None:
    # radial_001 (0 degrees) and radial_002 (30 degrees) each 3 mm nearer the
    # hub axis: past where their stock clears, and past the rings' notches.
    import math
    frames = CANDIDATES / "radial__cylinder" / "parts.frames.json"
    def edit(dxf):
        move_in_model(dxf, "radial_001", frames, (-3.0, 0, 0))
        move_in_model(dxf, "radial_002", frames, (-3.0 * math.cos(math.radians(30)), -3.0 * math.sin(math.radians(30)), 0))
    results = radial_result(mutated(tmp_path, "radial__cylinder", edit))
    mate = results["SLOTS-MATE"]
    for fin in ("radial_001", "radial_002"):
        assert any("collide" in v.detail and fin in v.where for v in mate.violations), failing_places(mate)
    clear = results["PARTS-CLEAR"]
    assert not clear.passed
    assert all("radial_001" in v.where and "radial_002" in v.where for v in clear.violations), failing_places(clear)
    # One fin pushed in alone still clears its neighbours, which start where
    # they always did; it only runs into the rings.
    alone = radial_result(mutated(tmp_path / "alone", "radial__cylinder",
                                  lambda dxf: move_in_model(dxf, "radial_001", frames, (-3.0, 0, 0))))
    assert alone["PARTS-CLEAR"].passed
    assert not alone["SLOTS-MATE"].passed


@pytest.mark.parametrize("label,layer", [("cylinder", "radial_001"), ("sphere", "first_axis_005")])
def test_radial_slots_a_little_too_narrow_collide(tmp_path, label, layer) -> None:
    # A fin's slots (cylinder) or a ring's notches (sphere) narrowed by
    # 0.2 mm a side: 4.6 mm for 5 mm stock. SLOTS-MATE now sees the other
    # part's stock in them, not just SLOTS-FIT-MATERIAL.
    path = mutated(tmp_path, f"radial__{label}", lambda dxf: narrow_slots(dxf, f"radial__{label}", layer, 0.2))
    results = radial_result(path, label)
    assert results["SLOT-COUNT"].passed and results["PARTS-CLEAR"].passed
    assert not results["SLOTS-FIT-MATERIAL"].passed
    mate = results["SLOTS-MATE"]
    assert not mate.passed
    assert all(layer in v.where and "collide" in v.detail for v in mate.violations), failing_places(mate)


def test_rings_closer_than_the_stock_pass_through_each_other(tmp_path) -> None:
    # In 5 mm stock three rings fit on the 19.9 mm torus, 6.6 mm apart. Put
    # the middle one 3 mm lower, 3.6 mm from the bottom ring: their stock
    # overlaps wherever their outlines do.
    import json
    import numpy as np
    data = json.loads((CANDIDATES / "radial__torus" / "parts.frames.json").read_text())
    for part in data["parts"]:
        if part["label"] == "first_axis_002":
            m = np.asarray(part["dxfToModel"], dtype=float)
            m[2, 2] -= 3.0
            part["dxfToModel"] = m.tolist()
    frames = tmp_path / "parts.frames.json"
    frames.write_text(json.dumps(data))
    untouched = radial_result(candidate("radial__torus"), "torus")
    assert untouched["PARTS-CLEAR"].passed, failing_places(untouched["PARTS-CLEAR"])
    clear = radial_result(candidate("radial__torus"), "torus", frames)["PARTS-CLEAR"]
    assert not clear.passed
    assert [v.where for v in clear.violations] == ["first_axis_001xfirst_axis_002"], failing_places(clear)
    assert "3.630mm apart in 5mm stock" in clear.violations[0].detail


def test_a_fin_left_out_leaves_the_ring_notches_cut_for_it_empty(tmp_path) -> None:
    # The low-poly head's fin at 270 degrees runs through head, nose and
    # brow, one piece. Leave it out: the notches every ring has for it hold
    # nothing.
    frames = cut_invariants.load_part_frames(CANDIDATES / "radial__head" / "parts.frames.json")
    layout = cut_invariants.build_layout(cut_invariants.read_dxf(candidate("radial__head")))
    placed, _ = cut_invariants.place_parts(layout, frames)
    fin = next(p.part.layer for p in placed
               if p.family == "radial" and abs(p.normal[1]) < 1e-6
               and (p.model_points(p.part.outline)[:, 1] < -5).any())
    path = mutated(tmp_path, "radial__head", lambda dxf: dxf.drop_layer(fin))
    results = radial_result(path, "head")
    assert not results["PART-COUNT"].passed
    mate = results["SLOTS-MATE"]
    empty = [v for v in mate.violations if "empty" in v.detail]
    assert empty and all("first_axis" in v.where for v in empty), failing_places(mate)


def test_shells_that_overlap_are_model_where_they_overlap() -> None:
    # Two cubes run into each other: a line through both is inside from one's
    # far face to the other's, overlap and all. A hollow box's cavity, whose
    # surface faces into it, is outside.
    import numpy as np
    cubes = cut_invariants.load_mesh(REPO / "tests/fixtures/pathological/cube_self_intersecting.stl")
    spans = cut_invariants.mesh_spans(cubes, np.array([0.0, 0.0, 10.0]), np.array([1.0, 0.0, 0.0]))
    assert [(round(a, 3), round(b, 3)) for a, b in spans] == [(-25.0, 45.0)]
    box = cut_invariants.load_mesh(REPO / "tests/fixtures/stress/hollow_box_50mm.stl")
    spans = cut_invariants.mesh_spans(box, np.array([0.0, 0.0, 0.0]), np.array([1.0, 0.0, 0.0]))
    assert [(round(a, 3), round(b, 3)) for a, b in spans] == [(-25.0, -15.0), (15.0, 25.0)]


def test_a_fin_turned_off_its_angle_misses_the_ring_notches(tmp_path) -> None:
    import json
    import math
    data = json.loads((CANDIDATES / "radial__cylinder" / "parts.frames.json").read_text())
    for part in data["parts"]:
        if part["label"] == "radial_004":
            m = part["dxfToModel"]
            c, s = math.cos(math.radians(10)), math.sin(math.radians(10))
            # Turn the fin 10 degrees about the hub axis.
            part["dxfToModel"] = [[c * m[0][k] - s * m[1][k] for k in range(3)],
                                  [s * m[0][k] + c * m[1][k] for k in range(3)],
                                  m[2]]
    frames = tmp_path / "parts.frames.json"
    frames.write_text(json.dumps(data))
    mate = radial_result(candidate("radial__cylinder"), frames=frames)["SLOTS-MATE"]
    assert not mate.passed
    assert any("radial_004" in v.where and "collide" in v.detail for v in mate.violations), failing_places(mate)


# Two square ribs of a 50 mm cube crossing on its vertical axis: rib A in the
# plane y = 0, rib B in the plane x = 0, both 3 mm stock. Each is drawn in its
# own section coordinates, (x, z) and (y, z); the part frames put them back in
# the cube (B is drawn 100 mm along the sheet so it does not lie on A).
CROSSING_FRAMES = {
    "A-1": [[1, 0, 0], [0, 0, 0], [0, 1, 0]],
    "B-1": [[0, 0, 0], [1, 0, -100], [0, 1, 0]],
}
SQUARE = [(-25, -25), (25, -25), (25, 25), (-25, 25)]
SLOTTED_FROM_TOP = [(-25, -25), (25, -25), (25, 25), (1.5, 25), (1.5, 0), (-1.5, 0), (-1.5, 25), (-25, 25)]
SLOTTED_FROM_BOTTOM = [(-25, -25), (-1.5, -25), (-1.5, 0), (1.5, 0), (1.5, -25), (25, -25), (25, 25), (-25, 25)]


def box(x0, z0, x1, z1):
    return [(x0, z0), (x1, z0), (x1, z1), (x0, z1)]


def crossing_result(tmp_path: Path, a_loops: list, b_loops: list, joints: int, frames: dict | None = None):
    """SLOTS-MATE and PARTS-CLEAR of the two crossing parts."""
    return crossing_checks(tmp_path, a_loops, b_loops, joints, frames)[:2]


def crossing_checks(tmp_path: Path, a_loops: list, b_loops: list, joints: int, frames: dict | None = None,
                    detached: tuple[str, ...] = ()):
    """SLOTS-MATE, PARTS-CLEAR and PARTS-JOINED of the two crossing parts,
    `detached` naming parts the frames file marks detached."""
    import json
    rows = [("0", "SECTION"), ("2", "ENTITIES")]
    for layer, loops, dx in (("A-1", a_loops, 0.0), ("B-1", b_loops, 100.0)):
        for loop in loops:
            for (x0, y0), (x1, y1) in zip(loop, loop[1:] + loop[:1]):
                rows += [("0", "LINE"), ("8", layer), ("10", f"{x0 + dx}"), ("20", f"{y0}"),
                         ("11", f"{x1 + dx}"), ("21", f"{y1}")]
    rows += [("0", "ENDSEC"), ("0", "EOF")]
    path = tmp_path / "crossing.dxf"
    path.write_text("".join(f"{c}\n{v}\n" for c, v in rows))
    frames_path = tmp_path / "crossing.frames.json"
    frames_path.write_text(json.dumps({"parts": [{"label": k, "dxfToModel": v, **({"detached": True} if k in detached else {})}
                                                 for k, v in (frames or CROSSING_FRAMES).items()]}))
    layout = cut_invariants.build_layout(cut_invariants.read_dxf(path))
    mesh = cut_invariants.load_mesh(REPO / "tests/fixtures/primitives/cube_50mm_binary.stl")
    return cut_invariants.check_joints(layout, cut_invariants.load_part_frames(frames_path), mesh, 3.0, joints,
                                       cut_invariants.load_detached_labels(frames_path))


def test_a_half_lap_on_two_crossing_squares_mates(tmp_path) -> None:
    # A slotted from the top down to the middle, B from the bottom up.
    mate, clear = crossing_result(tmp_path, [SLOTTED_FROM_TOP], [SLOTTED_FROM_BOTTOM], 1)
    assert mate.passed and clear.passed, failing_places(mate)
    # Unslotted, they pass through each other.
    mate, _ = crossing_result(tmp_path, [SQUARE], [SQUARE], 1)
    assert not mate.passed


def test_a_slot_cut_right_through_a_part_does_not_hold(tmp_path) -> None:
    # B in two pieces either side of the crossing (its slot runs full height):
    # B still takes part in the crossing but keeps nothing on it.
    mate, _ = crossing_result(tmp_path, [SLOTTED_FROM_TOP], [box(-25, -25, -1.5, 25), box(1.5, -25, 25, 25)], 1)
    assert not mate.passed
    assert any("does not hold" in v.detail for v in mate.violations), failing_places(mate)


def test_a_part_that_stops_short_of_a_crossing_takes_no_part_in_it(tmp_path) -> None:
    # B ends 2 mm short of A's plane: nothing to join, and A needs no slot.
    mate, clear = crossing_result(tmp_path, [SQUARE], [box(2, -25, 25, 25)], 0)
    assert mate.passed and clear.passed, failing_places(mate)
    # A slotted anyway leaves the top of the crossing empty.
    mate, _ = crossing_result(tmp_path, [SLOTTED_FROM_TOP], [box(2, -25, 25, 25)], 0)
    assert not mate.passed
    assert any("where no part crosses" in v.detail for v in mate.violations), failing_places(mate)


def slotted_from_top(half_width: float) -> list[tuple[float, float]]:
    return [(-25, -25), (25, -25), (25, 25), (half_width, 25), (half_width, 0), (-half_width, 0),
            (-half_width, 25), (-25, 25)]


def slotted_from_bottom(half_width: float) -> list[tuple[float, float]]:
    return [(-25, -25), (-half_width, -25), (-half_width, 0), (half_width, 0), (half_width, -25), (25, -25),
            (25, 25), (-25, 25)]


def test_a_square_slot_a_little_narrower_than_the_stock_collides(tmp_path) -> None:
    # 2.85 mm slots for 3 mm stock: 5% too narrow.
    mate, _ = crossing_result(tmp_path, [slotted_from_top(1.425)], [slotted_from_bottom(1.425)], 1)
    assert not mate.passed
    assert any("collide" in v.detail for v in mate.violations), failing_places(mate)


@pytest.mark.parametrize("degrees", [60.0, 45.0])
def test_a_slot_too_narrow_for_a_slanted_crossing_collides(tmp_path, degrees) -> None:
    # B turned about the crossing line so the two ribs meet at `degrees`: in
    # 3 mm stock each slot must be 3 (1 + cos a) / sin a wide (5.196 mm at
    # 60 degrees, 7.243 mm at 45). That width mates; 8% less, still far wider
    # than the stock, collides.
    import math
    a = math.radians(degrees)
    frames = {"A-1": CROSSING_FRAMES["A-1"],
              "B-1": [[math.cos(a), 0, -100 * math.cos(a)], [math.sin(a), 0, -100 * math.sin(a)], [0, 1, 0]]}
    needed = 3.0 * (1 + math.cos(a)) / math.sin(a)
    for scale, mates in ((1.0, True), (0.92, False)):
        half = needed * scale / 2
        mate, clear = crossing_result(tmp_path, [slotted_from_top(half)], [slotted_from_bottom(half)], 1, frames)
        assert clear.passed
        assert mate.passed == mates, f"{scale}: {failing_places(mate)}"


def test_curve_ribs_turned_into_their_neighbours_pass_through_each_other(tmp_path) -> None:
    import json
    import math
    data = json.loads((CANDIDATES / "curve__sphere" / "parts.frames.json").read_text())
    for part in data["parts"]:
        if part["label"] == "C-6":
            m = part["dxfToModel"]
            c, s = math.cos(math.radians(-15)), math.sin(math.radians(-15))
            # Turn the rib 15 degrees about the vertical, into C-5 and C-7.
            part["dxfToModel"] = [[c * m[0][k] - s * m[1][k] for k in range(3)],
                                  [s * m[0][k] + c * m[1][k] for k in range(3)],
                                  m[2]]
    frames = tmp_path / "parts.frames.json"
    frames.write_text(json.dumps(data))
    clear = curve_result(candidate("curve__sphere"), frames=frames)["PARTS-CLEAR"]
    assert not clear.passed
    assert any("C-6" in v.where for v in clear.violations), failing_places(clear)


def test_curve_ribs_closer_than_the_stock_pass_through_each_other(tmp_path) -> None:
    # In 5 mm stock five curve ribs stand about 11 mm apart. Slide C-3 7 mm
    # along the spline toward a neighbour, closer than the stock is thick,
    # and their stock overlaps where they leave the spline.
    import json
    import numpy as np
    data = json.loads((CANDIDATES / "curve__sphere-5mm" / "parts.frames.json").read_text())
    for part in data["parts"]:
        if part["label"] == "C-3":
            m = np.asarray(part["dxfToModel"], dtype=float)
            normal = np.cross(m[:, 0], m[:, 1])
            m[:, 2] += 7.0 * normal / np.linalg.norm(normal)
            part["dxfToModel"] = m.tolist()
    frames = tmp_path / "parts.frames.json"
    frames.write_text(json.dumps(data))
    untouched = curve_result(candidate("curve__sphere-5mm"), "sphere-5mm")
    assert untouched["PARTS-CLEAR"].passed, failing_places(untouched["PARTS-CLEAR"])
    clear = curve_result(candidate("curve__sphere-5mm"), "sphere-5mm", frames)["PARTS-CLEAR"]
    assert not clear.passed
    assert all("C-3" in v.where for v in clear.violations), failing_places(clear)


def test_joints_are_not_checked_without_part_frames(tmp_path) -> None:
    results = curve_result(candidate("curve__sphere"), frames=tmp_path / "missing.json")
    assert not results["SLOTS-MATE"].passed
    assert results["SLOTS-MATE"].violations[0].detail == "no part frames to check the joints against"


# ---------------------------------------------------------------------------
# BISCUITS-IN-MATERIAL
# ---------------------------------------------------------------------------

def test_biscuit_hole_outside_the_part_fails(tmp_path) -> None:
    def edit(dxf):
        x0, y0, x1, y1 = dxf.bbox("slice_001")
        dxf.add_circle("slice_001", x1 + 4.0, (y0 + y1) / 2, 2.0)  # in the gap beside the part
    holes = result_of(mutated(tmp_path, "stacked__cube", edit))["BISCUITS-IN-MATERIAL"]
    assert not holes.passed
    assert [v.where for v in holes.violations] == ["slice_001@circle1"]


def test_biscuit_hole_cutting_through_the_edge_fails(tmp_path) -> None:
    def edit(dxf):
        x0, y0, x1, y1 = dxf.bbox("slice_001")
        dxf.add_circle("slice_001", x0 + 1.0, (y0 + y1) / 2, 3.0)  # centre inside, rim past the edge
    holes = result_of(mutated(tmp_path, "stacked__cube", edit))["BISCUITS-IN-MATERIAL"]
    assert not holes.passed
    assert holes.violations[0].where.startswith("slice_001@")
    assert "past the material edge" in holes.violations[0].detail


def test_biscuit_hole_in_a_void_of_the_part_fails(tmp_path) -> None:
    # The torus slices are rings: a dowel at the centre lands in the hole.
    def edit(dxf):
        x0, y0, x1, y1 = dxf.bbox("slice_002")
        dxf.add_circle("slice_002", (x0 + x1) / 2, (y0 + y1) / 2, 2.0)
    holes = result_of(mutated(tmp_path, "stacked__torus", edit))["BISCUITS-IN-MATERIAL"]
    assert not holes.passed
    assert [v.detail for v in holes.violations] == ["centre is not in the part's material"]


def test_biscuit_hole_touching_the_edge_fails(tmp_path) -> None:
    def edit(dxf):
        x0, y0, x1, y1 = dxf.bbox("slice_001")
        dxf.add_circle("slice_001", x0 + 2.0, (y0 + y1) / 2, 2.0)  # rim on the edge, nothing between
    holes = result_of(mutated(tmp_path, "stacked__cube", edit))["BISCUITS-IN-MATERIAL"]
    assert not holes.passed
    assert [v.where for v in holes.violations] == ["slice_001@circle1"]
    assert "touches the material edge" in holes.violations[0].detail


def push_holes_toward_the_edge(dxf: Dxf, past: float) -> int:
    """Move each hole cut into a part straight toward the nearest point of
    the part's outline until it reaches that outline, then `past` mm on.
    Returns the number of holes moved."""
    def ends(e):
        v = {c.strip(): float(x) for c, x in e if c.strip() in ("10", "20", "11", "21")}
        return (v["10"], v["20"]), (v["11"], v["21"])

    def key(p) -> tuple[int, int]:
        return round(p[0] * 1e4), round(p[1] * 1e4)

    layout = cut_invariants.build_layout(cut_invariants.DxfEntities(lines=_lines(dxf)))
    moved = 0
    for part in layout.parts:
        outline = [tuple(q) for q in part.outline]
        for hole in part.holes:
            best = None
            for p in hole:
                for a, b in zip(outline, outline[1:] + outline[:1]):
                    ab = (b[0] - a[0], b[1] - a[1])
                    t = max(0.0, min(1.0, ((p[0] - a[0]) * ab[0] + (p[1] - a[1]) * ab[1]) / (ab[0] ** 2 + ab[1] ** 2)))
                    q = (a[0] + t * ab[0], a[1] + t * ab[1])
                    d = ((q[0] - p[0]) ** 2 + (q[1] - p[1]) ** 2) ** 0.5
                    if best is None or d < best[0]:
                        best = (d, p, q)
            d, p, q = best
            step = (d + past) / d
            dx, dy = (q[0] - p[0]) * step, (q[1] - p[1]) * step
            corners = {key(v) for v in hole}
            for e in dxf.on_layer(part.layer):
                if e[0][1].strip() != "LINE" or not all(key(v) in corners for v in ends(e)):
                    continue
                for pair in e:
                    code = pair[0].strip()
                    if code in ("10", "11"):
                        pair[1] = f"{float(pair[1]) + dx:.6f}"
                    elif code in ("20", "21"):
                        pair[1] = f"{float(pair[1]) + dy:.6f}"
            moved += 1
    return moved


def _lines(dxf: Dxf) -> dict[str, list[tuple[float, float, float, float]]]:
    out: dict[str, list[tuple[float, float, float, float]]] = {}
    for e in dxf.entities:
        if e[0][1].strip() != "LINE":
            continue
        v = {c.strip(): float(x) for c, x in e if c.strip() in ("10", "20", "11", "21")}
        out.setdefault(Dxf.layer(e), []).append((v["10"], v["20"], v["11"], v["21"]))
    return out


@pytest.mark.parametrize("case", ["folded__cube", "folded__cube-diamond", "folded__cube-tongue", "folded__cube-rivet"])
def test_a_folded_hole_pushed_onto_its_edge_touches_it(tmp_path, case) -> None:
    # Slots sit on lugs, and pin and lacing holes inside the panel, a web of
    # material from the edge: with that material gone the hole touches it.
    moved = {}
    path = mutated(tmp_path, case, lambda dxf: moved.setdefault("n", push_holes_toward_the_edge(dxf, 0.0)))
    holes = result_of(path)["BISCUITS-IN-MATERIAL"]
    assert not holes.passed
    assert len(holes.violations) == moved["n"]
    assert all("touches the part outline" in v.detail for v in holes.violations), failing_places(holes)


# ---------------------------------------------------------------------------
# Folded Panels: the nets folded back up (PARTS-CLEAR, SLOTS-MATE)
# ---------------------------------------------------------------------------

def folded_result(path: Path, case: str, stock: float | None = None, frames: Path | None = None,
                  panels: int | None = None, mesh: Path | None = None) -> dict[str, cut_invariants.InvariantResult]:
    """The invariants of a Folded case, with its frames, stock and panels."""
    key = case.replace("__", "/", 1)
    result = cut_invariants.validate(
        path, mesh, contour=False, count_part_holes=True,
        part_frames=frames or CANDIDATES / case / "parts.frames.json",
        expected_joints=functional_gate.EXPECTED_JOINTS[key] if panels is None else panels,
        stock=functional_gate.case_thickness("folded", key.split("/", 1)[1]) if stock is None else stock)
    return {inv.name: inv for inv in result["invariants"]}


@pytest.mark.parametrize("case", ["folded__cube", "folded__cube-gear-3mm", "folded__pyramid-puzzle",
                                  "folded__chair-multitab", "folded__torus"])
def test_untouched_folded_nets_fold_up_clear(case) -> None:
    result = folded_result(candidate(case), case)
    for name in ("SLOTS-MATE", "PARTS-CLEAR"):
        assert result[name].passed, f"{case} {name}: {failing_places(result[name])}"


def test_a_folded_slot_pushed_off_its_lug_leaves_its_tab_in_material(tmp_path) -> None:
    # Half of each slot hanging off its lug: folded up, every tab lands in
    # the lug's material where its slot was.
    moved = {}
    path = mutated(tmp_path, "folded__cube", lambda dxf: moved.setdefault("n", push_holes_toward_the_edge(dxf, 2.5)))
    assert moved["n"] == 7
    result = folded_result(path, "folded__cube")
    clear = result["PARTS-CLEAR"]
    assert not clear.passed
    assert len(clear.violations) == 7, failing_places(clear)
    assert all("stock passes into each other" in v.detail for v in clear.violations)
    assert not result["BISCUITS-IN-MATERIAL"].passed


def test_a_net_folded_in_thicker_stock_than_it_was_cut_for_overlaps_at_every_seam() -> None:
    # The cube's net is cut back for 5 mm stock. In 6 mm stock each of the
    # seven seams the folds leave open overlaps by the extra millimetre.
    clear = folded_result(candidate("folded__cube"), "folded__cube", stock=6.0)["PARTS-CLEAR"]
    assert not clear.passed
    assert len(clear.violations) == 7, failing_places(clear)
    assert all(v.where.startswith("1/p") for v in clear.violations)


def test_folds_left_out_of_the_frames_are_checked_like_seams(tmp_path) -> None:
    # Two panels a fold joins are one bent piece; checked as separate panels
    # their stock overlaps at each of the cube net's five folds.
    frames = json.loads((CANDIDATES / "folded__cube" / "parts.frames.json").read_text())
    for net in frames["folds"]:
        net["hinges"] = []
    path = tmp_path / "parts.frames.json"
    path.write_text(json.dumps(frames))
    clear = folded_result(candidate("folded__cube"), "folded__cube", frames=path)["PARTS-CLEAR"]
    assert not clear.passed
    assert len(clear.violations) == 5, failing_places(clear)


def test_a_panel_missing_from_the_frames_fails_slots_mate(tmp_path) -> None:
    frames = json.loads((CANDIDATES / "folded__cube" / "parts.frames.json").read_text())
    frames["folds"][0]["panels"][2]["region"] = []
    frames["folds"][0]["panels"][2]["features"] = []
    path = tmp_path / "parts.frames.json"
    path.write_text(json.dumps(frames))
    mate = folded_result(candidate("folded__cube"), "folded__cube", frames=path)["SLOTS-MATE"]
    assert not mate.passed
    # The panel's tabs gone with it, its neighbours' slots hold nothing.
    assert [v.detail for v in mate.violations][0] == "5 panels, expected 6"


def net_material(case: str, layer: str = "1"):
    """The material of a Folded net as a shapely polygon (outline less
    holes), from the candidate's DXF."""
    shapely = pytest.importorskip("shapely")
    from shapely.geometry import Polygon
    part = next(p for p in cut_invariants.build_layout(cut_invariants.read_dxf(candidate(case))).parts if p.layer == layer)
    return shapely.make_valid(Polygon(part.outline, [h for h in part.holes]))


def redraw_layer(dxf: Dxf, layer: str, material) -> None:
    """Replace the layer's cuts with the outline and holes of `material`."""
    dxf.entities = [e for e in dxf.entities if not (Dxf.layer(e) == layer and e[0][1].strip() == "LINE")]
    polygons = [material] if material.geom_type == "Polygon" else list(material.geoms)
    for polygon in polygons:
        for ring in [polygon.exterior, *polygon.interiors]:
            pts = list(ring.coords)
            for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
                dxf.entities.append([["0", "LINE"], ["8", layer], ["10", f"{x0:.6f}"], ["20", f"{y0:.6f}"], ["30", "0.0"],
                                     ["11", f"{x1:.6f}"], ["21", f"{y1:.6f}"], ["31", "0.0"]])


def test_net_material_outside_its_panels_fails_parts_clear(tmp_path) -> None:
    # The cube's net grown 0.6 mm all round, its holes kept: every seam now
    # pushes 0.6 mm into the neighbouring panel's stock, but that material
    # lies outside every panel and feature the frames give, where the
    # fold-up check does not look. The net must lie inside its panels.
    from shapely.geometry import Polygon
    material = net_material("folded__cube")
    grown = Polygon(material.buffer(0.6, join_style=2).exterior.coords, [h.coords for h in material.interiors])
    path = mutated(tmp_path, "folded__cube", lambda dxf: redraw_layer(dxf, "1", grown))
    untouched = folded_result(candidate("folded__cube"), "folded__cube")["PARTS-CLEAR"]
    assert untouched.passed, failing_places(untouched)
    clear = folded_result(path, "folded__cube")["PARTS-CLEAR"]
    assert not clear.passed
    assert [v.where for v in clear.violations] == ["1"], failing_places(clear)
    assert "outside every panel and feature, up to 0." in clear.violations[0].detail


def test_tabs_cut_off_leave_their_slots_empty(tmp_path) -> None:
    # Cut every tab off the cube's net (the features that do not frame a
    # slot of their own panel): nothing collides, but folded up every one of
    # the seven slots holds nothing, and the lugs that carry them meet
    # nothing either.
    from shapely.geometry import Polygon
    from shapely.ops import unary_union
    frames = json.loads((CANDIDATES / "folded__cube" / "parts.frames.json").read_text())
    material = net_material("folded__cube")
    holes = [Polygon(h.coords) for h in material.interiors]
    tabs = []
    for panel in frames["folds"][0]["panels"]:
        region = Polygon(panel["region"])
        for feature in panel["features"]:
            beyond = Polygon(feature).difference(region)
            if not beyond.is_empty and all(beyond.distance(h) > 5.0 for h in holes if region.buffer(1e-6).contains(h)):
                tabs.append(beyond.buffer(0.05, join_style=2))
    assert len(tabs) == 7
    cut = material.difference(unary_union(tabs)).simplify(0.001)
    path = mutated(tmp_path, "folded__cube", lambda dxf: redraw_layer(dxf, "1", cut))
    result = folded_result(path, "folded__cube")
    mate = result["SLOTS-MATE"]
    assert not mate.passed
    slots = [v for v in mate.violations if "no other panel passes through this slot hole" in v.detail]
    lugs = [v for v in mate.violations if "meets no other panel" in v.detail]
    assert len(slots) == 7 and len(lugs) == 7 and len(mate.violations) == 14, failing_places(mate)
    assert result["PARTS-CLEAR"].passed, failing_places(result["PARTS-CLEAR"])


def test_features_left_out_of_the_frames_leave_their_material_and_slots_unchecked(tmp_path) -> None:
    # Panel 2's two tabs missing from the frames: their material lies outside
    # every panel (PARTS-CLEAR), so they no longer fill their slots and the
    # lugs that frame those slots meet nothing (SLOTS-MATE).
    frames = json.loads((CANDIDATES / "folded__cube" / "parts.frames.json").read_text())
    frames["folds"][0]["panels"][1]["features"] = []
    path = tmp_path / "parts.frames.json"
    path.write_text(json.dumps(frames))
    result = folded_result(candidate("folded__cube"), "folded__cube", frames=path)
    clear = result["PARTS-CLEAR"]
    assert not clear.passed and "outside every panel and feature" in clear.violations[0].detail, failing_places(clear)
    mate = result["SLOTS-MATE"]
    details = [v.detail for v in mate.violations]
    assert any("no other panel passes through this slot hole" in d for d in details), failing_places(mate)
    assert any("meets no other panel" in d for d in details), failing_places(mate)


def test_laced_holes_may_hold_nothing() -> None:
    # Lacing holes are for a cord: checked as slots, they hold nothing.
    laced = folded_result(candidate("folded__cube-laced"), "folded__cube-laced")["SLOTS-MATE"]
    assert not laced.passed
    assert all("no other panel passes through this slot hole" in v.detail for v in laced.violations)
    case = functional_gate.case_checks("folded", "cube-laced", base=CANDIDATES)
    assert case["folded_holes_hold_joints"] is False
    result = cut_invariants.validate(candidate("folded__cube-laced"), None, contour=False, **case)
    assert next(i for i in result["invariants"] if i.name == "SLOTS-MATE").passed


def test_frames_without_the_folded_nets_fail_slots_mate(tmp_path) -> None:
    frames = json.loads((CANDIDATES / "folded__cube" / "parts.frames.json").read_text())
    del frames["folds"]
    path = tmp_path / "parts.frames.json"
    path.write_text(json.dumps(frames))
    mate = folded_result(candidate("folded__cube"), "folded__cube", frames=path,
                         mesh=REPO / "tests/fixtures/primitives/cube_50mm_binary.stl")["SLOTS-MATE"]
    assert not mate.passed


# ---------------------------------------------------------------------------
# VALIDITY
# ---------------------------------------------------------------------------

def test_outline_left_open_fails_validity(tmp_path) -> None:
    validity = result_of(mutated(tmp_path, "interlocked__cube", lambda dxf: dxf.drop_first_line("X-3")))["VALIDITY"]
    assert not validity.passed
    assert any(v.where == "X-3" and "open cut path" in v.detail for v in validity.violations), failing_places(validity)


def test_two_pieces_cut_as_one_figure_of_eight_fail_validity_and_part_count(tmp_path) -> None:
    """stacked/corner-blocks: each section is two pieces meeting at a
    corner. Written as one loop that crosses over there (as the sections
    were cut before they were split), each slice pinches."""
    case = "stacked__corner-blocks"
    checks = functional_gate.case_checks("stacked", "corner-blocks")
    assert all(inv.passed for inv in result_of(candidate(case), **checks).values())

    def as_one_loop(dxf: Dxf) -> None:
        # Each slice's two loops, joined into one figure of eight at the
        # corner they share.
        for layer in sorted({Dxf.layer(e) for e in dxf.entities if Dxf.layer(e).startswith("slice_")}):
            lines = [e for e in dxf.on_layer(layer) if e[0][1].strip() == "LINE"]
            segs = [tuple(float(next(v for c, v in e if c.strip() == k)) for k in ("10", "20", "11", "21")) for e in lines]
            loops, _ = cut_invariants.chain_segments(segs)
            assert len(loops) == 2
            a, b = (np.asarray(l) for l in loops)
            shared = min(((i, j) for i in range(len(a)) for j in range(len(b))),
                         key=lambda ij: float(np.hypot(*(a[ij[0]] - b[ij[1]]))))
            # Start one past the corner, so the outline runs through it
            # twice: round the first piece to the corner, round the second
            # back to it, and on.
            joined = np.vstack([np.roll(a, -(shared[0] + 1), axis=0), np.roll(b, -(shared[1] + 1), axis=0)])
            for e in lines:
                dxf.entities.remove(e)
            for k in range(len(joined)):
                p, q = joined[k], joined[(k + 1) % len(joined)]
                dxf.entities.append([["0", "LINE"], ["8", layer], ["10", f"{p[0]:.6f}"], ["20", f"{p[1]:.6f}"],
                                     ["30", "0.000000"], ["11", f"{q[0]:.6f}"], ["21", f"{q[1]:.6f}"],
                                     ["31", "0.000000"]])

    results = result_of(mutated(tmp_path, case, as_one_loop), **checks)
    assert not results["VALIDITY"].passed
    assert any("pinches" in v.detail for v in results["VALIDITY"].violations), failing_places(results["VALIDITY"])
    assert not results["PART-COUNT"].passed


# ---------------------------------------------------------------------------
# MATERIAL-IN-MODEL
# ---------------------------------------------------------------------------

def _hole_lines_removed(case: str, layer: str):
    """An edit that drops the lines of the hole in `layer`'s part (the
    torus's hole, its largest): the ring cut solid."""
    part = next(p for p in cut_invariants.build_layout(cut_invariants.read_dxf(candidate(case))).parts
                if p.layer == layer)
    hole = max(part.holes, key=lambda h: abs(cut_invariants.polygon_area(h)))
    corners = {(round(float(x), 4), round(float(y), 4)) for x, y in hole}

    def edit(dxf: Dxf) -> None:
        for e in [e for e in dxf.on_layer(layer) if e[0][1].strip() == "LINE"]:
            ends = [(round(float(next(v for c, v in e if c.strip() == a)), 4),
                     round(float(next(v for c, v in e if c.strip() == b)), 4))
                    for a, b in (("10", "20"), ("11", "21"))]
            if all(end in corners for end in ends):
                dxf.entities.remove(e)
    return edit


@pytest.mark.parametrize("case,layer", [("radial__torus", "first_axis_002"),
                                        ("radial__torus-mixed-winding", "first_axis_002"),
                                        ("radial__torus-inverted", "first_axis_002"),
                                        ("curve__torus-mixed-winding", "Z-1"),
                                        ("curve__torus-inverted-5mm", "Z-1")])
def test_a_torus_ring_cut_solid_fails_material_in_model(tmp_path, case, layer) -> None:
    """A ring or rib that keeps the torus's hole passes; with the hole cut
    solid (as a loop turned the wrong way leaves it) its material lies up
    to 20 mm outside the model."""
    mode, label = case.split("__")
    fixture = functional_gate.CASE_FIXTURE[f"{mode}/{label}"]
    checks = functional_gate.case_checks(mode, label, base=CANDIDATES)
    assert checks["material_in_model"]
    mesh = functional_gate.case_mesh(fixture)
    untouched = cut_invariants.validate(candidate(case), mesh, contour=False, **checks)
    assert all(inv.passed for inv in untouched["invariants"]), case

    out = mutated(tmp_path, case, _hole_lines_removed(case, layer))
    shutil.copy(functional_gate.frames_path(CANDIDATES, mode, label), out.parent / "parts.frames.json")
    checks = functional_gate.case_checks(mode, label, base=tmp_path)
    result = {inv.name: inv for inv in cut_invariants.validate(out, mesh, contour=False, **checks)["invariants"]}
    material = result["MATERIAL-IN-MODEL"]
    assert not material.passed
    assert any(v.where == layer for v in material.violations), failing_places(material)
    assert material.worst_value > 15


def test_material_in_model_is_armed_for_radial_and_curve_on_closed_meshes() -> None:
    for (mode, fixture, label, _axis) in functional_gate.CASES:
        armed = functional_gate.case_checks(mode, label, base=CANDIDATES).get("material_in_model", False)
        assert armed == (mode in ("radial", "curve") and fixture not in functional_gate.OPEN_MESHES), f"{mode}/{label}"


# ---------------------------------------------------------------------------
# The gate itself
# ---------------------------------------------------------------------------

def test_gate_exits_non_zero_on_a_mutated_candidate(tmp_path) -> None:
    base = tmp_path / "candidates"
    shutil.copytree(CANDIDATES, base, ignore=shutil.ignore_patterns("functional_gate.json", "*.md"))
    Dxf(candidate("stacked__cube")).write(base / "stacked__cube" / "parts.dxf")
    assert functional_gate.run(base, tol_mm=0.3, contour=False) == 0

    dxf = Dxf(candidate("stacked__cube"))
    dxf.move("slice_003", 600.0, 0.0)
    dxf.write(base / "stacked__cube" / "parts.dxf")
    assert functional_gate.run(base, tol_mm=0.3, contour=False) == 1


@pytest.mark.parametrize("case", sorted(p.name for p in CANDIDATES.iterdir() if p.is_dir()))
def test_ezdxf_reads_the_same_entities(case) -> None:
    """An independent DXF reader sees the same LINEs and CIRCLEs per layer."""
    ezdxf = pytest.importorskip("ezdxf")
    doc = ezdxf.readfile(candidate(case))
    counts: dict[tuple[str, str], int] = {}
    for e in doc.modelspace():
        if e.dxftype() in ("LINE", "CIRCLE"):
            key = (e.dxftype(), e.dxf.layer)
            counts[key] = counts.get(key, 0) + 1
    ours = cut_invariants.read_dxf(candidate(case))
    mine = {("LINE", k): len(v) for k, v in ours.lines.items()}
    mine.update({("CIRCLE", k): len(v) for k, v in ours.circles.items()})
    assert counts == mine
