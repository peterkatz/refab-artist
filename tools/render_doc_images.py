#!/usr/bin/env python3
"""Draw the illustrations in docs/images from Refab Artist's own exports.

Nothing here needs the app window. The pictures come from the headless export
(`RefabArtist --headless-export`) and two small renderers in this file:

  * a cut sheet, drawn from the SVG the app writes (outlines blue, labels red,
    scored guides as the file draws them), and
  * an assembled model, drawn from the OBJ the app writes: every part where it
    sits in the finished model, flat shaded, with a z-buffer so interlocking
    parts hide each other correctly.

The pictures are illustrations of the exports, not screenshots of the app
window; the README says where screenshots can be added.

Usage (from the repository root, after `swift build -c release
--package-path app/RefabArtist`):
    python3 tools/render_doc_images.py all [--binary PATH] [--out docs/images]
        run every case in CASES and write <name>-sheet.png (the first sheet of
        the cut sheet) and <name>-assembled.png (the parts in place), where the
        mode has them, plus app-icon.png
    python3 tools/render_doc_images.py obj IN.obj OUT.png [--family-colors]
    python3 tools/render_doc_images.py svg IN.svg OUT.png

Needs numpy, Pillow and matplotlib (tools/requirements.txt). Output is
deterministic for a given export.
"""
from __future__ import annotations

import argparse
import math
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
DEFAULT_BINARY = REPO / "app/RefabArtist/.build/release/RefabArtist"
DEFAULT_OUT = REPO / "docs/images"

BACKGROUND = (244, 244, 246)

# Plywood-like tones. Two tones alternate along a family so neighbouring slices
# read as separate sheets; two-family modes use one pair per family.
PALETTE_A = [(226, 188, 138), (214, 170, 116)]
PALETTE_B = [(176, 112, 74), (160, 98, 62)]


# --------------------------------------------------------------------------
# Cases
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Case:
    name: str
    mode: str
    fixture: str
    args: tuple[str, ...] = ()
    elev: float = 26.0
    azim: float = 38.0
    families: bool = False  # colour the two part families differently
    sheet: bool = True  # the mode writes a cut sheet (3D Slices does not)
    assembled: bool = True  # the OBJ shows the parts in place (Folded writes its flat nets)


# One case per picture set. The fixtures are the project's own models
# (tests/fixtures/MANIFEST.md).
CASES: tuple[Case, ...] = (
    Case("stacked", "stacked", "tests/fixtures/primitives/sphere_d50mm.stl",
         ("--thickness", "3", "--axis", "z")),
    Case("interlocked", "interlocked", "tests/fixtures/real-world/simple_chair.stl",
         ("--thickness", "3", "--slot-clearance", "0.1", "--slice-count", "6"),
         families=True),
    Case("radial", "radial", "tests/fixtures/primitives/torus_R30_r10mm.stl",
         ("--thickness", "3", "--first-axis-count", "6", "--n-radial", "6"),
         elev=32.0, families=True),
    Case("curve", "curve", "tests/fixtures/organic/lumpy_blob.stl",
         ("--thickness", "3"), families=True),
    Case("folded", "foldedPanels", "tests/fixtures/organic/low_poly_head.stl",
         ("--thickness", "3"), assembled=False),
    Case("3d-slices", "threeD", "tests/fixtures/organic/lumpy_blob.stl",
         ("--thickness", "3", "--slice-depth", "4"), sheet=False),
)


# --------------------------------------------------------------------------
# OBJ reading
# --------------------------------------------------------------------------


def read_obj(path: Path) -> list[tuple[str, np.ndarray]]:
    """Return [(object name, triangles (n, 3, 3))] in file order."""
    verts: list[tuple[float, float, float]] = []
    groups: list[tuple[str, list[list[int]]]] = []
    current: list[list[int]] | None = None
    for raw in path.read_text().splitlines():
        if raw.startswith("v "):
            _, x, y, z = raw.split()[:4]
            verts.append((float(x), float(y), float(z)))
        elif raw.startswith("o "):
            current = []
            groups.append((raw[2:].strip(), current))
        elif raw.startswith("f "):
            if current is None:
                current = []
                groups.append(("object", current))
            idx = [int(tok.split("/")[0]) for tok in raw.split()[1:]]
            idx = [i - 1 if i > 0 else len(verts) + i for i in idx]
            for k in range(1, len(idx) - 1):
                current.append([idx[0], idx[k], idx[k + 1]])
    v = np.array(verts, dtype=np.float64)
    out = []
    for name, faces in groups:
        if faces:
            out.append((name, v[np.array(faces, dtype=np.int64)]))
    return out


