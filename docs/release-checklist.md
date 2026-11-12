# Release Checklist

This checklist is the gate for a tagged Refab Artist release. It is intentionally
stricter than "the app builds": a release must be clean-room safe, testable,
packaged, and honest about what each construction mode can and cannot do.

Use a fresh clone or clean worktree for release preparation. Do not cut a
release from a dirty development checkout.

## Release Identity

- [ ] Pick the release version, for example `0.1.0`.
- [ ] Create or update release notes with the supported modes, known gaps,
  gate results and physical validation status.
- [ ] Confirm the public launch trigger (`docs/PRD.md`, decision D3).
- [ ] Confirm the distribution channel (`docs/PRD.md`, decision D4: GitHub
  releases).

## Source Tree Gate

- [ ] Confirm the release branch is clean:

```sh
git status --short
```

- [ ] Confirm all intended PRs are merged and no release-critical work is still
  draft-only.
- [ ] Confirm the release scope in `docs/PRD.md` is current.
- [ ] Confirm `README.md` does not describe stale architecture or unsupported
  modes.
- [ ] Confirm `LICENSE`, `THIRD_PARTY_NOTICES.md` and `CONTRIBUTING.md` are
  present and current.

## Clean-Room Gate

- [ ] Run the asset boundary scan:

```sh
bash scripts/check-no-foreign-assets.sh --all
```

- [ ] Confirm no other application's files or resources, installer
  artifacts, output files produced by other software, or local archive paths
  are tracked.
- [ ] Confirm the release notes describe Refab Artist on its own terms: what it
  does and who it is for, with no origin story and no other company or
  product named as its source.

## Public History Gate

The development repository's history holds work-in-progress files that are
not part of any release. Deleting a file at HEAD does not remove it from
history, so the public repository must not share that history.

The maintainer runs this gate in the development repository. Its release
tooling, `scripts/release/`, stays there and is not part of the public
repository, so a public clone does not have the script named below.

- [ ] Make the public snapshot from the release commit, in the development
  repository:

```sh
scripts/release/make-public-snapshot.sh ../refab-artist-public "Refab Artist <version>"
```

  The script refuses to run with uncommitted changes to tracked files. It
  exports HEAD without the paths in `scripts/release/public-exclude.txt`
  (internal tracking and history docs, the release tooling itself, private
  archive paths) and creates a new repository with one root commit. That
  commit is authored and committed by the project owner, whatever git
  identity the development repository uses: the script sets the owner's
  identity itself (`REFAB_SNAPSHOT_AUTHOR_NAME` and
  `REFAB_SNAPSHOT_AUTHOR_EMAIL` override it) and fails if the commit names
  anyone else, or if its dates are not recorded in UTC. It then searches every file and path for the patterns in
  `scripts/release/banned-terms.txt` and runs
  `scripts/check-no-foreign-assets.sh --all` on the snapshot. It never adds a
  remote and never pushes.

- [ ] The script ends with `make-public-snapshot: OK`. On `FAIL` it lists
  every banned-term hit and guard failure; fix them in the development
  repository, commit, and make a new snapshot. Never silence a hit by adding
  a real file to the exclude list; make the pattern more exact instead.
- [ ] Review the `note:` lines: public files that mention a path the
  snapshot leaves out.
- [ ] Confirm the public repository has exactly one commit and no other
  refs (the script also checks the commit count and that there is no
  remote):

```sh
git rev-list --all --count   # 1
git for-each-ref             # only refs/heads/main
```

- [ ] Never push the development repository, or any of its branches or
  tags, to a public remote. Later public releases are new commits on the
  public repository, made from the next release tree the same way.

## Test Gate

There is no cloud CI; run every gate locally on the release commit.

```sh
python3 -m pytest -q
swift test --package-path app/RefabArtist
```

- [ ] Record the Python result count.
- [ ] Record the Swift result count, and compare failures against the
  previous release's baseline: a release must not add failures.

## Functional And Assembly Gate

