# Contributing — Local Git Hooks

Refab Artist ships an opt-in pre-commit hook that blocks other software's files
(app bundles, binaries, interface files, icons, installers, help documents)
from being committed. There is no CI that runs this check. The hook gives you
fast local feedback, and the maintainer runs
`scripts/check-no-foreign-assets.sh --all` before merging outside
contributions.

## One-time setup

In a fresh clone:

```
git config core.hooksPath .githooks
```

That points git at the in-repo `.githooks/` directory. From then on, every
`git commit` in this clone first runs `scripts/check-no-foreign-assets.sh
--staged` against the staged changes and aborts the commit if any blocked
file shows up.

The setting is per-clone (it writes to `.git/config`) and not committed,
which is why it's opt-in. You only need to run it once per clone.

## What the hook checks

The check works by file type and path, and lives in
`scripts/check-no-foreign-assets.sh`. At time of writing it blocks:

- Anything inside an application, framework, plug-in or help bundle
  (`*.app/`, `*.framework/`, `*.bundle/`, `*.plugin/`, `*.help/`, …), or laid
  out like one (`Contents/MacOS/`, `Contents/Resources/`, …)
- Interface files: `*.nib`, `*.xib`, `*.storyboard`
- Icons and compiled asset catalogs: `*.icns`, `*.car`
- Dynamic libraries: `*.dylib`, `*.so`
- Installers, disk images and executables: `*.dmg`, `*.pkg`, `*.mpkg`,
  `*.xip`, `*.msi`, `*.exe`
- Help files: `*.chm`, `*.hlp`, and PDFs named like help documents
  (`*help*.pdf`, `*manual*.pdf`, `*userguide*.pdf`, `*user-guide*.pdf`,
  `*user_guide*.pdf`)
- Mach-O executables, libraries and object files (thin or universal) and ELF
  binaries, recognised by their leading bytes whatever the file is called

Static libraries (`*.a`) are not blocked: the vendored Manifold archives are
listed in `THIRD_PARTY_NOTICES.md`. A project-owned file that matches a
blocked type goes in the script's `ALLOWED_PATHS` list, which holds one
entry: the app's own icon, `app/RefabArtist/Packaging/AppIcon.icns`, drawn by
`tools/icon/make_app_icon.py`.

Add new checks by editing the script; the change is picked up automatically
on the next commit. `tests/gates/test_foreign_asset_guard.py` covers each
check.

## Running the check manually

You can run the check at any time without committing:

```
bash scripts/check-no-foreign-assets.sh --all      # every tracked file
bash scripts/check-no-foreign-assets.sh --staged   # only staged changes
```

Exit 0 means clean. Non-zero prints the offending paths and the reason
each one tripped the check.

## Why opt-in

Git hooks are deliberately not committed to a repository — they live in
`.git/hooks/` per clone. Pointing `core.hooksPath` at an in-repo directory
is the standard workaround, but it still requires the contributor to
flip the switch. The non-opt-in layer is the maintainer's review: before
merging an outside contribution, the maintainer runs the check with `--all`
on the merged result, and a change that fails it is not merged.