# --------------------------------------------------------------------------
# Mesh rendering: a flat-shaded z-buffer
# --------------------------------------------------------------------------


def _normalize(a: np.ndarray) -> np.ndarray:
    return a / max(float(np.linalg.norm(a)), 1e-12)


def render_mesh(
    groups: list[tuple[str, np.ndarray]],
    size: tuple[int, int] = (1100, 820),
    elev: float = 26.0,
    azim: float = 38.0,
    families: bool = False,
    supersample: int = 3,
) -> "Image.Image":
    from PIL import Image

    width, height = size
    sw, sh = width * supersample, height * supersample

    # Camera: looking at the model's centre from (azim, elev), Z up.
    el, az = math.radians(elev), math.radians(azim)
    to_cam = np.array([math.cos(el) * math.cos(az), math.cos(el) * math.sin(az), math.sin(el)])
    view = -to_cam  # direction the camera looks along
    right = _normalize(np.cross(view, np.array([0.0, 0.0, 1.0])))
    up = np.cross(right, view)

    all_tris = np.concatenate([t for _, t in groups])
    lo, hi = all_tris.reshape(-1, 3).min(axis=0), all_tris.reshape(-1, 3).max(axis=0)
    centre = (lo + hi) / 2

    ids = np.concatenate([np.full(len(t), i, dtype=np.int32) for i, (_, t) in enumerate(groups)])
    base_colors = _group_colors(groups, families)

    rel = all_tris - centre
    sx = rel @ right
    sy = rel @ up
    depth = rel @ view  # larger = further from the camera

    span_x = float(sx.max() - sx.min())
    span_y = float(sy.max() - sy.min())
    scale = 0.86 * min(sw / max(span_x, 1e-9), sh / max(span_y, 1e-9))
    px = sw / 2 + (sx - (sx.max() + sx.min()) / 2) * scale
    py = sh / 2 - (sy - (sy.max() + sy.min()) / 2) * scale

    # Flat normals, turned to face the camera, and their shade.
    e1 = all_tris[:, 1] - all_tris[:, 0]
    e2 = all_tris[:, 2] - all_tris[:, 0]
    n = np.cross(e1, e2)
    length = np.linalg.norm(n, axis=1)
    n = n / np.maximum(length, 1e-12)[:, None]
    n[(n @ to_cam) < 0] *= -1
    key = _normalize(to_cam * 0.55 + up * 0.75 - right * 0.55)
    fill = _normalize(to_cam * 0.5 + right * 0.8 + up * 0.1)
    shade = 0.40 + 0.52 * np.clip(n @ key, 0, 1) + 0.18 * np.clip(n @ fill, 0, 1)
    shade = np.clip(shade, 0, 1.08)
    colors = base_colors[ids] * shade[:, None]

    zbuf = np.full((sh, sw), np.inf)
    image = np.zeros((sh, sw, 3), dtype=np.float32)
    idbuf = np.full((sh, sw), -1, dtype=np.int32)

    for t in range(len(all_tris)):
        if length[t] < 1e-9:
            continue
        xs, ys, zs = px[t], py[t], depth[t]
        x0 = max(int(math.floor(xs.min())), 0)
        x1 = min(int(math.ceil(xs.max())), sw - 1)
        y0 = max(int(math.floor(ys.min())), 0)
        y1 = min(int(math.ceil(ys.max())), sh - 1)
        if x1 < x0 or y1 < y0:
            continue
        denom = (ys[1] - ys[2]) * (xs[0] - xs[2]) + (xs[2] - xs[1]) * (ys[0] - ys[2])
        if abs(denom) < 1e-12:
            continue
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        w0 = ((ys[1] - ys[2]) * (gx - xs[2]) + (xs[2] - xs[1]) * (gy - ys[2])) / denom
        w1 = ((ys[2] - ys[0]) * (gx - xs[2]) + (xs[0] - xs[2]) * (gy - ys[2])) / denom
        w2 = 1.0 - w0 - w1
        inside = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
        if not inside.any():
            continue
        z = w0 * zs[0] + w1 * zs[1] + w2 * zs[2]
        region = zbuf[y0:y1 + 1, x0:x1 + 1]
        win = inside & (z < region)
        if not win.any():
            continue
        region[win] = z[win]
        image[y0:y1 + 1, x0:x1 + 1][win] = colors[t]
        idbuf[y0:y1 + 1, x0:x1 + 1][win] = ids[t]

    covered = idbuf >= 0

    # Darken the seam where one part ends and another begins, so touching
    # slices of the same tone stay readable.
    edge = np.zeros_like(covered)
    for dy, dx in ((0, 1), (1, 0)):
        a = idbuf[: sh - dy, : sw - dx]
        b = idbuf[dy:, dx:]
        diff = (a != b) & (a >= 0) & (b >= 0)
        edge[: sh - dy, : sw - dx] |= diff
        edge[dy:, dx:] |= diff
    image[edge] *= 0.62

    bg = np.array(BACKGROUND, dtype=np.float32)
    out = np.where(covered[..., None], np.clip(image, 0, 255), bg)

    # Soft contact shadow under the model: the footprint, offset and blurred.
    out = _with_ground_shadow(out, covered, bg)

    img = Image.fromarray(out.astype(np.uint8), "RGB")
    return img.resize((width, height), Image.LANCZOS)


