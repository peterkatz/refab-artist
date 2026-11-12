from __future__ import annotations

from pathlib import Path

import pytest

from tools.benchmark_exports import (
    DEFAULT_CASES,
    BenchmarkCase,
    RunRecord,
    command_for_case,
    list_cases,
    render_markdown,
    select_cases,
    summarize_runs,
)


REPO_ROOT = Path(__file__).resolve().parents[2]


def test_default_benchmark_fixtures_exist():
    missing = [case.fixture for case in DEFAULT_CASES if not (REPO_ROOT / case.fixture).exists()]

    assert missing == []


def test_select_cases_preserves_requested_order():
    selected = select_cases(["three_d_torus_stl", "stacked_dense_sphere_svg"])

    assert [case.case_id for case in selected] == [
        "three_d_torus_stl",
        "stacked_dense_sphere_svg",
    ]


def test_select_cases_rejects_unknown_id():
    with pytest.raises(ValueError, match="unknown benchmark case"):
        select_cases(["no_such_case"])


def test_command_for_case_threads_headless_export_arguments(tmp_path):
    case = BenchmarkCase(
        case_id="example",
        fixture="tests/fixtures/cube_ascii.stl",
        mode="stacked",
        format="svg",
        args=("--axis", "z", "--thickness", "5"),
    )
    command = command_for_case(
        executable=Path("/tmp/RefabArtist"),
        case=case,
        output_path=tmp_path / "out.svg",
        measurement_path=tmp_path / "out.json",
    )

    assert command[:6] == [
        "/tmp/RefabArtist",
        "--headless-export",
        "--mode",
        "stacked",
        "--format",
        "svg",
    ]
    assert "--fixture" in command
    assert str(REPO_ROOT / "tests/fixtures/cube_ascii.stl") in command
    assert command[-4:] == ["--axis", "z", "--thickness", "5"]


def test_summarize_runs_reports_median_and_output_range():
    summary = summarize_runs(
        [
            RunRecord(elapsed_seconds=0.8, output_bytes=100, measurement={}),
            RunRecord(elapsed_seconds=1.2, output_bytes=120, measurement={}),
            RunRecord(elapsed_seconds=1.0, output_bytes=110, measurement={}),
        ]
    )

    assert summary["iterations"] == 3
    assert summary["min_seconds"] == 0.8
    assert summary["median_seconds"] == 1.0
    assert summary["mean_seconds"] == 1.0
    assert summary["max_seconds"] == 1.2
    assert summary["output_bytes_min"] == 100
    assert summary["output_bytes_max"] == 120


def test_render_markdown_includes_case_table():
    markdown = render_markdown(
        {
            "generated_at": "2026-06-02T00:00:00+00:00",
            "iterations": 3,
            "warmups": 1,
            "cases": [
                {
                    "case_id": "stacked_dense_sphere_svg",
                    "mode": "stacked",
                    "format": "svg",
                    "note": "Dense case.",
                    "summary": {
                        "min_seconds": 0.8,
                        "median_seconds": 1.0,
                        "mean_seconds": 1.05,
                        "max_seconds": 1.2,
                        "output_bytes_min": 100,
                        "output_bytes_max": 100,
                    },
                }
            ],
        }
    )

    assert "| stacked_dense_sphere_svg | stacked | svg | 1.000 | 1.050 | 0.800 | 1.200 | 100-100 |" in markdown
    assert "- `stacked_dense_sphere_svg`: Dense case." in markdown


def test_list_cases_emits_machine_readable_rows():
    rows = list_cases(DEFAULT_CASES).splitlines()

    assert rows
    assert rows[0].split("\t")[:3] == [
        "stacked_dense_sphere_svg",
        "stacked",
        "svg",
    ]
