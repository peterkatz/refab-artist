#!/usr/bin/env python3
"""Organic hand-model geometry gate for real radial/interlocked/curve failures.

The generic assembly gate is necessary but not sufficient: it can pass while
organic exports contain named parts with zero faces, unsupported floating radial
first-axis slices, interlocked/curve cut sheets with severed parts, or radial fin
outlines that leave the actual shrinkwrapped mesh. This script exercises the same
CLI paths the app uses and checks those geometry facts directly.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

REPO = Path(__file__).resolve().parent.parent
# The hand scans are committed with the app's test fixtures.
HAND_ROOT = REPO / "app/RefabArtist/Tests/Fixtures/hand-scans"
# The older, large hand scan (an 82 MB STL) is not part of the repository: the
# --include-slow case runs only when REFAB_HANDSTAND3_STL names a copy of it.
LARGE_HAND_STL_VARIABLE = "REFAB_HANDSTAND3_STL"


@dataclass(frozen=True)
class Case:
    label: str
    fixture: Path
    mode: str
    export_args: tuple[str, ...]
    audit_args: tuple[str, ...] = ()
    assembly_args: tuple[str, ...] = ()
    signed_distance: bool = False
    skip_hint: str = ""


CASES = (
    Case(
        label="handStand_ex3_radial_shrinkwrap",
        fixture=HAND_ROOT / "handStand_ex3.obj",
        mode="radial",
        export_args=("--shrinkwrap", "0.5", "--n-radial", "6", "--slice-count", "10"),
        audit_args=("--shrinkwrap", "--n-radial", "6", "--first-axis-count", "10"),
        signed_distance=True,
    ),
    Case(
        label="handStand_ex3_interlocked_yup_shrinkwrap",
        fixture=HAND_ROOT / "handStand_ex3.obj",
        mode="interlocked",
        export_args=("--import-up-axis", "y", "--thickness", "3", "--shrinkwrap", "0.5"),
        assembly_args=("--import-up-axis", "y", "--thickness", "3", "--shrinkwrap", "0.5"),
    ),
    Case(
        label="handStand_ex3_curve_yup_shrinkwrap",
        fixture=HAND_ROOT / "handStand_ex3.obj",
        mode="curve",
        export_args=("--import-up-axis", "y", "--thickness", "3", "--shrinkwrap", "0.5"),
        assembly_args=("--import-up-axis", "y", "--thickness", "3", "--shrinkwrap", "0.5"),
    ),
)

SLOW_CASES = (
    Case(
        label="handStand3_radial_import_y",
        fixture=Path(os.environ.get(LARGE_HAND_STL_VARIABLE) or "handStand3.stl"),
        mode="radial",
        export_args=("--import-up-axis", "y", "--n-radial", "6", "--slice-count", "10"),
        skip_hint=f"set {LARGE_HAND_STL_VARIABLE}=<path to handStand3.stl> to run it",
    ),
)


def find_binary() -> Path:
    for configuration in ("debug", "release"):
        binary = REPO / f"app/RefabArtist/.build/arm64-apple-macosx/{configuration}/RefabArtist"
        if binary.exists():
            return binary
    sys.exit("No built RefabArtist binary; run: swift build --package-path app/RefabArtist")


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, cwd=REPO, text=True, capture_output=True)
    if result.returncode != 0:
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(command)}")
    return result


@dataclass
class ObjGroup:
    name: str
    faces: int
    indices: set[int]
    bbox: tuple[float, float, float, float, float, float] | None = None
    face_indices: list[tuple[int, int, int]] | None = None
    mesh: Any | None = None
    samples: Any | None = None


def parse_obj_groups(path: Path) -> list[ObjGroup]:
    import numpy as np
    import trimesh

    vertices: list[tuple[float, float, float] | None] = [None]
    groups: list[ObjGroup] = []
    current: ObjGroup | None = None

    for line in path.read_text(errors="ignore").splitlines():
        if line.startswith("o "):
            current = ObjGroup(name=line[2:].strip(), faces=0, indices=set(), face_indices=[])
            groups.append(current)
        elif line.startswith("v "):
            parts = line.split()
            if len(parts) >= 4:
                vertices.append((float(parts[1]), float(parts[2]), float(parts[3])))
        elif line.startswith("f ") and current is not None:
            raw_indices: list[int] = []
            for token in line.split()[1:]:
                index = int(token.split("/")[0])
                if index < 0:
                    index = len(vertices) + index
                current.indices.add(index)
                raw_indices.append(index)
            if len(raw_indices) >= 3:
                assert current.face_indices is not None
                for offset in range(1, len(raw_indices) - 1):
                    current.face_indices.append((raw_indices[0], raw_indices[offset], raw_indices[offset + 1]))
                    current.faces += 1

    for group in groups:
        points = [vertices[index] for index in group.indices if 0 < index < len(vertices)]
        points = [point for point in points if point is not None]
        if not points:
            continue
        xs = [point[0] for point in points]
        ys = [point[1] for point in points]
        zs = [point[2] for point in points]
        group.bbox = (min(xs), min(ys), min(zs), max(xs), max(ys), max(zs))
        index_map: dict[int, int] = {}
        local_vertices: list[tuple[float, float, float]] = []
        local_faces: list[tuple[int, int, int]] = []
        for face in group.face_indices or []:
            local_face: list[int] = []
            for index in face:
                if index not in index_map:
                    point = vertices[index] if 0 < index < len(vertices) else None
                    if point is None:
                        break
                    index_map[index] = len(local_vertices)
                    local_vertices.append(point)
                local_face.append(index_map[index])
            if len(local_face) == 3:
                local_faces.append((local_face[0], local_face[1], local_face[2]))
        if local_vertices and local_faces:
            group.mesh = trimesh.Trimesh(
                vertices=np.asarray(local_vertices, dtype=float),
                faces=np.asarray(local_faces, dtype=int),
                process=False,
            )
    return groups


def boxes_overlap(
    a: tuple[float, float, float, float, float, float],
    b: tuple[float, float, float, float, float, float],
    tolerance: float,
) -> bool:
    return (
        a[0] <= b[3] + tolerance and b[0] <= a[3] + tolerance
        and a[1] <= b[4] + tolerance and b[1] <= a[4] + tolerance
        and a[2] <= b[5] + tolerance and b[2] <= a[5] + tolerance
    )


def sample_points(group: ObjGroup, max_points: int = 2500):
    import numpy as np

    if group.samples is not None:
        return group.samples
    if group.mesh is None:
        group.samples = np.empty((0, 3), dtype=float)
        return group.samples
    mesh = group.mesh
    vertices = np.asarray(mesh.vertices, dtype=float)
    triangles = np.asarray(mesh.triangles, dtype=float)
    centers = triangles.mean(axis=1) if len(triangles) else np.empty((0, 3), dtype=float)
    points = np.vstack([vertices, centers]) if len(centers) else vertices
    if len(points) > max_points:
        indices = np.linspace(0, len(points) - 1, max_points).astype(int)
        points = points[indices]
    group.samples = points
    return points


def meshes_touch(lhs: ObjGroup, rhs: ObjGroup, tolerance: float) -> bool:
    if lhs.bbox is None or rhs.bbox is None:
        return False
    if not boxes_overlap(lhs.bbox, rhs.bbox, tolerance):
        return False
    if lhs.mesh is None or rhs.mesh is None:
        return False

    import numpy as np
    from trimesh.proximity import closest_point

    lhs_samples = sample_points(lhs)
    rhs_samples = sample_points(rhs)
    if len(lhs_samples) == 0 or len(rhs_samples) == 0:
        return False

    try:
        _, lhs_to_rhs, _ = closest_point(rhs.mesh, lhs_samples)
        if len(lhs_to_rhs) and float(np.min(lhs_to_rhs)) <= tolerance:
            return True
        _, rhs_to_lhs, _ = closest_point(lhs.mesh, rhs_samples)
        if len(rhs_to_lhs) and float(np.min(rhs_to_lhs)) <= tolerance:
            return True
    except Exception as exc:
        raise RuntimeError(f"exact mesh contact check failed for {lhs.name} / {rhs.name}: {exc}") from exc
    return False


def contact_adjacency(nonempty: list[ObjGroup], tolerance: float) -> list[list[int]]:
    adjacency: list[list[int]] = [[] for _ in nonempty]
    for i, lhs in enumerate(nonempty):
        for j in range(i + 1, len(nonempty)):
            rhs = nonempty[j]
            if meshes_touch(lhs, rhs, tolerance):
                adjacency[i].append(j)
                adjacency[j].append(i)
    return adjacency


def unsupported_first_axis(groups: Iterable[ObjGroup], adjacency: list[list[int]], tolerance: float) -> list[str]:
    nonempty = [group for group in groups if group.faces > 0 and group.bbox is not None]
    first_axis = [group for group in nonempty if group.name.startswith("first_axis_")]
    radial_indices = {index for index, group in enumerate(nonempty) if group.name.startswith("radial_")}
    unsupported: list[str] = []
    for first in first_axis:
        index = nonempty.index(first)
        if not any(neighbor in radial_indices for neighbor in adjacency[index]):
            unsupported.append(first.name)
    return unsupported


def disconnected_components(groups: Iterable[ObjGroup], adjacency: list[list[int]], tolerance: float) -> list[list[str]]:
    nonempty = [group for group in groups if group.faces > 0 and group.bbox is not None]
    if len(nonempty) <= 1:
        return []

    seen: set[int] = set()
    components: list[list[int]] = []
    for start in range(len(nonempty)):
        if start in seen:
            continue
        stack = [start]
        seen.add(start)
        component: list[int] = []
        while stack:
            current = stack.pop()
            component.append(current)
            for neighbor in adjacency[current]:
                if neighbor not in seen:
                    seen.add(neighbor)
                    stack.append(neighbor)
        components.append(component)

    if len(components) <= 1:
        return []
    components.sort(key=len, reverse=True)
    return [[nonempty[index].name for index in component] for component in components]


def part_outline_points(path: Path) -> dict[str, list[list[float]]]:
    objects: dict[str, list[list[float]]] = {}
    current: str | None = None
    for line in path.read_text(errors="ignore").splitlines():
        if line.startswith("o "):
            current = line[2:].strip()
            objects[current] = []
        elif line.startswith("v ") and current is not None:
            objects[current].append([float(value) for value in line.split()[1:4]])
    return objects


def signed_distance_failures(mesh_path: Path, parts_path: Path, tolerance: float) -> list[str]:
    try:
        import numpy as np
        import trimesh
        from trimesh.proximity import signed_distance
    except Exception as exc:  # pragma: no cover - dependency is local-machine only
        raise RuntimeError(f"trimesh signed-distance dependencies unavailable: {exc}") from exc

    mesh = trimesh.load(mesh_path, process=False)
    if not getattr(mesh, "is_watertight", False):
        raise RuntimeError(f"signed-distance mesh is not watertight: {mesh_path}")

    failures: list[str] = []
    for name, points in part_outline_points(parts_path).items():
        if not name.startswith("fin_") or not points:
            continue
        distances = signed_distance(mesh, np.asarray(points, dtype=float))
        worst = float(distances.min())
        if worst < -tolerance:
            failures.append(f"{name} outside by {-worst:.2f} mm")
    return failures


def run_case(binary: Path, case: Case, tmp: Path, tolerance: float, connection_tolerance: float) -> bool:
    if not case.fixture.exists():
        hint = f" ({case.skip_hint})" if case.skip_hint else ""
        print(f"{case.label}: SKIP missing fixture {case.fixture}{hint}")
        return True

    obj_path = tmp / f"{case.label}.obj"
    mesh_path = tmp / f"{case.label}-mesh.obj"
    command = [
        str(binary),
        "--headless-export",
        "--fixture",
        str(case.fixture),
        "--mode",
        case.mode,
        "--format",
        "obj",
        "--output",
        str(obj_path),
        "--dump-mesh",
        str(mesh_path),
        *case.export_args,
    ]
    run(command)

    groups = parse_obj_groups(obj_path)
    empty = [group.name for group in groups if group.faces == 0]
    nonempty = [group for group in groups if group.faces > 0 and group.bbox is not None]
    adjacency = contact_adjacency(nonempty, tolerance=connection_tolerance)
    unsupported = unsupported_first_axis(groups, adjacency=adjacency, tolerance=connection_tolerance) if case.mode == "radial" else []
    disconnected = disconnected_components(groups, adjacency=adjacency, tolerance=connection_tolerance)

    assembly_errors: list[str] = []
    if case.assembly_args:
        audit_command = [
            str(binary),
            "--assembly-audit",
            "--fixture",
            str(case.fixture),
            "--mode",
            case.mode,
            *case.assembly_args,
        ]
        audit = json.loads(run(audit_command).stdout)
        if not audit.get("assemblable", False):
            assembly_errors.append(
                "assembly audit failed "
                f"severed={audit.get('severed')} detached={audit.get('detached')} overflow={audit.get('overflow')} "
                f"severedLabels={audit.get('severedLabels')}"
            )

    signed_distance_errors: list[str] = []
    if case.signed_distance:
        parts_path = tmp / f"{case.label}-parts.obj"
        audit_command = [
            str(binary),
            "--radial-audit",
            "--fixture",
            str(case.fixture),
            "--dump-parts",
            str(parts_path),
            *case.audit_args,
        ]
        run(audit_command)
        signed_distance_errors = signed_distance_failures(mesh_path, parts_path, tolerance=tolerance)

    first_axis_count = len([group for group in groups if group.faces > 0 and group.name.startswith("first_axis_")])
    radial_part_count = len([group for group in groups if group.faces > 0 and group.name.startswith("radial_")])
    mode_detail = f"first_axis={first_axis_count} radial_parts={radial_part_count}" if case.mode == "radial" else f"mode={case.mode}"
    print(f"{case.label}: groups={len(groups)} nonempty={sum(group.faces > 0 for group in groups)} {mode_detail}")

    failed = False
    if empty:
        failed = True
        print(f"  FAIL empty mesh groups ({len(empty)}): {', '.join(empty[:12])}{' ...' if len(empty) > 12 else ''}")
    if unsupported:
        failed = True
        print(f"  FAIL unsupported first-axis parts: {', '.join(unsupported)}")
    if disconnected:
        failed = True
        summaries = [
            f"{len(component)} parts [{', '.join(component[:6])}{' ...' if len(component) > 6 else ''}]"
            for component in disconnected
        ]
        print(f"  FAIL disconnected assembly components: {'; '.join(summaries)}")
    if assembly_errors:
        failed = True
        print(f"  FAIL {'; '.join(assembly_errors)}")
    if signed_distance_errors:
        failed = True
        print(f"  FAIL radial outlines leave mesh: {', '.join(signed_distance_errors)}")
    if not failed:
        print("  PASS")
    return not failed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="Keep temporary OBJ/JSON outputs")
    parser.add_argument("--include-slow", action="store_true", help="Also run the older large handStand3 STL case")
    parser.add_argument("--outside-tolerance-mm", type=float, default=1.0)
    parser.add_argument("--connection-tolerance-mm", type=float, default=1.0)
    args = parser.parse_args()

    binary = find_binary()
    with tempfile.TemporaryDirectory(prefix="refabartist_radial_gate_") as temp_name:
        temp = Path(temp_name)
        ok = True
        cases = CASES + (SLOW_CASES if args.include_slow else ())
        for case in cases:
            ok = run_case(
                binary,
                case,
                temp,
                tolerance=args.outside_tolerance_mm,
                connection_tolerance=args.connection_tolerance_mm,
            ) and ok
        if args.keep:
            keep_path = Path("/tmp") / temp.name
            import shutil

            shutil.copytree(temp, keep_path, dirs_exist_ok=True)
            print(f"kept outputs: {keep_path}")
        return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
