#!/usr/bin/env python3
"""Generate the four viewport matcap images from a stated lighting model.

A matcap (material capture, or lit sphere) is a picture of a sphere that has
already been lit. The viewport shader (`tools/shaders/Matcap.metal`) looks up
the shade of every visible surface point in that picture, using the point's
view-space normal as the coordinate. The picture therefore carries the whole
look of a style: where the light sits, how soft the highlight is, how dark the
shadow side gets. The shader tints it with the object colour, so the images
made here are neutral grey.

This script draws those pictures from scratch. It reads no image: every pixel
is computed from the parameters in `STYLES` below, so the images are project
work under the project licence (GPL-3.0).

Usage, from anywhere, with numpy and Pillow installed:

    python3 tools/generate_matcaps.py                 # rewrite the four PNGs
    python3 tools/generate_matcaps.py --check         # exit 1 if the PNGs are stale
    python3 tools/generate_matcaps.py --out DIR       # write somewhere else
    python3 tools/generate_matcaps.py --preview DIR   # also draw a test-shape sheet

Image contract (what `ViewportMatcapMaterial.swift` and `Matcap.metal` rely on)
------------------------------------------------------------------------------
* 512 x 512 pixels, 8 bits per channel, RGBA, alpha 255 everywhere, R = G = B.
  The shader reads the red channel as the shade. The app decodes the file with
  ImageIO and uploads it as a colour texture.
* The sphere fills the square. The shader maps a view-space normal (nx, ny, nz)
  to u = nx/2 + 1/2 and v = 1/2 - ny/2, with v counted down from the top. So
  the pixel centre (i + 1/2, j + 1/2) stands for the normal
  nx = 2(i + 1/2)/N - 1, ny = 1 - 2(j + 1/2)/N, nz = sqrt(1 - nx^2 - ny^2).
  Pixels outside the unit disc are black; a visible surface never samples them.

Lighting model
--------------
Directions are unit vectors in view space: +x to the right, +y up, +z towards
the viewer. A direction is written as a polar angle from +z (0 is a head-on
light, 90 is level with the image plane) and an azimuth in the image plane,
counted anticlockwise from +x (0 is right, 90 is up, 180 is left).

For a surface normal n, a smooth style (`SmoothStyle`) adds up

  ambient    ambient_floor + ambient_sky * (1/2 + n.y / 2)
             a dim gradient, brighter towards the top.
  key        key_gain * max(n.l_key, 0)
             the main light, diffuse (Lambert's law), from the upper left.
  fill       fill_gain * max(n.l_fill, 0)
             a weak light from the lower right that lifts the shadow side.
  rim        rim_gain * (1 - n.z)^rim_power * (1/2 + cos(phi - rim_azimuth)/2)
             a faint glow along the silhouette, strongest on the side the
             rim light sits; phi is the image-plane azimuth of n.
  highlight  spec_gain  * exp(-a^2 / (2 spec_width^2))
           + sheen_gain * exp(-a^2 / (2 sheen_width^2))
             two Gaussian lobes in the angle a between n and the half vector
             of the key light and the viewer: a tight lobe for the bright
             spot and a wide, faint one for the glow around it.

The sum is clipped to [0, 1] and quantised to 8 bits.

A banded style (`ToonStyle`) does not add lights. It cuts the key light's
diffuse term n.l_key at two thresholds into three flat tones, and paints a
hard-edged white highlight disc wherever the angle a is smaller than
`highlight_deg`.
"""

from __future__ import annotations

import argparse
import math
import sys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

SIZE = 512
REPO_ROOT = Path(__file__).resolve().parent.parent
RESOURCES = REPO_ROOT / "app" / "RefabArtist" / "Sources" / "RefabArtist" / "Resources"

# The key light every style shares unless it says otherwise: up and to the
# left, about 45 degrees off the line of sight.
KEY_POLAR_DEG = 45.5
KEY_AZIMUTH_DEG = 129.0


@dataclass(frozen=True)
class SmoothStyle:
    """Parameters of a smoothly shaded style (see the module docstring)."""

    key_gain: float
    ambient_floor: float
    ambient_sky: float
    spec_gain: float
    spec_width_deg: float
    sheen_gain: float
    sheen_width_deg: float
    fill_gain: float = 0.0
    rim_gain: float = 0.0
    rim_power: float = 2.0
    key_polar_deg: float = KEY_POLAR_DEG
    key_azimuth_deg: float = KEY_AZIMUTH_DEG
    fill_polar_deg: float = 80.0
    fill_azimuth_deg: float = -75.0
    rim_azimuth_deg: float = 180.0


