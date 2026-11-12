#!/usr/bin/env python3
"""Run repeatable local benchmarks for Refab Artist headless exports.

The benchmark intentionally stays out of CI gating. It measures wall-clock
time on the current machine, records raw run data as JSON, and optionally emits
a small Markdown summary that can be pasted into Linear or a release note.
"""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Sequence


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[1]
APP_PACKAGE = REPO_ROOT / "app" / "RefabArtist"
DEFAULT_OUTPUT_DIR = REPO_ROOT / ".benchmark-output"


@dataclass(frozen=True)
class BenchmarkCase:
    case_id: str
    fixture: str
    mode: str
    format: str
    args: tuple[str, ...] = field(default_factory=tuple)
    note: str = ""

    @property
    def output_extension(self) -> str:
        return self.format


@dataclass(frozen=True)
class RunRecord:
    elapsed_seconds: float
    output_bytes: int
    measurement: dict[str, Any]


DEFAULT_CASES: tuple[BenchmarkCase, ...] = (
    BenchmarkCase(
        case_id="stacked_dense_sphere_svg",
        fixture="tests/fixtures/stress/sphere_dense_d50mm.stl",
        mode="stacked",
        format="svg",
        args=("--axis", "z", "--thickness", "5"),
        note="Dense 107k-triangle import plus stacked contour/vector export.",
    ),
    BenchmarkCase(
        case_id="interlocked_gear_svg",
        fixture="tests/fixtures/real-world/spur_gear_T20_M2.stl",
        mode="interlocked",
        format="svg",
        args=(
            "--axis",
            "z",
            "--secondary-axis",
            "x",
            "--thickness",
            "5",
            "--slot-clearance",
            "0.2",
        ),
        note="Feature-rich real-world outline with interlocked slot planning.",
    ),
    BenchmarkCase(
        case_id="three_d_torus_stl",
        fixture="tests/fixtures/primitives/torus_R30_r10mm.stl",
        mode="threeD",
        format="stl",
        args=("--thickness", "5"),
        note="Genus-1 model through 3D slices mesh export.",
    ),
    BenchmarkCase(
        case_id="folded_chair_obj",
        fixture="tests/fixtures/real-world/simple_chair.stl",
        mode="foldedPanels",
        format="obj",
        args=("--thickness", "5"),
        note="Representative multi-part folded panel mesh export.",
    ),
)


def build_release_app() -> Path:
    subprocess.run(
        ["swift", "build", "--package-path", str(APP_PACKAGE), "-c", "release"],
        check=True,
        cwd=REPO_ROOT,
    )
    executable = APP_PACKAGE / ".build" / "release" / "RefabArtist"
    if not executable.exists():
        raise FileNotFoundError(f"release executable not found: {executable}")
    return executable


def select_cases(case_ids: Sequence[str] | None) -> list[BenchmarkCase]:
    cases_by_id = {case.case_id: case for case in DEFAULT_CASES}
    if not case_ids:
        return list(DEFAULT_CASES)

    selected: list[BenchmarkCase] = []
    missing: list[str] = []
    for case_id in case_ids:
        case = cases_by_id.get(case_id)
        if case is None:
            missing.append(case_id)
        else:
            selected.append(case)
    if missing:
        valid = ", ".join(sorted(cases_by_id))
        raise ValueError(f"unknown benchmark case(s): {', '.join(missing)}. Valid: {valid}")
    return selected


def command_for_case(
    executable: Path,
    case: BenchmarkCase,
    output_path: Path,
    measurement_path: Path,
) -> list[str]:
    return [
        str(executable),
        "--headless-export",
        "--mode",
        case.mode,
        "--format",
        case.format,
        "--fixture",
        str(REPO_ROOT / case.fixture),
        "--output",
        str(output_path),
        "--measurement",
        str(measurement_path),
        *case.args,
    ]


def run_case_once(
    executable: Path,
    case: BenchmarkCase,
    run_dir: Path,
    run_index: int,
) -> RunRecord:
    run_dir.mkdir(parents=True, exist_ok=True)
    output_path = run_dir / f"{case.case_id}-{run_index}.{case.output_extension}"
    measurement_path = run_dir / f"{case.case_id}-{run_index}.measurement.json"

    command = command_for_case(executable, case, output_path, measurement_path)
    start = time.perf_counter()
    subprocess.run(command, check=True, cwd=REPO_ROOT)
    elapsed = time.perf_counter() - start

    measurement = json.loads(measurement_path.read_text(encoding="utf-8"))
    return RunRecord(
        elapsed_seconds=elapsed,
        output_bytes=output_path.stat().st_size,
        measurement=measurement,
    )


def summarize_runs(runs: Sequence[RunRecord]) -> dict[str, Any]:
    if not runs:
        raise ValueError("cannot summarize an empty run set")

    timings = [run.elapsed_seconds for run in runs]
    output_sizes = [run.output_bytes for run in runs]
    return {
        "iterations": len(runs),
        "min_seconds": min(timings),
        "median_seconds": statistics.median(timings),
        "mean_seconds": statistics.fmean(timings),
        "max_seconds": max(timings),
        "output_bytes_min": min(output_sizes),
        "output_bytes_max": max(output_sizes),
    }


