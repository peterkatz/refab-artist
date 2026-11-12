#!/usr/bin/env python3
"""Draw the Refab Artist app icon and build AppIcon.icns.

The icon is a sphere built from stacked, laser-cut birch-plywood sheets, with
one glossy orange acrylic sheet at its widest point and the top sheet just
being set in place, over a deep blue rounded-square body.

Everything is drawn here from geometry. A small orthographic ray caster
renders the sheets (soft key-light shadows, plies and glue lines on the cut
edges, the browned rim a laser leaves on a face, faint face grain, a softbox
reflection on the acrylic). The body follows the macOS app icon grid: a
1024 x 1024 canvas with an 824 x 824 body, continuous corners and a soft drop
shadow. The script reads no images, fonts or other art, and uses no random
numbers, so re-running it reproduces the icon.

Each size is rendered from the geometry at its own pixel size, never scaled
down from a larger one. Small sizes get fewer, thicker sheets and a slightly
larger form so the sphere still reads at 16 px.

Usage (from the repository root):
    python3 tools/icon/make_app_icon.py
        render every iconset size and write
        app/RefabArtist/Packaging/AppIcon.icns (uses macOS iconutil)
    python3 tools/icon/make_app_icon.py --no-icns --preview DIR
        write preview-light.png and preview-dark.png: the icon at 1024, 128,
        32 and 16 px, with 32 and 16 px also enlarged 8x
    options: --iconset DIR keeps the AppIcon.iconset PNGs; --png-dir DIR
        writes icon-<size>.png for each --sizes value; --icns PATH

Needs numpy (tools/requirements.txt). PNGs are written with the standard
library. tools/package_app.sh copies the committed AppIcon.icns into the app.
"""
from __future__ import annotations

import argparse
import math
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from dataclasses import dataclass
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
DEFAULT_ICNS = REPO / "app/RefabArtist/Packaging/AppIcon.icns"

CANVAS = 1024.0  # design units: the full icon canvas is 1024 x 1024
BODY_HALF = 412.0  # the 824 x 824 body, centred
BODY_CORNER = 185.4  # nominal corner radius of the body
# Continuous corners: each corner is a superellipse quadrant that starts
# 1.528 corner radii before the corner (so curvature eases in from the
# straight edge) and passes through the 45 degree point of a circular corner
# of BODY_CORNER.
BODY_CORNER_EXTENT = 1.528665 * BODY_CORNER
BODY_CORNER_EXPONENT = math.log(2.0) / -math.log(
    1.0 - BODY_CORNER * (1.0 - 1.0 / math.sqrt(2.0)) / BODY_CORNER_EXTENT
)

# The members of a macOS .iconset: (file name, pixel size).
ICONSET = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


# ---------------------------------------------------------------- colour --


def srgb_to_linear(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1.0 / 2.4) - 0.055)


def hex_linear(code: str) -> np.ndarray:
    code = code.lstrip("#")
    return srgb_to_linear([int(code[i : i + 2], 16) / 255.0 for i in (0, 2, 4)])


def _unit(v) -> np.ndarray:
    v = np.asarray(v, dtype=np.float64)
    return v / np.linalg.norm(v)


def _dot(a, b):
    return np.einsum("...i,...i->...", a, b)


def _tonemap(c, knee=0.72):
    """Roll bright values off smoothly instead of clipping, keeping hue."""
    peak = np.max(c, axis=-1, keepdims=True)
    span = 1.0 - knee
    soft = knee + span * (1.0 - np.exp(-(peak - knee) / span))
    with np.errstate(invalid="ignore", divide="ignore"):
        return c * np.where(peak > knee, soft / peak, 1.0)


# ----------------------------------------------------------------- scene --


