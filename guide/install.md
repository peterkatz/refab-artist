# Install

## What you need

- A Mac with Apple silicon (M1 or later). Intel Macs are not supported.
- macOS 15 (Sequoia) or newer. Version 0.1.0 was built and checked on macOS 26 only; it has not been run on macOS 15 or 14, so tell us if you hit trouble there.

Refab Artist needs no account and no internet connection once it is installed.

## Download the app

1. Go to the [Releases page](https://github.com/peterkatz/refab-artist/releases) and download `Refab-Artist-0.1.0.zip`.
2. Double-click the zip. **Refab Artist** appears next to it.
3. Drag **Refab Artist** into your Applications folder.
4. Open it.

The app is signed with a Developer ID and notarized by Apple, with the ticket stapled, so macOS opens it like any other app without warnings or extra steps.

The app does not update itself. To update, download the new version from the Releases page and drag it over the old one. Your saved projects stay where you saved them.

## Build from source

You need a Mac with Apple silicon, macOS 15 or newer, and Xcode (or its command line tools) with Swift 6. Manifold and Clipper2 are vendored as prebuilt static libraries, so nothing else needs installing.

```sh
git clone https://github.com/peterkatz/refab-artist.git
cd refab-artist

# Build an app you can double-click (a release build; the first one takes a few minutes):
tools/package_app.sh
open "build/Refab Artist.app"
```

`tools/package_app.sh` builds in release configuration and writes `build/Refab Artist.app`, signed ad hoc so it runs on your Mac. To build or run without packaging:

```sh
swift build --package-path app/RefabArtist -c release
swift run --package-path app/RefabArtist RefabArtist
```

## Optional: a 3Dconnexion SpaceMouse

If you have a 3Dconnexion SpaceMouse and 3Dconnexion's driver is installed, Refab Artist can use it to move around the 3D view. The app loads the driver library at run time, and the download is signed in a way that allows that. Nothing needs setting up in Refab Artist; if the driver is not installed, the app works as normal with the mouse and trackpad.

## What is in the window

The window is organised around one flow, left to right:

- **Left rail:** the whole build, top to bottom: your model, the construction technique, manufacturing settings, technique settings, slice direction, and the **Slice** button, followed by Assembly and Export once there are parts.
- **Centre:** the 3D view, and the cut-sheet preview once you have sliced.
- **Right inspector:** tabs for **Object** (size and Modify Form), **Viewport** (how the model looks), **Issues** and **Stats**.

[Getting started](getting-started.md) walks through it with a model.

!!! tip "Try it without a model"
    **File > Load Sample Model** opens a built-in sample cube so you can look around before you bring your own.
