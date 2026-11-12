"""Tests for `tools/generate_matcaps.py`, which draws the viewport matcap images.

They pin the image contract the viewport shader relies on (size, format, which
pixels are the sphere, which way the light falls), check that the committed
PNGs are what the generator produces, and check the character of each style.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from tools import generate_matcaps as gm

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "tools" / "generate_matcaps.py"
NAMES = ["clay", "satin", "glossy", "toon"]
SMOOTH = ["clay", "satin", "glossy"]


def committed(name: str) -> Image.Image:
    return Image.open(gm.RESOURCES / f"matcap_{name}.png")


def disc_mask() -> np.ndarray:
    return gm.sphere_normals(gm.SIZE)[3]


def test_styles_cover_the_names_the_app_loads():
    # ViewportAppearanceSettings.ObjectMaterial loads "matcap_<style>" for each case.
    assert sorted(gm.STYLES) == sorted(NAMES)


@pytest.mark.parametrize("name", NAMES)
def test_committed_png_is_current(name):
    gray = gm.render(gm.STYLES[name])
    assert gm.is_current(gray, gm.RESOURCES / f"matcap_{name}.png")


@pytest.mark.parametrize("name", NAMES)
def test_png_follows_the_loader_contract(name):
    with committed(name) as im:
        assert im.size == (512, 512)
        assert im.mode == "RGBA"
        assert not im.info.get("transparency")
        px = np.asarray(im)
    assert px.dtype == np.uint8
    assert (px[..., 3] == 255).all()
    assert (px[..., 0] == px[..., 1]).all() and (px[..., 0] == px[..., 2]).all()
    inside = disc_mask()
    assert (px[..., 0][~inside] == 0).all()
    assert (px[..., 0][inside] > 0).all()


def test_pixel_to_normal_mapping_matches_the_shader():
    nx, ny, nz, inside = gm.sphere_normals(gm.SIZE)
    # The shader reads u = nx/2 + 1/2 and v = 1/2 - ny/2 (v down from the top),
    # so the top-left of the sphere faces left and up, and the middle faces the viewer.
    assert nx[100, 100] < 0 < ny[100, 100]
    assert nx[400, 400] > 0 > ny[400, 400]
    assert abs(nx[256, 256]) < 0.01 and abs(ny[256, 256]) < 0.01 and nz[256, 256] > 0.99
    assert not inside[0, 0] and inside[256, 256]
    assert np.allclose(nx[inside] ** 2 + ny[inside] ** 2 + nz[inside] ** 2, 1.0)


@pytest.mark.parametrize("name", NAMES)
def test_light_comes_from_the_upper_left(name):
    gray = gm.render(gm.STYLES[name]).astype(float)
    ys, xs = np.nonzero(gray >= gray.max() - 1)
    assert xs.mean() < 256 and ys.mean() < 256
    # The shadow side is the opposite quadrant.
    inside = disc_mask()
    lit = gray[:256, :256][inside[:256, :256]].mean()
    dark = gray[256:, 256:][inside[256:, 256:]].mean()
    assert lit > dark + 40


@pytest.mark.parametrize("name", SMOOTH)
def test_smooth_styles_are_smooth(name):
    gray = gm.render(gm.STYLES[name]).astype(int)
    nx, ny, _, inside = gm.sphere_normals(gm.SIZE)
    assert len(np.unique(gray[inside])) > 150
    # Away from the edge of the disc, neighbouring pixels differ by a few levels at most.
    well_inside = np.hypot(nx, ny) < 0.97
    for axis in (0, 1):
        step = np.abs(np.diff(gray, axis=axis))
        both = np.take(well_inside, range(1, gray.shape[axis]), axis=axis) & np.take(
            well_inside, range(0, gray.shape[axis] - 1), axis=axis
        )
        assert step[both].max() <= 12


def test_toon_is_four_flat_tones():
    gray = gm.render(gm.STYLES["toon"])
    values = np.unique(gray[disc_mask()])
    assert len(values) == 4 and values[-1] == 255


def test_highlight_gets_tighter_from_clay_to_glossy():
    def bright_area(name):
        return int((gm.render(gm.STYLES[name]) >= 250).sum())

    assert bright_area("clay") > bright_area("satin") > bright_area("glossy") > 0


def test_clay_is_the_lightest_smooth_style_and_glossy_the_darkest():
    inside = disc_mask()
    mean = {n: gm.render(gm.STYLES[n])[inside].mean() for n in SMOOTH}
    assert mean["clay"] > mean["satin"] > mean["glossy"]
    assert all(60 < m < 200 for m in mean.values())


def test_generation_is_deterministic():
    a = gm.render(gm.STYLES["glossy"])
    b = gm.render(gm.STYLES["glossy"])
    assert np.array_equal(a, b)


def test_check_mode_reports_stale_files(tmp_path):
    ok = subprocess.run([sys.executable, str(SCRIPT), "--check"], capture_output=True, text=True)
    assert ok.returncode == 0, ok.stdout + ok.stderr

    # A directory with one altered file and one missing file is stale.
    for name in NAMES[:3]:
        (tmp_path / f"matcap_{name}.png").write_bytes((gm.RESOURCES / f"matcap_{name}.png").read_bytes())
    with Image.open(tmp_path / "matcap_clay.png") as im:
        altered = np.asarray(im).copy()
    altered[256, 256, :3] = 0
    Image.fromarray(altered).save(tmp_path / "matcap_clay.png")
    bad = subprocess.run([sys.executable, str(SCRIPT), "--check", "--out", str(tmp_path)], capture_output=True, text=True)
    assert bad.returncode == 1
    assert bad.stdout.count("STALE") == 2


def test_write_mode_round_trips(tmp_path):
    done = subprocess.run([sys.executable, str(SCRIPT), "--out", str(tmp_path)], capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    for name in NAMES:
        assert gm.is_current(gm.render(gm.STYLES[name]), tmp_path / f"matcap_{name}.png")
        with Image.open(tmp_path / f"matcap_{name}.png") as im:
            assert im.info == {}  # no metadata


def test_torus_normals_are_unit_and_face_the_viewer_mostly():
    nx, ny, nz, hit = gm.torus_normals(160)
    assert hit.sum() > 3000
    length = np.sqrt(nx[hit] ** 2 + ny[hit] ** 2 + nz[hit] ** 2)
    assert np.allclose(length, 1.0, atol=1e-6)
    assert (nz[hit] > -0.1).all()


def test_apply_matcap_stays_in_range_and_keeps_the_highlight_white():
    gray = gm.render(gm.STYLES["glossy"])
    nx, ny, nz, inside = gm.sphere_normals(64)
    rgb = gm.apply_matcap(gray, nx, ny, inside, tint=(0.13, 0.52, 0.55))
    assert rgb.min() >= 0.0 and rgb.max() <= 1.0
    # The brightest spot of a teal ball is white, not teal.
    top = rgb[np.unravel_index(np.argmax(rgb.sum(axis=-1) * inside), inside.shape)]
    assert top.min() > 0.9