@dataclass
class Material:
    """How a sheet looks: its faces, its cut edge and its shine."""

    face: str  # sRGB hex of the faces
    edge: str  # sRGB hex of the cut edge
    plies: int = 0  # plies visible on the cut edge (0 = solid sheet)
    ply_contrast: float = 0.0  # brightness step between neighbouring plies
    glue_line: float = 0.0  # darkening of the glue line between plies
    grain: float = 0.0  # strength of the face grain
    face_rim: float = 0.0  # width of the browned rim a laser leaves on a face
    face_rim_strength: float = 0.6
    specular: float = 0.03
    shininess: float = 10.0
    edge_glow: float = 0.0  # extra light on cut edges (acrylic carries light)
    gloss: float = 0.0  # strength of the softbox reflection


@dataclass
class Sheet:
    """A flat circular sheet: a disc of `radius` and `thickness` centred on
    `center`, its faces perpendicular to `axis`."""

    center: tuple
    axis: tuple
    radius: float
    thickness: float
    material: Material
    grain_phase: float = 0.0

    def __post_init__(self):
        self.c = np.asarray(self.center, dtype=np.float64)
        self.a = _unit(self.axis)
        self.h = 0.5 * self.thickness
        helper = np.array([0.0, 0.0, 1.0]) if abs(self.a[2]) < 0.9 else np.array([1.0, 0.0, 0.0])
        self.u = _unit(np.cross(self.a, helper))  # in-face directions for the grain
        self.v = np.cross(self.a, self.u)

    def intersect(self, o, d):
        """For rays o + t d: the interval [t_in, t_out] inside the sheet, the
        normal where the ray enters, and whether it enters through the cut
        edge (True) or a face (False)."""
        oc = o - self.c
        s0 = oc @ self.a
        sd = _dot(d, self.a) * np.ones_like(s0)
        # Between the two face planes.
        with np.errstate(divide="ignore", invalid="ignore"):
            t1 = (-self.h - s0) / sd
            t2 = (self.h - s0) / sd
        parallel = np.abs(sd) < 1e-12
        within = np.abs(s0) <= self.h
        t_in = np.where(parallel, np.where(within, -np.inf, np.inf), np.minimum(t1, t2))
        t_out = np.where(parallel, np.where(within, np.inf, -np.inf), np.maximum(t1, t2))
        normal = -np.sign(sd)[:, None] * self.a[None, :]
        # Inside the round outline.
        m = oc - s0[:, None] * self.a
        n = d - sd[:, None] * self.a
        qa = _dot(n, n)
        qb = 2.0 * _dot(m, n)
        qc = _dot(m, m) - self.radius * self.radius
        disc = qb * qb - 4.0 * qa * qc
        root = np.sqrt(np.maximum(disc, 0.0))
        with np.errstate(divide="ignore", invalid="ignore"):
            c_in = (-qb - root) / (2.0 * qa)
            c_out = (-qb + root) / (2.0 * qa)
        along = qa < 1e-12
        c_in = np.where(along, np.where(qc <= 0, -np.inf, np.inf), np.where(disc < 0, np.inf, c_in))
        c_out = np.where(along, np.where(qc <= 0, np.inf, -np.inf), np.where(disc < 0, -np.inf, c_out))
        edge = c_in > t_in
        t_in = np.where(edge, c_in, t_in)
        t_out = np.minimum(t_out, c_out)
        with np.errstate(invalid="ignore"):
            edge_n = m + c_in[:, None] * n
            edge_n /= np.maximum(np.linalg.norm(edge_n, axis=1), 1e-12)[:, None]
        normal = np.where(edge[:, None], edge_n, normal)
        return t_in, t_out, normal, edge


