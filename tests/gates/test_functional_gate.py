"""Guard for the functional-correctness gate.

Runs the committed candidates (`tests/fixtures/functional-gate/`, the DXF
each case exports) through the gated invariants without a Swift build.
`scripts/functional_gate.py --generate` checks a fresh export from the built
app the same way.

If this test fails, a gated invariant (fits / overlap / validity / holes in
material / counts / joints) regressed on a case beyond its known-defect entry, or a known
defect was fixed and its entry should go.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from scripts import functional_gate  # noqa: E402
from tools.gates import cut_invariants  # noqa: E402

CANDIDATES = REPO / "tests/fixtures/functional-gate"

# Every case needs a committed candidate.
_CASES = [
    pytest.param(mode, fixture, label, axis, id=f"{mode}-{label}")
    for (mode, fixture, label, axis) in functional_gate.CASES
]


def test_every_case_has_a_committed_candidate() -> None:
    missing = [
        f"{mode}/{label}"
        for (mode, _fixture, label, _axis) in functional_gate.CASES
        if not functional_gate.candidate_path(CANDIDATES, mode, label).exists()
    ]
    assert not missing, (
        f"Missing functional-gate candidates under {CANDIDATES}: {missing}. "
        "Regenerate with: swift build --package-path app/RefabArtist && "
        "python3 scripts/functional_gate.py --generate"
    )


@pytest.mark.parametrize("mode,fixture,label,axis", _CASES)
def test_cuttability_invariants(mode, fixture, label, axis) -> None:
    key = f"{mode}/{label}"
    cand = functional_gate.candidate_path(CANDIDATES, mode, label)
    result = cut_invariants.validate(cand, functional_gate.case_mesh(fixture), axis, contour=False,
                                     **functional_gate.case_checks(mode, label, base=CANDIDATES))
    by_name = {inv.name: inv for inv in result["invariants"]}

    failed = {n for n in functional_gate.GATED if not by_name[n].passed}
    known = set(functional_gate.KNOWN_DEFECTS.get(key, ((), ""))[0])
    assert failed <= known, f"{key} regressed gated invariants: {sorted(failed - known)}"
    assert failed == known, f"{key} no longer fails {sorted(known - failed)}: remove its KNOWN_DEFECTS entry"
    assert result["n_parts"] > 0


def test_every_case_has_an_expected_part_count() -> None:
    keys = {f"{mode}/{label}" for (mode, _f, label, _a) in functional_gate.CASES}
    assert keys == set(functional_gate.EXPECTED_PARTS)


def test_every_jointed_case_has_an_expected_slot_count() -> None:
    """Slotted and Folded Panels cases pin their slots, so parts that should
    interlock but lose their slots fail SLOT-COUNT."""
    keys = {f"{mode}/{label}" for (mode, _f, label, _a) in functional_gate.CASES
            if mode in functional_gate.SLOTTED_MODES | {"folded"}}
    assert keys == set(functional_gate.EXPECTED_SLOTS)


def test_every_radial_folded_and_curve_case_checks_its_joints_against_committed_frames() -> None:
    """Radial and Curve parts are put back in the model, and Folded Panels
    nets folded up, from the frames their export writes."""
    for (mode, _f, label, _a) in functional_gate.CASES:
        if mode not in ("radial", "folded", "curve"):
            continue
        assert f"{mode}/{label}" in functional_gate.EXPECTED_JOINTS
        assert functional_gate.frames_path(CANDIDATES, mode, label).is_file()


def test_known_defects_name_gated_invariants_and_real_cases() -> None:
    keys = {f"{mode}/{label}" for (mode, _f, label, _a) in functional_gate.CASES}
    for key, (names, why) in functional_gate.KNOWN_DEFECTS.items():
        assert key in keys, key
        assert names and set(names) <= set(functional_gate.GATED), key
        assert why.strip(), key


def test_gate_exit_code_clean() -> None:
    """The whole gate returns 0 over the committed candidates."""
    assert functional_gate.run(CANDIDATES, tol_mm=0.3, contour=False) == 0