def benchmark(
    executable: Path,
    cases: Sequence[BenchmarkCase],
    output_dir: Path,
    iterations: int,
    warmups: int,
) -> dict[str, Any]:
    if iterations <= 0:
        raise ValueError("--iterations must be greater than zero")
    if warmups < 0:
        raise ValueError("--warmups must be zero or greater")

    output_dir.mkdir(parents=True, exist_ok=True)
    case_results: list[dict[str, Any]] = []
    for case in cases:
        for warmup_index in range(warmups):
            run_case_once(executable, case, output_dir / case.case_id / "warmups", warmup_index)

        runs: list[RunRecord] = []
        for run_index in range(iterations):
            runs.append(run_case_once(executable, case, output_dir / case.case_id / "runs", run_index))

        case_results.append(
            {
                "case_id": case.case_id,
                "fixture": case.fixture,
                "mode": case.mode,
                "format": case.format,
                "args": list(case.args),
                "note": case.note,
                "summary": summarize_runs(runs),
                "runs": [
                    {
                        "iteration": index,
                        "elapsed_seconds": run.elapsed_seconds,
                        "output_bytes": run.output_bytes,
                        "measurement": compact_measurement(run.measurement),
                    }
                    for index, run in enumerate(runs)
                ],
            }
        )

    return {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "repo_root": str(REPO_ROOT),
        "app_package": str(APP_PACKAGE),
        "executable": str(executable),
        "iterations": iterations,
        "warmups": warmups,
        "cases": case_results,
    }


def compact_measurement(measurement: dict[str, Any]) -> dict[str, Any]:
    compact: dict[str, Any] = {
        "mode": measurement.get("mode"),
        "mesh": measurement.get("mesh"),
        "exports": measurement.get("exports"),
    }
    for key in (
        "stacked_slices",
        "interlocked_slices",
        "radial_slices",
        "curve_slices",
        "three_d_slices",
        "folded_panels",
    ):
        if key in measurement:
            compact[key] = measurement[key]
    return compact


def render_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Refab Artist Performance Benchmark",
        "",
        f"- Generated: `{report['generated_at']}`",
        f"- Iterations: `{report['iterations']}`",
        f"- Warmups: `{report['warmups']}`",
        "",
        "| Case | Mode | Format | Median s | Mean s | Min s | Max s | Output bytes |",
        "|---|---|---|---:|---:|---:|---:|---:|",
    ]
    for case in report["cases"]:
        summary = case["summary"]
        lines.append(
            "| {case_id} | {mode} | {format} | {median:.3f} | {mean:.3f} | "
            "{min_s:.3f} | {max_s:.3f} | {bytes_min}-{bytes_max} |".format(
                case_id=case["case_id"],
                mode=case["mode"],
                format=case["format"],
                median=summary["median_seconds"],
                mean=summary["mean_seconds"],
                min_s=summary["min_seconds"],
                max_s=summary["max_seconds"],
                bytes_min=summary["output_bytes_min"],
                bytes_max=summary["output_bytes_max"],
            )
        )
    lines.append("")
    lines.append("## Cases")
    lines.append("")
    for case in report["cases"]:
        lines.append(f"- `{case['case_id']}`: {case['note']}")
    lines.append("")
    return "\n".join(lines)


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def list_cases(cases: Iterable[BenchmarkCase]) -> str:
    return "\n".join(
        f"{case.case_id}\t{case.mode}\t{case.format}\t{case.fixture}\t{case.note}"
        for case in cases
    )


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", action="append", dest="cases", help="Benchmark case id. Repeat to select multiple cases.")
    parser.add_argument("--iterations", type=int, default=3, help="Measured iterations per case.")
    parser.add_argument("--warmups", type=int, default=1, help="Warmup iterations per case, excluded from summaries.")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR, help="Directory for per-run exports and measurements.")
    parser.add_argument("--json", type=Path, default=DEFAULT_OUTPUT_DIR / "benchmark.json", help="Benchmark JSON report path.")
    parser.add_argument("--markdown", type=Path, help="Optional Markdown report path.")
    parser.add_argument("--executable", type=Path, help="Use an existing RefabArtist executable instead of building release.")
    parser.add_argument("--skip-build", action="store_true", help="Use the default release executable without invoking swift build.")
    parser.add_argument("--list-cases", action="store_true", help="List benchmark cases and exit.")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    if args.list_cases:
        print(list_cases(DEFAULT_CASES))
        return 0

    cases = select_cases(args.cases)
    if args.executable:
        executable = args.executable
    elif args.skip_build:
        executable = APP_PACKAGE / ".build" / "release" / "RefabArtist"
    else:
        executable = build_release_app()

    if not executable.exists():
        raise FileNotFoundError(f"executable not found: {executable}")

    report = benchmark(
        executable=executable,
        cases=cases,
        output_dir=args.output_dir,
        iterations=args.iterations,
        warmups=args.warmups,
    )
    write_json(args.json, report)
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(render_markdown(report), encoding="utf-8")
    print(f"Wrote benchmark report: {args.json}")
    if args.markdown:
        print(f"Wrote benchmark summary: {args.markdown}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
