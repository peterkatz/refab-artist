# Contributing and licence

Refab Artist is free and open source. The code and the guide live in the [GitHub repository](https://github.com/peterkatz/refab-artist). Contributions are welcome: bug reports, test models, fixes, new ideas.

## Reporting problems and sharing models

Open an issue on the repository. Say which mode you were using, what you expected, and what happened. If you can share the model, attach it; failures on real models are the most useful thing you can report.

## Contributing code and documents

[CONTRIBUTING.md](https://github.com/peterkatz/refab-artist/blob/main/CONTRIBUTING.md) explains how to build and check a change. In short:

- Work on a branch (`feat/<name>`, `fix/<name>`, `docs/<name>` or `chore/<name>`), open a draft pull request on your first push, and keep to one feature per pull request.
- Start a construction mode from its spec in `docs/specs/`, and run the checks on your own machine; there is no cloud CI beyond the check that records your signature on the contributor agreement.
- A mode is done when it passes the functional gate, which checks that the parts it exports can be cut.
- Keep the project clean-room: never copy other software, its resources, help text or output files. Test models need a recorded source.

### Contributor agreement

You sign the contributor agreement once, on your first pull request, by replying to the bot's comment. You keep your copyright. The agreement licenses your contribution to the project under GPL-3.0 and additionally grants the maintainer a licence to use it under other terms. Read the full text in [CONTRIBUTING.md](https://github.com/peterkatz/refab-artist/blob/main/CONTRIBUTING.md#license-and-contributor-agreement) before you contribute.

## Licence

Copyright (C) 2026 Pete Katz. Refab Artist is released under the **GNU General Public License, version 3**; see [LICENSE](https://github.com/peterkatz/refab-artist/blob/main/LICENSE). You may use, study, share and change it under those terms.

## Third-party components

Refab Artist links two components it did not write, and each keeps its own licence, both compatible with GPL-3.0:

- [Manifold](https://github.com/elalish/manifold) for 3D mesh operations (Apache-2.0).
- [Clipper2](https://github.com/AngusJohnson/Clipper2) for 2D polygon operations (Boost Software License 1.0).

The full list is in [THIRD_PARTY_NOTICES.md](https://github.com/peterkatz/refab-artist/blob/main/THIRD_PARTY_NOTICES.md).

## How it is built

The Mac app is written in SwiftUI, with RealityKit for the 3D view. The cut-sheet modes and 3D Slices are specified in `docs/specs/` in the repository, one file per mode.
