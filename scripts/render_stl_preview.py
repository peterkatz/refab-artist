#!/usr/bin/env python3
"""Shaded STL preview for geometry gate screenshots.

Usage:
    python3 scripts/render_stl_preview.py <in.stl> <out.png> "<title>" [elev azim]

Handles binary AND ascii STL. Renders z-graded, light-shaded solid triangles —
unlike a bare scatter/wireframe dump, branching structure, merged trunks, and
surface tears are actually visible. Keep views deterministic: pass explicit
elev/azim (defaults 12 -60) so before/after screenshots are comparable.

NOT a substitute for the owner looking at the real app (that stays the final
gate) — this exists so run reports carry legible evidence instead of dust.
"""
import struct
import sys

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from mpl_toolkits.mplot3d.art3d import Poly3DCollection  # noqa: E402


def read_stl(path):
    with open(path, "rb") as f:
        head = f.read(5)
    if head == b"solid":
        # Could still be binary with a "solid" header; try ascii, fall back.
        try:
            return _read_ascii(path)
        except (ValueError, UnicodeDecodeError):
            pass
    return _read_binary(path)


def _read_ascii(path):
    verts = []
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            line = line.lstrip()
            if line.startswith("vertex"):
                parts = line.split()
                verts.append([float(parts[1]), float(parts[2]), float(parts[3])])
    if not verts or len(verts) % 3 != 0:
        raise ValueError("not a well-formed ascii STL")
    return np.array(verts, np.float32).reshape(-1, 3, 3)


def _read_binary(path):
    with open(path, "rb") as f:
        f.seek(80)
        (count,) = struct.unpack("<I", f.read(4))
        data = np.frombuffer(f.read(count * 50), dtype=np.uint8)
    if data.size != count * 50:
        raise ValueError("truncated binary STL")
    tris = data.reshape(count, 50)[:, 12:48].copy().view(np.float32)
    return tris.reshape(count, 3, 3)


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    src, out, title = sys.argv[1], sys.argv[2], sys.argv[3]
    elev = float(sys.argv[4]) if len(sys.argv) > 4 else 12.0
    azim = float(sys.argv[5]) if len(sys.argv) > 5 else -60.0

    tris = read_stl(src)
    fig = plt.figure(figsize=(9, 9))
    ax = fig.add_subplot(projection="3d")
    z = tris[:, :, 2].mean(axis=1)
    norm = (z - z.min()) / max(float(z.max() - z.min()), 1e-9)
    colors = plt.cm.copper(0.25 + 0.6 * norm)
    # NB: shade=True + edgecolors="none" crashes matplotlib's _shade_colors on
    # some versions; the z-graded facecolors already read as depth.
    pc = Poly3DCollection(tris, facecolors=colors, edgecolors="none")
    ax.add_collection3d(pc)
    lo, hi = tris.min(axis=(0, 1)), tris.max(axis=(0, 1))
    center, radius = (lo + hi) / 2, float((hi - lo).max()) / 2
    ax.set_xlim(center[0] - radius, center[0] + radius)
    ax.set_ylim(center[1] - radius, center[1] + radius)
    ax.set_zlim(center[2] - radius, center[2] + radius)
    ax.set_axis_off()
    ax.view_init(elev=elev, azim=azim)
    ax.set_title(f"{title}  [{tris.shape[0]} tris]")
    plt.tight_layout()
    plt.savefig(out, dpi=110)
    print(f"wrote {out} ({tris.shape[0]} triangles)")


if __name__ == "__main__":
    main()