@dataclass(frozen=True)
class ToonStyle:
    """Parameters of a banded style (see the module docstring)."""

    levels: tuple          # shade of the shadow, middle and light band, 0..1
    thresholds: tuple      # n.l_key where shadow gives way to middle, and middle to light
    highlight_deg: float   # angular radius of the white highlight disc
    key_polar_deg: float = KEY_POLAR_DEG
    key_azimuth_deg: float = KEY_AZIMUTH_DEG


# Tuned so that each image reads like the matcap it replaces in the viewport:
# the same overall brightness, light direction, highlight size and softness,
# measured with radial and angular intensity profiles and the structural
# similarity index (SSIM) between the old and new images.
STYLES: dict[str, SmoothStyle | ToonStyle] = {
    # Matte plaster, the default and the look the app was tuned around. The
    # highlight is mostly a broad soft glow (wide sheen) over a small, dim
    # core, and the key sits a little further off the line of sight and to the
    # left than the other styles' (49 and 128 degrees against 45.5 and 129).
    "clay": SmoothStyle(
        key_polar_deg=49.0, key_azimuth_deg=128.0, key_gain=0.68,
        ambient_floor=0.09, ambient_sky=0.14, fill_gain=0.065,
        spec_gain=0.54, spec_width_deg=8.5, sheen_gain=0.16, sheen_width_deg=43.0,
    ),
    # Semi-matte: a clear but soft highlight, a darker body than clay, and a
    # faint rim light on the left edge.
    "satin": SmoothStyle(
        key_gain=0.50, ambient_floor=0.078, ambient_sky=0.165, fill_gain=0.055,
        rim_gain=0.10, rim_power=1.7,
        spec_gain=0.44, spec_width_deg=11.0, sheen_gain=0.05, sheen_width_deg=22.0,
    ),
    # Polished: a small, hard, bright spot on a darker body, with the same
    # rim light.
    "glossy": SmoothStyle(
        key_gain=0.51, ambient_floor=0.04, ambient_sky=0.16, fill_gain=0.055,
        rim_gain=0.10, rim_power=1.9,
        spec_gain=0.95, spec_width_deg=5.2, sheen_gain=0.04, sheen_width_deg=24.0,
    ),
    # Flat bands: three tones and a white highlight disc, no gradients.
    "toon": ToonStyle(
        levels=(0.298, 0.557, 0.80), thresholds=(0.33, 0.72), highlight_deg=25.8,
    ),
}


def direction(polar_deg: float, azimuth_deg: float) -> np.ndarray:
    """View-space unit vector from a polar angle (off +z) and an image-plane azimuth."""
    p = math.radians(polar_deg)
    a = math.radians(azimuth_deg)
    return np.array([math.sin(p) * math.cos(a), math.sin(p) * math.sin(a), math.cos(p)])


def half_vector(light: np.ndarray) -> np.ndarray:
    """Blinn half vector of a light and a viewer on the +z axis."""
    h = light + np.array([0.0, 0.0, 1.0])
    return h / np.linalg.norm(h)


def sphere_normals(size: int = SIZE):
    """Normals of the unit sphere seen head-on, one per pixel centre.

    Returns (nx, ny, nz, inside); nz is 0 outside the unit disc.
    """
    c = (np.arange(size) + 0.5) / size * 2.0 - 1.0
    nx = np.broadcast_to(c[None, :], (size, size))
    ny = np.broadcast_to(-c[:, None], (size, size))
    r2 = nx * nx + ny * ny
    nz = np.sqrt(np.clip(1.0 - r2, 0.0, 1.0))
    return nx, ny, nz, r2 <= 1.0


def shade(style: SmoothStyle | ToonStyle, nx, ny, nz, clip: bool = True) -> np.ndarray:
    """Shade in [0, 1] of the unit normals (nx, ny, nz) under `style`.

    `clip=False` keeps smooth shades above 1; it is for tuning tools.
    """
    n = np.stack([nx, ny, nz], axis=-1)
    l_key = direction(style.key_polar_deg, style.key_azimuth_deg)
    angle = np.arccos(np.clip(n @ half_vector(l_key), -1.0, 1.0))

    if isinstance(style, ToonStyle):
        d = n @ l_key
        shadow, middle, light = style.levels
        low, high = style.thresholds
        tone = np.where(d < low, shadow, np.where(d < high, middle, light))
        return np.where(angle < math.radians(style.highlight_deg), 1.0, tone)

    l_fill = direction(style.fill_polar_deg, style.fill_azimuth_deg)
    e = style.ambient_floor + style.ambient_sky * (0.5 + 0.5 * ny)
    e = e + style.key_gain * np.maximum(n @ l_key, 0.0)
    e = e + style.fill_gain * np.maximum(n @ l_fill, 0.0)
    side = 0.5 + 0.5 * np.cos(np.arctan2(ny, nx) - math.radians(style.rim_azimuth_deg))
    e = e + style.rim_gain * (1.0 - nz) ** style.rim_power * side
    spec = math.radians(style.spec_width_deg)
    sheen = math.radians(style.sheen_width_deg)
    e = e + style.spec_gain * np.exp(-0.5 * (angle / spec) ** 2)
    e = e + style.sheen_gain * np.exp(-0.5 * (angle / sheen) ** 2)
    return np.clip(e, 0.0, 1.0) if clip else e