def _with_ground_shadow(out: np.ndarray, covered: np.ndarray, bg: np.ndarray) -> np.ndarray:
    from PIL import Image, ImageFilter

    h, w = covered.shape
    ys = np.where(covered.any(axis=1))[0]
    if ys.size == 0:
        return out
    bottom = ys.max()
    mask = np.zeros((h, w), dtype=np.uint8)
    band = covered[max(bottom - h // 40, 0): bottom + 1].any(axis=0)
    xs = np.where(band)[0]
    if xs.size == 0:
        return out
    cx, half = (xs.min() + xs.max()) / 2, (xs.max() - xs.min()) / 2
    yy, xx = np.mgrid[0:h, 0:w]
    ellipse = ((xx - cx) / max(half * 1.05, 1)) ** 2 + ((yy - (bottom + h * 0.012)) / (h * 0.02)) ** 2 < 1
    mask[ellipse] = 255
    blurred = np.asarray(Image.fromarray(mask).filter(ImageFilter.GaussianBlur(h * 0.012)), dtype=np.float32) / 255
    shadow = (1 - 0.22 * blurred)[..., None]
    shaded_bg = bg * shadow
    return np.where(covered[..., None], out, shaded_bg)


def _group_colors(groups: list[tuple[str, np.ndarray]], families: bool) -> np.ndarray:
    palette_index: dict[str, int] = {}
    colors = []
    first_family = None
    for name, _ in groups:
        prefix = re.sub(r"_?\d+$", "", name)
        if first_family is None:
            first_family = prefix
        key = prefix if families else "all"
        k = palette_index.get(key, 0)
        palette_index[key] = k + 1
        if families and prefix != first_family:
            colors.append(PALETTE_B[k % 2])
        else:
            colors.append(PALETTE_A[k % 2])
    return np.array(colors, dtype=np.float32)


# --------------------------------------------------------------------------
# Cut sheet rendering: SVG -> PNG
# --------------------------------------------------------------------------


@dataclass
class _Shape:
    kind: str  # "poly", "circle", "text"
    points: np.ndarray | None = None
    closed: bool = False
    stroke: str = "#0000FF"
    width: float = 0.1
    dash: tuple[float, ...] | None = None
    centre: tuple[float, float] = (0.0, 0.0)
    radius: float = 0.0
    text: str = ""
    size: float = 8.0
    rotation: float = 0.0
    sheet: int = 1


@dataclass
class _Sheet:
    width: float = 0.0
    height: float = 0.0
    shapes: list[_Shape] = field(default_factory=list)


_NUMBER = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _parse_transform(value: str | None) -> np.ndarray:
    m = np.eye(3)
    if not value:
        return m
    for name, args in re.findall(r"(\w+)\s*\(([^)]*)\)", value):
        nums = [float(x) for x in _NUMBER.findall(args)]
        t = np.eye(3)
        if name == "translate":
            t[0, 2] = nums[0]
            t[1, 2] = nums[1] if len(nums) > 1 else 0.0
        elif name == "rotate":
            a = math.radians(nums[0])
            c, s = math.cos(a), math.sin(a)
            r = np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])
            if len(nums) == 3:
                pre = np.eye(3)
                pre[0, 2], pre[1, 2] = nums[1], nums[2]
                post = np.eye(3)
                post[0, 2], post[1, 2] = -nums[1], -nums[2]
                r = pre @ r @ post
            t = r
        elif name == "scale":
            t[0, 0] = nums[0]
            t[1, 1] = nums[1] if len(nums) > 1 else nums[0]
        elif name == "matrix" and len(nums) == 6:
            a, b, c, d, e, f = nums
            t = np.array([[a, c, e], [b, d, f], [0, 0, 1]])
        else:
            raise ValueError(f"unsupported SVG transform: {name}")
        m = m @ t
    return m