@dataclass
class Camera:
    """Orthographic camera: world point `target` lands on canvas point
    `canvas_center`, at `scale` canvas units per world unit."""

    azimuth_deg: float
    elevation_deg: float
    canvas_center: tuple
    scale: float

    def __post_init__(self):
        az = math.radians(self.azimuth_deg)
        el = math.radians(self.elevation_deg)
        self.w = np.array([math.cos(el) * math.cos(az), math.cos(el) * math.sin(az), math.sin(el)])
        self.r = np.array([-math.sin(az), math.cos(az), 0.0])
        self.up = np.cross(self.w, self.r)

    def to_world(self, v):
        """A camera-space direction (right, up, toward the viewer) in world."""
        return _unit(v[0] * self.r + v[1] * self.up + v[2] * self.w)

    def rays(self, X, Y):
        sx = (X - self.canvas_center[0]) / self.scale
        sy = -(Y - self.canvas_center[1]) / self.scale
        return sx[:, None] * self.r + sy[:, None] * self.up + 50.0 * self.w, -self.w


@dataclass
class Scene:
    camera: Camera
    sheets: list
    body_top: str  # body gradient, sRGB hex
    body_bottom: str
    body_glow: tuple  # (x, y, radius, strength): soft light on the body
    floor_shadow: tuple  # (x, y, x radius, y radius, opacity) under the form
    key_light: tuple = (-0.55, 0.75, 0.55)  # camera space; casts soft shadows
    key_softness_deg: float = 12.0
    key_color: str = "#FFF4E6"
    key_strength: float = 1.35
    sky_color: str = "#E4DED6"
    sky_strength: float = 0.42
    bounce_color: str = "#8A6A50"
    bounce_strength: float = 0.18
    fill_light: tuple = (0.7, 0.1, 0.7)  # camera space; no shadows
    fill_color: str = "#E8E4F0"
    fill_strength: float = 0.35
    # A tall softbox seen only in reflections: azimuth from the view
    # direction (degrees, negative = left) and half-width.
    softbox: tuple = (-62.0, 12.0)
    softbox_strength: float = 1.2


# ------------------------------------------------------------- rendering --


def _body_corner_terms(X, Y):
    ax = np.abs(X - CANVAS / 2)
    ay = np.abs(Y - CANVAS / 2)
    inner = BODY_HALF - BODY_CORNER_EXTENT
    dx = np.maximum(ax - inner, 0.0) / BODY_CORNER_EXTENT
    dy = np.maximum(ay - inner, 0.0) / BODY_CORNER_EXTENT
    return ax, ay, dx, dy


def body_inside(X, Y):
    """True inside the icon body."""
    ax, ay, dx, dy = _body_corner_terms(X, Y)
    p = BODY_CORNER_EXPONENT
    return (ax <= BODY_HALF) & (ay <= BODY_HALF) & (dx**p + dy**p <= 1.0)


def body_distance(X, Y):
    """Approximate signed distance to the body outline, in canvas units."""
    ax, ay, dx, dy = _body_corner_terms(X, Y)
    p = BODY_CORNER_EXPONENT
    corner = ((dx**p + dy**p) ** (1.0 / p) - 1.0) * BODY_CORNER_EXTENT
    return np.where((dx > 0) & (dy > 0), corner, np.maximum(ax, ay) - BODY_HALF)


def _samples_per_side(size: int) -> int:
    return int(min(16, max(4, round(2048 / size))))


def _sample_pattern(k: int):
    """k x k sub-pixel positions, and for each one a point on a disc used to
    spread the key light (so shadows come out soft)."""
    g = (np.arange(k) + 0.5) / k
    jx, jy = np.meshgrid(g, g[::-1])
    jx = np.roll(jx, 1, axis=1)  # decorrelate light samples from positions
    r = np.sqrt(jx)
    th = 2 * math.pi * jy
    return g, r * np.cos(th), r * np.sin(th)