def render(style: SmoothStyle | ToonStyle, size: int = SIZE) -> np.ndarray:
    """Render one matcap as a (size, size) uint8 array; black outside the disc."""
    nx, ny, nz, inside = sphere_normals(size)
    return np.where(inside, np.rint(shade(style, nx, ny, nz) * 255.0), 0.0).astype(np.uint8)


def to_image(gray: np.ndarray) -> Image.Image:
    rgba = np.empty(gray.shape + (4,), dtype=np.uint8)
    rgba[..., 0] = rgba[..., 1] = rgba[..., 2] = gray
    rgba[..., 3] = 255
    return Image.fromarray(rgba)


def write_png(gray: np.ndarray, path: Path) -> None:
    # No metadata and fixed compression: the same pixels always give the same file.
    to_image(gray).save(path, format="PNG", optimize=False, compress_level=9)


def is_current(gray: np.ndarray, path: Path) -> bool:
    """True when the PNG at `path` holds `gray` in the contract format. Pixels
    may differ by one 8-bit level, which absorbs floating-point differences
    between platforms."""
    if not path.exists():
        return False
    with Image.open(path) as im:
        if im.mode != "RGBA" or im.size != gray.shape[::-1]:
            return False
        have = np.asarray(im).astype(int)
    want = np.asarray(to_image(gray)).astype(int)
    return int(np.abs(have - want).max()) <= 1


# ---------------------------------------------------------------------------
# Test shapes: the matcaps applied to a sphere and a torus, with no GPU.
# ---------------------------------------------------------------------------

# The viewport shader's constants (tools/shaders/Matcap.metal).
SHADER_GAIN = 1.32
HOTSPOT_EDGE = (0.86, 1.0)
CHROMA_SCALE = 2.2


@lru_cache(maxsize=4)
def torus_normals(size: int, major: float = 0.60, minor: float = 0.30, tilt_deg: tuple = (58.0, -24.0)):
    """View-space normals of a torus seen head-on, by sphere tracing.

    The torus axis is tilted by `tilt_deg` about the view x axis, then the y
    axis. The view spans -1.2 to 1.2 in x and y. Returns (nx, ny, nz, hit).
    """
    ax, ay = (math.radians(a) for a in tilt_deg)
    rx = np.array([[1, 0, 0], [0, math.cos(ax), -math.sin(ax)], [0, math.sin(ax), math.cos(ax)]])
    ry = np.array([[math.cos(ay), 0, math.sin(ay)], [0, 1, 0], [-math.sin(ay), 0, math.cos(ay)]])
    rotation = ry @ rx  # torus frame -> view space

    def distance(p):
        q = p @ rotation  # row-vector form of rotation.T @ p: view space -> torus frame
        ring = np.hypot(q[..., 0], q[..., 1]) - major
        return np.hypot(ring, q[..., 2]) - minor

    c = (np.arange(size) + 0.5) / size * 2.4 - 1.2
    p = np.stack([
        np.broadcast_to(c[None, :], (size, size)),
        np.broadcast_to(-c[:, None], (size, size)),
        np.full((size, size), 2.0),
    ], axis=-1)
    step = np.array([0.0, 0.0, -1.0])
    for _ in range(240):
        p = p + step * np.clip(distance(p), 0.0, 1.0)[..., None]
    hit = np.abs(distance(p)) < 2e-3
    eps = 1e-4
    grad = np.stack([distance(p + eps * e) - distance(p - eps * e) for e in np.eye(3)], axis=-1)
    grad = grad / np.maximum(np.linalg.norm(grad, axis=-1, keepdims=True), 1e-12)
    return grad[..., 0], grad[..., 1], grad[..., 2], hit