def _apply(m: np.ndarray, pts: np.ndarray) -> np.ndarray:
    pts = np.asarray(pts, dtype=np.float64).reshape(-1, 2)
    return (np.c_[pts, np.ones(len(pts))] @ m.T)[:, :2]


def _path_polylines(d: str) -> list[tuple[np.ndarray, bool]]:
    tokens = re.findall(r"[MLHVZmlhvz]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?", d)
    out: list[tuple[np.ndarray, bool]] = []
    pts: list[tuple[float, float]] = []
    cmd = ""
    i = 0
    x = y = 0.0
    while i < len(tokens):
        tok = tokens[i]
        if tok.isalpha():
            cmd = tok
            i += 1
            if cmd in "Zz":
                if pts:
                    out.append((np.array(pts), True))
                    x, y = pts[0]
                    pts = []
            continue
        if cmd in "Mm":
            if pts:
                out.append((np.array(pts), False))
            nx, ny = float(tokens[i]), float(tokens[i + 1])
            x, y = (x + nx, y + ny) if cmd == "m" else (nx, ny)
            pts = [(x, y)]
            i += 2
            cmd = "L" if cmd == "M" else "l"
        elif cmd in "Ll":
            nx, ny = float(tokens[i]), float(tokens[i + 1])
            x, y = (x + nx, y + ny) if cmd == "l" else (nx, ny)
            pts.append((x, y))
            i += 2
        elif cmd in "Hh":
            nx = float(tokens[i])
            x = x + nx if cmd == "h" else nx
            pts.append((x, y))
            i += 1
        elif cmd in "Vv":
            ny = float(tokens[i])
            y = y + ny if cmd == "v" else ny
            pts.append((x, y))
            i += 1
        else:
            raise ValueError(f"unsupported SVG path command: {cmd!r}")
    if pts:
        out.append((np.array(pts), False))
    return out


def _style(el: ET.Element) -> tuple[str, float, tuple[float, ...] | None]:
    stroke = el.get("stroke", "#0000FF")
    width = float(el.get("stroke-width", "0.1"))
    dash = el.get("stroke-dasharray")
    dashes = tuple(float(x) for x in _NUMBER.findall(dash)) if dash else None
    return stroke, width, dashes


