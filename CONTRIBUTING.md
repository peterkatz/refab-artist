# Contributing to Refab Artist

Refab Artist is a native macOS fabrication app for Apple Silicon. Contributions
are welcome. This guide covers how to build and check a change, and the terms
contributions are accepted under.

## Development setup

You need a Mac with Apple Silicon running macOS 15 or newer and a Swift 6
toolchain (Xcode). The app is a Swift package at `app/RefabArtist`.
Manifold and Clipper2 are vendored as prebuilt static libraries under
`app/RefabArtist/Vendor/Manifold`, so there is nothing else to install for
the app itself.

```console
swift build --package-path app/RefabArtist
swift run --package-path app/RefabArtist RefabArtist
```

The Python tooling (the gates, the benchmark, the fixture generators and their
tests) needs the packages listed in `tools/requirements.txt`:

```console
python3 -m pip install -r tools/requirements.txt
```

## Local gates

There is no cloud CI. Run the gates on your own machine before proposing a
change:

```console
swift test --package-path app/RefabArtist
python3 scripts/functional_gate.py
```

- `swift test` runs the whole Swift test suite. If the branch you started from
  already has failing tests, note that baseline first; a change must not add
  failures to it.
- `scripts/functional_gate.py` is the ship gate: each construction mode's
  output must fit its sheet, not overlap, form valid closed contours, and keep
  connectors inside the material. See `docs/functional-gate.md`. Without
  arguments it checks the committed exports under
  `tests/fixtures/functional-gate/`. After an intentional exporter change, run
  `swift build --package-path app/RefabArtist`, then
  `python3 scripts/functional_gate.py --generate`, and commit the regenerated
  exports.
- If you change Python under `tools/` or `scripts/`, also run
  `python3 -m pytest`.

## Ground rules

- **Spec before code.** Work on a construction mode starts from its spec in
  `docs/specs/<mode>.md`; the implementation follows the spec.
- **Clean-room boundary.** Never copy, decompile or disassemble other
  software, its UI resources, help text or output files; only use third-party
  code under a compatible licence and list it in `THIRD_PARTY_NOTICES.md`.
  Other software's app bundles, binaries, interface files, icons and help
  documents never enter the repository. An opt-in pre-commit hook checks
  staged files for them:
  `git config core.hooksPath .githooks` (see `docs/contributing-hooks.md`).
- **Fixtures need provenance.** Every committed model or generated output used
  as test evidence needs a documented source, recorded in
  `tests/fixtures/MANIFEST.md`.
- **Third-party material.** Anything not written for this project is listed,
  with its licence, in `THIRD_PARTY_NOTICES.md`.

## Pull requests

- Branch per change: `feat/<name>`, `fix/<name>`, `docs/<name>`,
  `chore/<name>`. Never push directly to `main`.
- One feature per pull request; do not bundle unrelated cleanup.
- Open the pull request as a draft on first push.
- On your first pull request, sign the contributor agreement by posting a
  comment, as described below.

## License and contributor agreement

Refab Artist is distributed under the GNU General Public License, version 3 (see
[LICENSE](LICENSE)). Copyright in the project is held by Pete Katz.

By submitting a contribution (a pull request, patch, fixture, document, or any
other material) you agree that:

1. you wrote it, or otherwise have the right to submit it under these terms;
2. you license it to the project under GPL-3.0; and
3. you additionally grant Pete Katz a perpetual, worldwide, non-exclusive,
   royalty-free licence to use, reproduce, modify, sublicense, and distribute
   your contribution under any licence, including proprietary and commercial
   licences, as part of Refab Artist or works derived from it.

You keep your copyright; this is a licence grant, not an assignment. It keeps
Refab Artist free under the GPL while leaving the maintainer able to offer it under
other terms later.

You sign this agreement once, on your first pull request. A bot comments on
the pull request and asks you to sign; reply with a comment that says exactly:

```text
I have read the licence and contributor agreement in CONTRIBUTING.md and I agree to its terms.
```

The bot records your signature, and the pull request cannot be merged until
it has. Your later pull requests pass without asking again. If the check
does not update after you sign, comment `recheck`.

Keep dependencies GPL-compatible or permissively licensed. Do not copy,
decompile or disassemble other software, its UI resources, help text or output
files. Implement behavior from documented requirements
(`docs/specs/`) and understanding, and preserve attribution for compatible
upstream work in `THIRD_PARTY_NOTICES.md`.