def _shade(scene: Scene, p, n, edge, idx, view, lights, px_per_unit):
    cam = scene.camera
    key = hex_linear(scene.key_color) * scene.key_strength
    sky = hex_linear(scene.sky_color) * scene.sky_strength
    bounce = hex_linear(scene.bounce_color) * scene.bounce_strength
    fill = hex_linear(scene.fill_color) * scene.fill_strength

    # Shadows: every sample sends its own ray toward its point of the key light.
    start = p + n * 1e-5
    lit = np.ones(len(p))
    for sheet in scene.sheets:
        t_in, t_out, _, _ = sheet.intersect(start, lights)
        lit = np.where((t_out > 1e-6) & (t_in <= t_out), 0.0, lit)

    up = n[:, 2]
    ambient = (
        sky[None, :] * (0.55 + 0.45 * up)[:, None]
        + bounce[None, :] * (0.8 * np.maximum(-up, 0.0))[:, None]
        + fill[None, :] * np.maximum(n @ cam.to_world(scene.fill_light), 0.0)[:, None]
    )
    diffuse = key[None, :] * (np.maximum(_dot(n, lights), 0.0) * lit)[:, None]
    half = lights + view
    half /= np.linalg.norm(half, axis=1)[:, None]
    n_dot_h = np.maximum(_dot(n, half), 0.0)

    color = np.zeros(p.shape)
    for k, sheet in enumerate(scene.sheets):
        sel = idx == k
        if not np.any(sel):
            continue
        mat = sheet.material
        q = p[sel] - sheet.c
        on_edge = edge[sel]
        albedo = np.where(on_edge[:, None], hex_linear(mat.edge)[None, :], hex_linear(mat.face)[None, :])
        tone = np.ones(len(q))
        axial = q @ sheet.a

        if mat.plies:
            # Plies and glue lines across the cut edge, faded out where a ply
            # would be thinner than a couple of pixels.
            ply_px = (2 * sheet.h / mat.plies) * px_per_unit
            fade = float(np.clip((ply_px - 1.5) / 3.0, 0.0, 1.0))
            f = np.clip((axial + sheet.h) / (2 * sheet.h), 0, 1) * mat.plies
            which = np.minimum(np.floor(f), mat.plies - 1)
            frac = f - np.floor(f)
            ply = np.where(which % 2 == 0, 1.0, 1.0 - mat.ply_contrast)
            glue = ((frac < 0.1) & (which > 0)) | ((frac > 0.9) & (which < mat.plies - 1))
            ply = ply * np.where(glue, 1.0 - mat.glue_line, 1.0)
            tone = np.where(on_edge, 1.0 + (ply - 1.0) * fade, tone)

        if mat.grain:
            u = q @ sheet.u
            v = q @ sheet.v
            fade = float(np.clip((px_per_unit * 0.03 - 0.8) / 2.0, 0.0, 1.0))
            ph = sheet.grain_phase
            wobble = 0.6 * np.sin(v * 2.3 + ph) + 0.25 * np.sin(v * 5.1 + 1.7 * ph)
            grain = (np.sin(2 * math.pi * (u * 9.0 + wobble)) * 0.5 + 0.5) ** 3
            tone = np.where(on_edge, tone, 1.0 - mat.grain * fade * grain)

        if mat.face_rim:
            radial = np.linalg.norm(q - axial[:, None] * sheet.a[None, :], axis=1)
            rim = np.clip(1.0 - (sheet.radius - radial) / mat.face_rim, 0.0, 1.0) ** 1.5
            rim = np.where(on_edge, 0.0, rim * mat.face_rim_strength)
            albedo = albedo * (1 - rim)[:, None] + hex_linear(mat.edge)[None, :] * rim[:, None]

        light = diffuse[sel] + ambient[sel]
        if mat.edge_glow:
            light = light + np.where(on_edge, mat.edge_glow, 0.0)[:, None]
        spec = mat.specular * n_dot_h[sel] ** mat.shininess * lit[sel]
        shaded = albedo * tone[:, None] * light + spec[:, None] * key[None, :]

        if mat.gloss:
            ns, vs = n[sel], view[sel]
            n_dot_v = np.clip(_dot(ns, vs), 0.0, 1.0)
            refl = 2.0 * n_dot_v[:, None] * ns - vs
            ang = np.degrees(np.arctan2(refl @ cam.r, refl @ cam.w))
            az0, half_w = scene.softbox
            strip = np.exp(-(((ang - az0) / half_w) ** 4)) * np.clip((0.85 - refl @ cam.up) / 0.25, 0.0, 1.0)
            fresnel = 0.06 + 0.94 * (1.0 - n_dot_v) ** 5
            shaded = shaded + (mat.gloss * scene.softbox_strength * strip * (0.35 + fresnel))[:, None]
        color[sel] = shaded
    return color