def read_sheets(svg_path: Path) -> list[_Sheet]:
    root = ET.parse(svg_path).getroot()
    sheets: list[_Sheet] = []

    def walk(el: ET.Element, m: np.ndarray, sheet: _Sheet | None) -> None:
        tag = _local(el.tag)
        m = m @ _parse_transform(el.get("transform"))
        if tag == "g" and (el.get("id") or "").startswith("sheet-"):
            sheet = _Sheet()
            sheets.append(sheet)
        elif sheet is None and tag not in ("svg", "g"):
            # Drawing outside any sheet group: treat the file as one sheet.
            sheet = _Sheet()
            sheets.append(sheet)
        if tag == "rect":
            x, y = float(el.get("x", 0)), float(el.get("y", 0))
            w, h = float(el.get("width", 0)), float(el.get("height", 0))
            if el.get("fill", "none") == "none" and w > 0 and h > 0 and sheet.width == 0:
                p = _apply(m, [(x, y), (x + w, y + h)])
                sheet.width, sheet.height = float(p[1, 0] - p[0, 0]), float(p[1, 1] - p[0, 1])
            return
        if tag in ("path", "polyline", "polygon", "line"):
            stroke, width, dash = _style(el)
            if tag == "path":
                lines = _path_polylines(el.get("d", ""))
            elif tag == "line":
                lines = [(np.array([(float(el.get("x1", 0)), float(el.get("y1", 0))),
                                    (float(el.get("x2", 0)), float(el.get("y2", 0)))]), False)]
            else:
                nums = [float(x) for x in _NUMBER.findall(el.get("points", ""))]
                lines = [(np.array(nums).reshape(-1, 2), tag == "polygon")]
            for pts, closed in lines:
                if len(pts) >= 2:
                    sheet.shapes.append(_Shape("poly", _apply(m, pts), closed, stroke, width, dash))
            return
        if tag == "circle":
            stroke, width, dash = _style(el)
            c = _apply(m, [(float(el.get("cx", 0)), float(el.get("cy", 0)))])[0]
            sheet.shapes.append(_Shape("circle", None, True, stroke, width, dash,
                                       (float(c[0]), float(c[1])), float(el.get("r", 0))))
            return
        if tag == "text":
            c = _apply(m, [(float(el.get("x", 0)), float(el.get("y", 0)))])[0]
            angle = math.degrees(math.atan2(m[1, 0], m[0, 0]))
            sheet.shapes.append(_Shape("text", None, False, el.get("fill", "#FF0000"), 0.0, None,
                                       (float(c[0]), float(c[1])), 0.0,
                                       "".join(el.itertext()).strip(),
                                       float(el.get("font-size", 8)), angle))
            return
        for child in el:
            walk(child, m, sheet)

    walk(root, np.eye(3), None)
    return sheets


def render_sheet(svg_path: Path, width_px: int = 1100) -> "Image.Image":
    """Draw the first sheet of a cut-sheet SVG, cropped to its parts."""
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from PIL import Image

    sheets = read_sheets(svg_path)
    sheet = sheets[0]
    xs = [p for s in sheet.shapes if s.kind == "poly" for p in s.points[:, 0]]
    ys = [p for s in sheet.shapes if s.kind == "poly" for p in s.points[:, 1]]
    for s in sheet.shapes:
        if s.kind == "circle":
            xs += [s.centre[0] - s.radius, s.centre[0] + s.radius]
            ys += [s.centre[1] - s.radius, s.centre[1] + s.radius]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    pad = 0.04 * max(x1 - x0, y1 - y0)
    x0, x1, y0, y1 = x0 - pad, x1 + pad, y0 - pad, y1 + pad

    w_in = 10.0
    h_in = w_in * (y1 - y0) / (x1 - x0)
    dpi = width_px / w_in
    fig = plt.figure(figsize=(w_in, h_in), dpi=dpi, facecolor=tuple(c / 255 for c in BACKGROUND))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(x0, x1)
    ax.set_ylim(y1, y0)  # SVG y runs down
    ax.axis("off")
    pt_per_mm = (h_in * 72) / (y1 - y0)

    for s in sheet.shapes:
        if s.kind == "poly":
            pts = s.points if not s.closed else np.vstack([s.points, s.points[:1]])
            ax.plot(pts[:, 0], pts[:, 1], color=s.stroke, linewidth=max(s.width * pt_per_mm, 0.6),
                    linestyle=(0, [d * 3 for d in s.dash]) if s.dash else "-", solid_joinstyle="round")
        elif s.kind == "circle":
            ax.add_patch(plt.Circle(s.centre, s.radius, fill=False, color=s.stroke,
                                    linewidth=max(s.width * pt_per_mm, 0.6)))
        elif s.kind == "text":
            ax.text(s.centre[0], s.centre[1], s.text, color=s.stroke, ha="center", va="center",
                    fontsize=s.size * pt_per_mm * 0.9, rotation=-s.rotation, family="DejaVu Sans")
    fig.canvas.draw()
    buf = np.asarray(fig.canvas.buffer_rgba())[..., :3].copy()
    plt.close(fig)
    return Image.fromarray(buf, "RGB")


