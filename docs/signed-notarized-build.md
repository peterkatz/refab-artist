# Signed And Notarized Build Instructions

This runbook documents the macOS Developer ID path for a public Refab Artist
binary. It does not replace the release checklist; use it as the P6.7 packaging
detail after the release gates are satisfied.

## Prerequisites

- Apple Developer Program membership with a Developer ID Application
  certificate.
- Xcode command line tools installed.
- `xcrun notarytool` available.
- A notarytool keychain profile stored locally, never in git.
- A clean release worktree.

Store credentials once on the release machine:

```sh
xcrun notarytool store-credentials refabartist-notary \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD"
```

`$APP_SPECIFIC_PASSWORD` is an Apple app-specific password. Do not commit it,
paste it into docs, or keep it in shell history.

## Unsigned Smoke Build

`tools/package_app.sh` builds the Swift package in release configuration and
assembles `build/Refab Artist.app`: the executable, the resource bundle, the
licence texts, the app icon and `Info.plist`. It signs the result ad hoc, so
it runs on the machine that built it and nowhere else:

```sh
tools/package_app.sh
open "build/Refab Artist.app"
```

Do not ship that artifact as a public release. Note that the script replaces
`build/Refab Artist.app`; quit a copy of the app that is running from there
first, or set `REFAB_OUTPUT_DIR` to write the app to another directory.

The app must not carry anything that identifies the build machine, so the
script:

- builds in `/tmp/refab-artist-build`, outside the checkout (set
  `REFAB_SCRATCH_PATH` for another directory whose path names nobody).
  SwiftPM compiles the absolute path of its build directory into the
  executable, so a build inside a home directory would put the user name and
  the checkout path into the app;
- strips the debug map from the packaged executable (`strip -S`), which
  otherwise lists every object file and source directory by absolute path;
- ends with `tools/check_app_paths.sh`, which fails if any file in the app
  still contains a path in the users folder, the checkout path or the login
  name.

## Release Bundle

The release bundle is the same app, signed with the Developer ID identity
below. `package_app.sh` takes the version from `REFAB_VERSION` (default
`0.1.0`) and the build number from `REFAB_BUILD` (default `1`):

```sh
REFAB_VERSION=0.1.0 REFAB_BUILD=1 tools/package_app.sh
```

Before release, verify in `build/Refab Artist.app/Contents/Info.plist`:

- `CFBundleIdentifier` is stable (`com.refabartist.app`; the first-launch
  settings carry-over writes to that domain, so do not change it).
- `CFBundleShortVersionString` matches the release version.
- `CFBundleVersion` is incremented for every binary built from the same
  version.
- `LSMinimumSystemVersion` matches the supported macOS floor.

Smoke-test before signing:

```sh
open "build/Refab Artist.app"
```

Import a fixture and export at least one vector format and one mesh format.

## Sign

Set the signing identity:

```sh
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
export APP_DIR="$(pwd)/build/Refab Artist.app"
```

Sign nested code explicitly if future bundles/frameworks add executable code.
For the current app, sign the executable, then the app bundle. `--force`
replaces the ad hoc signature `package_app.sh` left on it:

```sh
ENTITLEMENTS="$(pwd)/app/RefabArtist/Packaging/RefabArtist.entitlements"

codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$DEVELOPER_ID_APPLICATION" \
  "$APP_DIR/Contents/MacOS/RefabArtist"

codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$DEVELOPER_ID_APPLICATION" \
  "$APP_DIR"
```

Verify:

```sh
codesign --verify --deep --strict --verbose=4 "$APP_DIR"
codesign --display --verbose=4 "$APP_DIR"
```

Use `--deep` for verification. Do not rely on `codesign --deep --sign` as a
substitute for explicitly signing nested executable code.

Check the signed app once more for paths and names of the build machine:

```sh
tools/check_app_paths.sh "$APP_DIR"
```

### The 3Dconnexion SpaceMouse driver (decided: keep SpaceMouse support)

With a 3Dconnexion SpaceMouse attached, the app loads the vendor's client
framework from `/Library/Frameworks/3DconnexionClient.framework` at run time
(`SpaceMouseController.swift`). The hardened runtime (`--options runtime`)
enables library validation, which refuses a library that is neither Apple's
nor signed by the app's own team. In a notarized build the load would fail
and SpaceMouse support would stop, without an error message: the app skips
the device when the load fails.

If SpaceMouse support is to work in the public binary, sign with the
`com.apple.security.cs.disable-library-validation` entitlement. It needs no
provisioning profile:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
```

That file is `app/RefabArtist/Packaging/RefabArtist.entitlements`, and the
`codesign` commands above pass it. Test each signed build with a real
SpaceMouse attached.

## Notarize And Staple

Submit a zip that preserves the app bundle:

```sh
ZIP_PATH="$(pwd)/build/RefabArtist.zip"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile refabartist-notary \
  --wait
```

Staple the accepted ticket to the app:

```sh
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
```

Gatekeeper assessment:

```sh
spctl --assess --type execute --verbose=4 "$APP_DIR"
```

For direct `.zip` distribution, zip the stapled app after the staple step:

```sh
STAPLED_ZIP="$(pwd)/build/RefabArtist-notarized.zip"
ditto -c -k --keepParent "$APP_DIR" "$STAPLED_ZIP"
```

For `.dmg` distribution, create and sign the disk image, submit the `.dmg` to
notarytool, then staple the `.dmg`:

```sh
DMG_PATH="$(pwd)/build/RefabArtist.dmg"
hdiutil create -volname "Refab Artist" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH"
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile refabartist-notary --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
```

## Failure Triage

If notarization fails:

```sh
xcrun notarytool history --keychain-profile refabartist-notary
xcrun notarytool log <submission-id> --keychain-profile refabartist-notary
```

Common failures:

- Unsigned nested executable code.
- Missing hardened runtime (`--options runtime`).
- Invalid or expired Developer ID certificate.
- Bundle version mismatch between release notes and `Info.plist`.
- Accidentally submitting an older `build/Refab Artist.app` instead of one
  freshly made by `tools/package_app.sh`.

After every fix, rebuild or reassemble the bundle, sign again, verify again,
and submit a fresh archive.

## Release Record

Attach these facts to the release record or Linear status update:

- git commit SHA
- `CFBundleShortVersionString` and `CFBundleVersion`
- Developer ID Team ID
- notarization submission ID
- output artifact SHA-256
- `codesign --verify` result
- `tools/check_app_paths.sh` result
- `spctl --assess` result
