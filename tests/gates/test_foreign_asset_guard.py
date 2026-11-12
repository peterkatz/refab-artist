"""The foreign-asset guard blocks other software's files by type and path.

Each test builds a throwaway git repository holding a copy of
scripts/check-no-foreign-assets.sh, stages files into it and runs the guard
the way the pre-commit hook (--staged) and the maintainer (--all) do.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "scripts/check-no-foreign-assets.sh"

MACHO_64 = bytes.fromhex("cffaedfe0c000001") + b"\0" * 56
MACHO_32_BE = bytes.fromhex("feedface00000007") + b"\0" * 56
FAT_MACHO = bytes.fromhex("cafebabe00000002") + b"\0" * 56
ELF = b"\x7fELF\x02\x01\x01" + b"\0" * 57
STATIC_ARCHIVE = b"!<arch>\n" + b"\0" * 56
PNG = bytes.fromhex("89504e470d0a1a0a") + b"\0" * 56


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
    return subprocess.run(["git", *args], cwd=repo, env=env, check=True, capture_output=True, text=True)


@pytest.fixture()
def repo(tmp_path: Path) -> Path:
    _git(tmp_path, "init", "-q")
    (tmp_path / "scripts").mkdir()
    shutil.copy2(GUARD, tmp_path / "scripts/check-no-foreign-assets.sh")
    (tmp_path / "README.md").write_text("project readme\n")
    (tmp_path / "Vendor").mkdir()
    (tmp_path / "Vendor/libmanifold.a").write_bytes(STATIC_ARCHIVE)
    (tmp_path / "Resources").mkdir()
    (tmp_path / "Resources/matcap.png").write_bytes(PNG)
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs/physical-calibration.md").write_text("cut a test piece\n")
    _git(tmp_path, "add", "-A")
    return tmp_path


def _add(repo: Path, relpath: str, content: bytes) -> None:
    path = repo / relpath
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    _git(repo, "add", "--", relpath)


def _guard(repo: Path, mode: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", "scripts/check-no-foreign-assets.sh", mode],
        cwd=repo, capture_output=True, text=True,
    )


@pytest.mark.parametrize("mode", ["--all", "--staged"])
def test_project_files_pass(repo: Path, mode: str):
    result = _guard(repo, mode)
    assert result.returncode == 0, result.stderr
    assert "OK" in result.stdout


@pytest.mark.parametrize(
    ("relpath", "content", "reason"),
    [
        ("Thing.app/Contents/Info.plist", b"<plist/>\n", "bundle"),
        ("stash/Contents/MacOS/Thing", b"#!/bin/sh\n", "application bundle"),
        ("stash/Contents/Resources/strings.txt", b"text\n", "application bundle"),
        ("Kit.framework/Headers/Kit.h", b"// header\n", "bundle"),
        ("ui/MainMenu.nib", b"nib\n", "interface file"),
        ("ui/Panel.xib", b"<xib/>\n", "interface file"),
        ("ui/Main.storyboard", b"<doc/>\n", "interface file"),
        ("art/AppIcon.ICNS", b"icns", "icon"),
        ("art/Assets.car", b"car", "asset catalog"),
        ("lib/libThing.dylib", b"text that is not a binary\n", "dynamic library"),
        ("dist/Installer.pkg", b"xar!", "installer"),
        ("docs/ThingHelp.pdf", b"%PDF-1.4\n", "help document"),
        ("docs/User_Guide.pdf", b"%PDF-1.4\n", "help document"),
        ("bin/tool", MACHO_64, "Mach-O binary"),
        ("bin/tool32", MACHO_32_BE, "Mach-O binary"),
        ("bin/universal", FAT_MACHO, "universal"),
        ("bin/linux-tool", ELF, "ELF binary"),
    ],
)
@pytest.mark.parametrize("mode", ["--all", "--staged"])
def test_foreign_files_fail(repo: Path, mode: str, relpath: str, content: bytes, reason: str):
    _add(repo, relpath, content)
    result = _guard(repo, mode)
    assert result.returncode == 1, result.stdout + result.stderr
    assert relpath in result.stderr
    assert reason in result.stderr


@pytest.mark.parametrize("mode", ["--all", "--staged"])
def test_the_apps_own_icon_is_allowed(repo: Path, mode: str):
    _add(repo, "app/RefabArtist/Packaging/AppIcon.icns", b"icns")
    result = _guard(repo, mode)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize(
    "relpath",
    [
        "app/RefabArtist/Packaging/Other.icns",
        "app/RefabArtist/AppIcon.icns",
        "elsewhere/app/RefabArtist/Packaging/AppIcon.icns",
    ],
)
def test_the_icon_allowance_covers_only_its_own_path(repo: Path, relpath: str):
    _add(repo, relpath, b"icns")
    result = _guard(repo, "--all")
    assert result.returncode == 1
    assert relpath in result.stderr


def test_staged_check_reads_the_index(repo: Path):
    # A binary staged and then overwritten in the working tree is still what
    # the commit would contain.
    _add(repo, "bin/tool", MACHO_64)
    (repo / "bin/tool").write_text("harmless now\n")
    result = _guard(repo, "--staged")
    assert result.returncode == 1
    assert "Mach-O binary" in result.stderr


def test_usage_error(repo: Path):
    result = _guard(repo, "--everything")
    assert result.returncode == 2
    assert "usage" in result.stderr
