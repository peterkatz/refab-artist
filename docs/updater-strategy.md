# Updater Strategy

Refab Artist should not add Sparkle or another built-in updater before the first
public release. The current distribution decision in `docs/PRD.md` is GitHub
Releases only, and the app still needs signed/notarized release packaging,
compatibility reporting, and physical validation before a public binary is a
normal user-facing artifact.

## Decision

For the v0.x line:

- No built-in updater.
- No Sparkle dependency.
- No automatic background update checks.
- Users discover updates through GitHub Releases and project release notes.

This keeps early distribution simple and avoids adding a network/update trust
surface before the release pipeline is proven.

## Why Not Sparkle Yet

Sparkle is a good fit for mature direct-download Mac apps, but adding it now
would require decisions and infrastructure Refab Artist has not made yet:

- stable update channel policy
- appcast hosting location
- signing/notarization pipeline for every release artifact
- rollback policy
- minimum supported macOS policy
- privacy copy for update checks
- UI affordance for update status/errors

Those are release-product decisions, not implementation prerequisites for the
current trust-building phase.

## Revisit Criteria

Reconsider Sparkle when all of these are true:

- P6.4 physical calibration has at least one recorded real-material pass.
- P6.5 compatibility report exists for the release line.
- P6.7 signed/notarized build instructions have been executed successfully for
  a real release candidate.
- P7.8 has produced at least one tagged release artifact.
- Direct-download GitHub Releases remain the distribution channel after real
  users have installed a release.

## Future Implementation Checklist

If Sparkle is later approved:

- Add Sparkle through Swift Package Manager or another reviewable dependency
  path.
- Record Sparkle's license in `NOTICE` if required by the chosen integration.
- Add appcast generation and signing to release packaging docs.
- Add update-check UI that is explicit and non-disruptive.
- Add a privacy note explaining update checks.
- Test update from release N to release N+1 on a clean user account.
- Keep a manual download path for users who disable update checks.

Until then, update instructions belong in the GitHub release notes.