# --------------------------------------------------------------------------
# Saving
# --------------------------------------------------------------------------


def save_png(img: "Image.Image", path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # A 256-colour palette keeps flat-shaded illustrations small.
    img.convert("RGB").quantize(colors=256, method=2, dither=0).save(path, optimize=True)
    print(f"wrote {path} ({path.stat().st_size // 1024} KB)")


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------


def run_export(binary: Path, case: Case, fmt: str, out: Path) -> None:
    cmd = [
        str(binary), "--headless-export",
        "--mode", case.mode, "--format", fmt,
        "--fixture", str(REPO / case.fixture), "--output", str(out),
        *case.args,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO)
    if result.returncode != 0 or not out.exists():
        sys.exit(f"export failed ({case.name} {fmt}):\n{result.stdout}\n{result.stderr}")


def cmd_all(args: argparse.Namespace) -> None:
    binary = Path(args.binary)
    if not binary.exists():
        sys.exit(f"missing {binary}; run: swift build -c release --package-path app/RefabArtist")
    out_dir = Path(args.out)
    only = set(args.only or [c.name for c in CASES])
    with tempfile.TemporaryDirectory(prefix="refab-doc-images-") as tmp:
        for case in CASES:
            if case.name not in only:
                continue
            if case.sheet:
                svg = Path(tmp) / f"{case.name}.svg"
                run_export(binary, case, "svg", svg)
                save_png(render_sheet(svg), out_dir / f"{case.name}-sheet.png")
            if case.assembled:
                obj = Path(tmp) / f"{case.name}.obj"
                run_export(binary, case, "obj", obj)
                save_png(render_mesh(read_obj(obj), elev=case.elev, azim=case.azim, families=case.families),
                         out_dir / f"{case.name}-assembled.png")
    if not args.only:
        from PIL import Image

        icon_dir = Path(tempfile.mkdtemp(prefix="refab-icon-"))
        subprocess.run([sys.executable, str(REPO / "tools/icon/make_app_icon.py"), "--no-icns",
                        "--png-dir", str(icon_dir), "--sizes", "256"], check=True, cwd=REPO)
        # The icon keeps its transparent corners, so it is saved as RGBA, not palettised.
        out_dir.mkdir(parents=True, exist_ok=True)
        Image.open(icon_dir / "icon-256.png").convert("RGBA").save(out_dir / "app-icon.png", optimize=True)
        print(f"wrote {out_dir / 'app-icon.png'}")


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)

    p_all = sub.add_parser("all", help="export and draw every case")
    p_all.add_argument("--binary", default=str(DEFAULT_BINARY))
    p_all.add_argument("--out", default=str(DEFAULT_OUT))
    p_all.add_argument("--only", nargs="*", help="draw only these case names (skips the icon)")
    p_all.set_defaults(func=cmd_all)

    p_obj = sub.add_parser("obj", help="draw one OBJ")
    p_obj.add_argument("input", type=Path)
    p_obj.add_argument("output", type=Path)
    p_obj.add_argument("--family-colors", action="store_true")
    p_obj.add_argument("--elev", type=float, default=26.0)
    p_obj.add_argument("--azim", type=float, default=38.0)
    p_obj.set_defaults(func=lambda a: save_png(
        render_mesh(read_obj(a.input), elev=a.elev, azim=a.azim, families=a.family_colors), a.output))

    p_svg = sub.add_parser("svg", help="draw one cut-sheet SVG")
    p_svg.add_argument("input", type=Path)
    p_svg.add_argument("output", type=Path)
    p_svg.set_defaults(func=lambda a: save_png(render_sheet(a.input), a.output))

    args = ap.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