The functional gate is the definition of done for every construction mode
(`docs/functional-gate.md`).

```sh
swift build --package-path app/RefabArtist
python3 scripts/functional_gate.py --generate
python3 scripts/assembly_gate.py
```

- [ ] The functional gate passes (only cases on its known-defect list may
  fail, and each is named in the release notes).
- [ ] The assembly gate passes on the same terms.
- [ ] List each mode as one of:
  - supported (passes both gates)
  - experimental
  - intentionally unavailable

## Physical Calibration Gate

Physical calibration is owner-run. A release that claims cut-fit confidence
needs at least one real material validation pass (`docs/physical-calibration.md`).

- [ ] Export the selected calibration fixture and record mode, material
  thickness, kerf/slot settings, and format.
- [ ] Laser-cut or CNC-cut the fixture in the target material.
- [ ] Record slot fit, assembly fit, scale accuracy, and any manual cleanup
  needed.
- [ ] Save photos and notes outside git if they include third-party/user
  project material; summarize the results in the release notes.

## Performance Gate

- [ ] Run the benchmark harness after a release build:

```sh
python3 tools/benchmark_exports.py \
  --iterations 5 \
  --warmups 1 \
  --json /tmp/refabartist-release-benchmark/benchmark.json \
  --markdown /tmp/refabartist-release-benchmark/benchmark.md \
  --output-dir /tmp/refabartist-release-benchmark/runs
```

- [ ] Compare median timings against the previous release or baseline run.
- [ ] Investigate regressions above 20 percent on dense or feature-rich cases.
- [ ] Paste the Markdown table into the release record.

## Packaging Gate

Unsigned local app smoke:

```sh
tools/package_app.sh
open "build/Refab Artist.app"
```

- [ ] Import a cube fixture.
- [ ] Switch through all construction modes.
- [ ] Export at least one vector format and one mesh format.
- [ ] Open the exported files with a parser or viewer.
- [ ] The Finder and the Dock show the Refab Artist icon at 128 px and
      larger with no gray backdrop behind it (macOS 26 adds one to icons it
      does not accept as full-size rounded squares). At 32 px and smaller, as
      in Finder's list view, macOS 26 draws its light-grey backdrop behind
      every legacy `.icns` icon, other apps' included; that is expected until
      the app has an asset-catalog or Icon Composer icon.

Before a public binary (`docs/signed-notarized-build.md`):

- [ ] Build a release-configuration `.app`, not a debug-only package.
- [ ] `tools/check_app_paths.sh "build/Refab Artist.app"` passes on the app
      that will be published (`tools/package_app.sh` runs it too): no file in
      it names a home directory, the checkout path or the build machine's
      login name.
- [ ] Sign the app with the intended Developer ID identity.
- [ ] Notarize and staple the app.
- [ ] Verify Gatekeeper on a separate machine or clean user account.
- [ ] Package the notarized app as the chosen distribution artifact.

## Final Release Gate

- [ ] Tag the exact commit in the public repository (Public History Gate):

```sh
git tag -a v0.1.0 -m "Refab Artist 0.1.0"
git push origin v0.1.0
```

- [ ] Create the GitHub release with:
  - release notes
  - supported/experimental mode table
  - functional, assembly and physical validation summary
  - known limitations
  - notarized app artifact if available
- [ ] Update the project tracker.
- [ ] Archive the release benchmark, gate and physical-calibration summaries
  in the project record.

## Do Not Release If

- [ ] Any other software's asset, or anything derived from other software's
  binaries or resources, is in git.
- [ ] `scripts/release/make-public-snapshot.sh` reports `FAIL` for the
  release commit.
- [ ] The public repository's history contains any commit of the
  development repository.
- [ ] The README or release notes claim more than the gates and physical
  validation show.
- [ ] Physical calibration is missing but the release claims real-material
  fit confidence.
- [ ] The functional or assembly gate fails outside its known-defect list.
- [ ] The binary is unsigned/not notarized but the release is presented as a
  polished public macOS download.
