#!/usr/bin/env python3
"""Audit exported MotherMold parts with trimesh and manifold3d."""

from __future__ import annotations

import argparse
import hashlib
import json
import tempfile
import warnings
import zipfile
from itertools import combinations
from pathlib import Path

import numpy as np
import trimesh


def load_mesh(path: Path) -> trimesh.Trimesh:
    loaded = trimesh.load(path, force="mesh", process=True)
    if isinstance(loaded, trimesh.Scene):
        loaded = loaded.to_geometry()
    if not isinstance(loaded, trimesh.Trimesh):
        raise RuntimeError(f"{path} did not load as a triangle mesh")
    loaded.remove_unreferenced_vertices()
    return loaded


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def mesh_metrics(name: str, mesh: trimesh.Trimesh) -> dict[str, object]:
    components = list(mesh.split(only_watertight=False))
    euler = int(mesh.euler_number)
    watertight = bool(mesh.is_watertight)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        volume_cc = float(abs(mesh.volume) / 1000.0)
    genus = None
    if watertight and len(components) == 1:
        candidate = (2 - euler) / 2
        if abs(candidate - round(candidate)) < 1.0e-6:
            genus = int(round(candidate))
    return {
        "name": name,
        "triangle_count": int(len(mesh.faces)),
        "vertex_count": int(len(mesh.vertices)),
        "component_count": len(components),
        "watertight": watertight,
        "winding_consistent": bool(mesh.is_winding_consistent),
        "is_volume": bool(mesh.is_volume),
        "euler": euler,
        "genus": genus,
        "volume_cc": volume_cc,
        "bounds": np.asarray(mesh.bounds, dtype=float).tolist(),
    }


def pairwise_overlaps(parts: list[tuple[str, trimesh.Trimesh]]) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for (left_name, left), (right_name, right) in combinations(parts, 2):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            overlap = trimesh.boolean.intersection(
                [left, right],
                engine="manifold",
                check_volume=False,
            )
            volume = 0.0 if overlap is None or overlap.is_empty else abs(float(overlap.volume))
        rows.append({
            "parts": [left_name, right_name],
            "overlap_mm3": volume,
        })
    return rows


def write_section(parts: list[trimesh.Trimesh], destination: Path) -> None:
    all_vertices = np.vstack([mesh.vertices for mesh in parts])
    max_z = float(all_vertices[:, 2].max())
    top = all_vertices[all_vertices[:, 2] >= max_z - 0.25]
    center_x = float(top[:, 0].mean())
    half_width = 0.5
    sections: list[trimesh.Trimesh] = []
    for mesh in parts:
        # Keep a thin open slab through the topmost feature centroid. A half-
        # section leaves the far cavity wall in view and visually hides the
        # funnel throat; the slab exposes the channel and floor honestly.
        section = mesh.slice_plane(
            np.array([center_x - half_width, 0.0, 0.0]),
            np.array([1.0, 0.0, 0.0]),
            cap=False,
        )
        if section is not None and not section.is_empty:
            section = section.slice_plane(
                np.array([center_x + half_width, 0.0, 0.0]),
                np.array([-1.0, 0.0, 0.0]),
                cap=False,
            )
        if section is not None and not section.is_empty:
            sections.append(section)
    if not sections:
        raise RuntimeError("section plane removed every part")
    destination.parent.mkdir(parents=True, exist_ok=True)
    trimesh.util.concatenate(sections).export(destination)


def audit(args: argparse.Namespace) -> dict[str, object]:
    zip_path = Path(args.parts_zip).resolve()
    with tempfile.TemporaryDirectory(prefix="mothermold-audit-") as temp_dir:
        temp = Path(temp_dir)
        with zipfile.ZipFile(zip_path) as archive:
            stl_names = sorted(name for name in archive.namelist() if name.lower().endswith(".stl"))
            if not stl_names:
                raise RuntimeError(f"{zip_path} contains no STL parts")
            part_paths: list[Path] = []
            for index, member in enumerate(stl_names):
                path = temp / f"{index:02d}-{Path(member).name}"
                path.write_bytes(archive.read(member))
                part_paths.append(path)

        parts = [(Path(name).stem, load_mesh(path)) for name, path in zip(stl_names, part_paths)]
        metrics = [mesh_metrics(name, mesh) for name, mesh in parts]
        overlaps = pairwise_overlaps(parts)
        combined = trimesh.util.concatenate([mesh for _, mesh in parts])

        if args.assembled_stl:
            assembled_path = Path(args.assembled_stl)
            assembled_path.parent.mkdir(parents=True, exist_ok=True)
            combined.export(assembled_path)
        if args.section_stl:
            write_section([mesh for _, mesh in parts], Path(args.section_stl))

        result: dict[str, object] = {
            "parts_zip": str(zip_path),
            "parts_zip_sha256": sha256(zip_path),
            "part_count": len(parts),
            "parts": metrics,
            "all_parts_single_component": all(row["component_count"] == 1 for row in metrics),
            "all_parts_watertight": all(row["watertight"] for row in metrics),
            "all_parts_winding_consistent": all(row["winding_consistent"] for row in metrics),
            "total_volume_cc": float(sum(float(row["volume_cc"]) for row in metrics)),
            "pairwise_overlaps": overlaps,
            "max_pairwise_overlap_mm3": max((float(row["overlap_mm3"]) for row in overlaps), default=0.0),
            "assembled": mesh_metrics("assembled", combined),
        }

        if args.laid_stl:
            laid_path = Path(args.laid_stl).resolve()
            laid = load_mesh(laid_path)
            result["laid_stl"] = str(laid_path)
            result["laid_stl_sha256"] = sha256(laid_path)
            result["laid"] = mesh_metrics("laid", laid)

        laid = result.get("laid")
        laid_ok = laid is None or (
            laid["component_count"] == len(parts)
            and laid["watertight"]
            and abs(float(laid["volume_cc"]) - float(result["total_volume_cc"]))
            <= max(0.01, float(result["total_volume_cc"]) * 0.0001)
        )
        result["max_allowed_overlap_mm3"] = args.max_overlap_mm3
        result["geometry_gate_passed"] = bool(
            result["all_parts_single_component"]
            and result["all_parts_watertight"]
            and result["all_parts_winding_consistent"]
            and float(result["max_pairwise_overlap_mm3"]) <= args.max_overlap_mm3
            and laid_ok
        )

        return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--parts-zip", required=True)
    parser.add_argument("--laid-stl")
    parser.add_argument("--assembled-stl")
    parser.add_argument("--section-stl")
    parser.add_argument("--max-overlap-mm3", type=float, default=0.01)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    result = audit(args)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({
        "part_count": result["part_count"],
        "all_parts_single_component": result["all_parts_single_component"],
        "all_parts_watertight": result["all_parts_watertight"],
        "geometry_gate_passed": result["geometry_gate_passed"],
        "max_pairwise_overlap_mm3": result["max_pairwise_overlap_mm3"],
        "total_volume_cc": result["total_volume_cc"],
    }, sort_keys=True))
    if not result["geometry_gate_passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