def apply_matcap(gray: np.ndarray, nx, ny, hit, tint=(0.80, 0.77, 0.72)) -> np.ndarray:
    """Shade normals through a matcap the way the viewport shader does.

    `gray` is the 512 x 512 shade image (uint8). The lookup is bilinear on
    u = nx/2 + 1/2, v = 1/2 - ny/2. The tint colours the body tones but not
    the highlight, then the shader's fixed gain is applied. The viewport
    tone-maps the result; here it is clipped. Returns float RGB in [0, 1],
    white where `hit` is False.
    """
    n = gray.shape[0]
    fx = np.clip((nx * 0.5 + 0.5) * n - 0.5, 0, n - 1)
    fy = np.clip((0.5 - ny * 0.5) * n - 0.5, 0, n - 1)
    x0 = np.floor(fx).astype(int)
    y0 = np.floor(fy).astype(int)
    x1 = np.minimum(x0 + 1, n - 1)
    y1 = np.minimum(y0 + 1, n - 1)
    wx, wy = fx - x0, fy - y0
    g = gray.astype(np.float64) / 255.0
    lum = (g[y0, x0] * (1 - wx) * (1 - wy) + g[y0, x1] * wx * (1 - wy)
           + g[y1, x0] * (1 - wx) * wy + g[y1, x1] * wx * wy)
    tint = np.asarray(tint, dtype=np.float64)
    chroma = tint.max() - tint.min()
    t = np.clip((lum - HOTSPOT_EDGE[0]) / (HOTSPOT_EDGE[1] - HOTSPOT_EDGE[0]), 0.0, 1.0)
    hotspot = t * t * (3.0 - 2.0 * t) * np.clip(chroma * CHROMA_SCALE, 0.0, 1.0)
    tone = tint[None, None, :] * (1.0 - hotspot[..., None]) + hotspot[..., None]
    rgb = np.clip(tone * lum[..., None] * SHADER_GAIN, 0.0, 1.0)
    return np.where(hit[..., None], rgb, 1.0)


def shape_tile(gray: np.ndarray, shape: str, tint, size: int = 256, backdrop=(0.94, 0.94, 0.93)) -> Image.Image:
    """A `size` x `size` picture of `shape` ('sphere' or 'torus') shaded by `gray`."""
    ss = 2  # supersampling for smooth silhouettes
    big = size * ss
    if shape == "sphere":
        c = (np.arange(big) + 0.5) / big * 2.4 - 1.2
        px = np.broadcast_to(c[None, :], (big, big)) / 0.9
        py = np.broadcast_to(-c[:, None], (big, big)) / 0.9
        hit = px * px + py * py <= 1.0
        nx, ny = px, py
    else:
        nx, ny, _, hit = torus_normals(big)
    rgb = apply_matcap(gray, nx, ny, hit, tint)
    cover = hit.astype(np.float64)[..., None]
    img = rgb * cover + np.asarray(backdrop)[None, None, :] * (1.0 - cover)
    img = img.reshape(size, ss, size, ss, 3).mean(axis=(1, 3))
    return Image.fromarray(np.rint(img * 255.0).astype(np.uint8))


def write_preview(images: dict[str, np.ndarray], path: Path, tile: int = 256) -> None:
    """One sheet: a row per style with the matcap, then a sphere and a torus in
    plaster, and a torus in teal, as the viewport would draw them."""
    plaster, teal = (0.80, 0.77, 0.72), (0.13, 0.52, 0.55)
    cols = ["matcap", "sphere, plaster", "torus, plaster", "torus, teal"]
    pad, head = 8, 22
    sheet = Image.new("RGB", (pad + (tile + pad) * len(cols), head + (tile + pad) * len(images)), (240, 240, 238))
    draw = ImageDraw.Draw(sheet)
    for j, title in enumerate(cols):
        draw.text((pad + j * (tile + pad), 6), title, fill=(60, 60, 60))
    for i, (name, gray) in enumerate(images.items()):
        y = head + i * (tile + pad)
        cells = [
            to_image(gray).convert("RGB").resize((tile, tile), Image.Resampling.LANCZOS),
            shape_tile(gray, "sphere", plaster, tile),
            shape_tile(gray, "torus", plaster, tile),
            shape_tile(gray, "torus", teal, tile),
        ]
        for j, cell in enumerate(cells):
            sheet.paste(cell, (pad + j * (tile + pad), y))
        draw.text((pad + 4, y + 4), name, fill=(255, 255, 255))
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path, format="PNG")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", type=Path, default=RESOURCES, help="directory holding matcap_<style>.png (default: the app resources)")
    ap.add_argument("--check", action="store_true", help="write nothing; exit 1 if a PNG in --out is missing or stale")
    ap.add_argument("--preview", type=Path, default=None, metavar="DIR", help="also write DIR/matcap_preview.png")
    args = ap.parse_args(argv)

    stale = 0
    images: dict[str, np.ndarray] = {}
    for name, style in STYLES.items():
        gray = render(style)
        images[name] = gray
        path = args.out / f"matcap_{name}.png"
        if args.check:
            ok = is_current(gray, path)
            print(f"{'ok   ' if ok else 'STALE'} {path}")
            stale += 0 if ok else 1
        else:
            args.out.mkdir(parents=True, exist_ok=True)
            write_png(gray, path)
            print(f"wrote {path}")
    if args.preview is not None:
        write_preview(images, args.preview / "matcap_preview.png")
        print(f"wrote {args.preview / 'matcap_preview.png'}")
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