def render(scene: Scene, size: int, samples: int | None = None) -> np.ndarray:
    """Render at `size` x `size` px. Returns straight-alpha sRGB RGBA floats."""
    k = samples or _samples_per_side(size)
    px = CANVAS / size  # canvas units per pixel
    px_per_unit = scene.camera.scale / px
    sub, jx, jy = _sample_pattern(k)
    cam = scene.camera
    key = cam.to_world(scene.key_light)
    ref = np.array([0.0, 0.0, 1.0]) if abs(key[2]) < 0.9 else np.array([1.0, 0.0, 0.0])
    e1 = _unit(np.cross(key, ref))
    e2 = np.cross(key, e1)
    spread = math.tan(math.radians(scene.key_softness_deg))
    top, bottom = hex_linear(scene.body_top), hex_linear(scene.body_bottom)

    out = np.zeros((size, size, 4))
    rows_per_chunk = max(1, 1_500_000 // (size * k * k))
    for row0 in range(0, size, rows_per_chunk):
        rows = min(rows_per_chunk, size - row0)
        # Samples laid out as [row, sub-row, column, sub-column].
        Yg = (np.arange(row0, row0 + rows)[:, None, None, None] + sub[None, :, None, None]) * px
        Xg = (np.arange(size)[None, None, :, None] + sub[None, None, None, :]) * px
        Yg, Xg = np.broadcast_arrays(Yg, Xg)
        X, Y = Xg.reshape(-1), Yg.reshape(-1)
        si = np.broadcast_to(np.arange(k)[None, :, None, None], Yg.shape).reshape(-1)
        sj = np.broadcast_to(np.arange(k)[None, None, None, :], Yg.shape).reshape(-1)
        lights = key[None, :] + spread * (jx[si, sj][:, None] * e1[None, :] + jy[si, sj][:, None] * e2[None, :])
        lights /= np.linalg.norm(lights, axis=1)[:, None]

        # The body: vertical gradient, a soft glow, a light rim along the top
        # edge and a darker one along the bottom, and the form's floor shadow.
        inside = body_inside(X, Y).astype(np.float64)
        tgrad = np.clip((Y - (CANVAS / 2 - BODY_HALF)) / (2 * BODY_HALF), 0, 1)
        color = top[None, :] * (1 - tgrad)[:, None] + bottom[None, :] * tgrad[:, None]
        gx, gy, gr, gs = scene.body_glow
        color = color * (1.0 + gs * np.exp(-((X - gx) ** 2 + (Y - gy) ** 2) / (gr * gr)))[:, None]
        rim = np.exp(-np.maximum(-body_distance(X, Y), 0.0) / 5.0) * inside
        rim_light = 0.35 * np.clip((CANVAS / 2 - Y) / BODY_HALF, 0, 1) - 0.25 * np.clip((Y - CANVAS / 2) / BODY_HALF, 0, 1)
        color = color * (1.0 + rim * rim_light)[:, None]
        fx, fy, frx, fry, fo = scene.floor_shadow
        qd = ((X - fx) / frx) ** 2 + ((Y - fy) / fry) ** 2
        color = color * (1.0 - fo * (0.65 * np.exp(-qd * 2.2) + 0.35 * np.exp(-qd * 0.7)))[:, None]

        # The form: nearest sheet along each ray.
        o, d = cam.rays(X, Y)
        d = np.broadcast_to(d, o.shape)
        best = np.full(X.size, np.inf)
        idx = np.full(X.size, -1, dtype=np.int32)
        normal = np.zeros((X.size, 3))
        edge = np.zeros(X.size, dtype=bool)
        for i, sheet in enumerate(scene.sheets):
            t_in, t_out, nrm, on_edge = sheet.intersect(o, d)
            hit = (t_in <= t_out) & (t_in > 0) & (t_in < best)
            best = np.where(hit, t_in, best)
            idx = np.where(hit, i, idx)
            normal = np.where(hit[:, None], nrm, normal)
            edge = np.where(hit, on_edge, edge)
        hit = idx >= 0
        if np.any(hit):
            p = o[hit] + best[hit][:, None] * d[hit]
            color[hit] = _shade(scene, p, normal[hit], edge[hit], idx[hit], -d[hit], lights[hit], px_per_unit)
            inside = np.where(hit, 1.0, inside)

        # Average each pixel's samples (premultiplied, in linear light).
        prem = (_tonemap(color) * inside[:, None]).reshape(rows, k, size, k, 3).mean(axis=(1, 3))
        alpha = inside.reshape(rows, k, size, k).mean(axis=(1, 3))

        # The body's drop shadow, outside the body: soft and a little lower.
        Yc, Xc = np.broadcast_arrays(
            (np.arange(row0, row0 + rows)[:, None] + 0.5) * px, (np.arange(size)[None, :] + 0.5) * px
        )
        shadow = 0.32 / (1.0 + np.exp(1.702 * body_distance(Xc, Yc - 10.0) / 9.0))
        a_out = alpha + shadow * (1 - alpha)
        with np.errstate(invalid="ignore", divide="ignore"):
            straight = np.where(a_out[..., None] > 0, prem / a_out[..., None], 0.0)
        out[row0 : row0 + rows, :, :3] = linear_to_srgb(straight)
        out[row0 : row0 + rows, :, 3] = a_out
    return out


# -------------------------------------------------------------- the icon --


BIRCH = Material(
    face="#EBD3A6",
    edge="#B0743F",
    plies=3,
    ply_contrast=0.12,
    glue_line=0.38,
    grain=0.07,
    face_rim=0.022,
)
ACRYLIC = Material(
    face="#FF6A1F",
    edge="#FF7A2E",
    specular=0.55,
    shininess=70.0,
    edge_glow=0.35,
    gloss=1.0,
)


def icon_scene(size: int) -> Scene:
    """A sphere of nine stacked sheets (fewer at small sizes), the middle one
    acrylic and the top one lifted and tipped as it is set in place."""
    layers = 9 if size >= 64 else 7 if size >= 32 else 5
    lift = 0.0 if size <= 16 else 0.6  # in sheet thicknesses
    grow = 1.10 if size <= 16 else 1.06 if size <= 32 else 1.0
    tip = math.radians(7.0)
    tip_toward = -0.95  # world azimuth (radians) the lifted sheet tips toward
    t = 2.0 / layers  # unit sphere
    sheets = []
    for i in range(layers):
        z = -1.0 + (i + 0.5) * t
        radius = max(math.sqrt(max(1.0 - z * z, 0.0)), 0.32)
        axis, center = (0.0, 0.0, 1.0), (0.0, 0.0, z)
        if i == layers - 1 and lift:
            axis = (math.sin(tip) * math.cos(tip_toward), math.sin(tip) * math.sin(tip_toward), math.cos(tip))
            center = (0.0, 0.0, z + lift * t)
        sheets.append(
            Sheet(center, axis, radius, t, ACRYLIC if i == layers // 2 else BIRCH, grain_phase=1.3 * i)
        )
    return Scene(
        camera=Camera(azimuth_deg=-30.0, elevation_deg=27.0, canvas_center=(512.0, 500.0), scale=272.0 * grow),
        sheets=sheets,
        body_top="#2B4F8C",
        body_bottom="#14264D",
        body_glow=(400.0, 300.0, 420.0, 0.25),
        floor_shadow=(512.0, 846.0, 240.0, 32.0, 0.7),
    )


# ----------------------------------------------------------------- files --


def write_png(path: Path, rgba: np.ndarray) -> None:
    """Write straight-alpha RGBA floats as an 8-bit PNG with no metadata."""
    data = np.clip(np.round(rgba * 255.0), 0, 255).astype(np.uint8)
    h, w, _ = data.shape
    raw = b"".join(b"\x00" + data[y].tobytes() for y in range(h))

    def chunk(tag: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def preview_sheet(renders: dict, background, magnify: int = 8, gap: int = 48) -> np.ndarray:
    """The renders side by side at 1:1 on `background` (sRGB 0..1), with the
    32 and 16 px ones repeated below, enlarged `magnify` times."""
    sizes = sorted(renders, reverse=True)
    small = [s for s in sizes if s <= 32]
    top_h = max(sizes) + 2 * gap
    width = max(sum(sizes) + gap * (len(sizes) + 1), sum(s * magnify for s in small) + gap * (len(small) + 1))
    height = top_h + (max(small) * magnify + gap if small else 0)
    sheet = np.ones((height, width, 4))
    sheet[..., :3] = background

    def place(img, x, y):
        a = img[..., 3:4]
        h, w, _ = img.shape
        sheet[y : y + h, x : x + w, :3] = img[..., :3] * a + sheet[y : y + h, x : x + w, :3] * (1 - a)

    x = gap
    for s in sizes:
        place(renders[s], x, gap + max(sizes) - s)
        x += s + gap
    x = gap
    for s in small:
        place(np.repeat(np.repeat(renders[s], magnify, axis=0), magnify, axis=1), x, top_h)
        x += s * magnify + gap
    return sheet


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Draw the Refab Artist app icon and build AppIcon.icns.")
    ap.add_argument("--icns", type=Path, default=DEFAULT_ICNS, help="where to write AppIcon.icns")
    ap.add_argument("--no-icns", action="store_true", help="do not render the iconset or build the .icns")
    ap.add_argument("--iconset", type=Path, help="keep the AppIcon.iconset PNGs in this directory")
    ap.add_argument("--png-dir", type=Path, help="write icon-<size>.png for each --sizes value here")
    ap.add_argument("--sizes", type=int, nargs="+", default=[1024, 128, 32, 16])
    ap.add_argument("--preview", type=Path, help="write preview-light.png and preview-dark.png here")
    args = ap.parse_args(argv)

    cache: dict[int, np.ndarray] = {}

    def rendered(size: int) -> np.ndarray:
        if size not in cache:
            cache[size] = render(icon_scene(size), size)
        return cache[size]

    if args.png_dir:
        args.png_dir.mkdir(parents=True, exist_ok=True)
        for size in args.sizes:
            write_png(args.png_dir / f"icon-{size}.png", rendered(size))
    if args.preview:
        args.preview.mkdir(parents=True, exist_ok=True)
        renders = {s: rendered(s) for s in (1024, 128, 32, 16)}
        for name, bg in (("light", (0.949, 0.949, 0.969)), ("dark", (0.118, 0.118, 0.125))):
            write_png(args.preview / f"preview-{name}.png", preview_sheet(renders, bg))

    if args.no_icns and not args.iconset:
        return 0
    with tempfile.TemporaryDirectory() as tmp:
        iconset = args.iconset if args.iconset else Path(tmp)
        if iconset.suffix != ".iconset":
            iconset = iconset / "AppIcon.iconset"
        iconset.mkdir(parents=True, exist_ok=True)
        for name, size in ICONSET:
            write_png(iconset / name, rendered(size))
        if not args.no_icns:
            if shutil.which("iconutil") is None:
                print("make_app_icon: iconutil not found (it ships with macOS)", file=sys.stderr)
                return 1
            args.icns.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(args.icns)], check=True)
            print(f"wrote {args.icns}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
