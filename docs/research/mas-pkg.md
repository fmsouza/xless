# Mac App Store `.pkg` from Linux

Status: implemented by the macOS App-Store lane ([signing-and-testflight.md](../signing-and-testflight.md#macos-app-store-lane-testflight), for Tauri and cargo overlays), and **not yet confirmed by a real App Store Connect upload**: the package is checked against Apple's own tools (`pkgutil --expand`, `xar`, `cpio`) and its parts against productbuild's output, not against App Store Connect. A macOS app is otherwise shipped as a Developer ID signed, notarized and stapled DMG.

## What blocked it, and what the lane does

1. rcodesign cannot write `.pkg` payloads, but it signs a finished flat package. xless writes the payload (odc cpio, gzip), the Bom, the `PackageInfo` and `Distribution` files and the XAR container itself (`Xar`, no `xar` tool: Ubuntu does not package one), then runs `rcodesign sign` on the result.
2. There is no `productbuild` (or `pkgbuild`) on Linux; the package's shape is the one productbuild writes (verified on a Mac).
3. The package must be signed with a **Mac Installer Distribution** certificate ("3rd Party Mac Developer Installer", `XLESS_INSTALLER_KEY`); a package signed with the Apple Distribution certificate is refused (ITMS-90237). The app inside is signed with Apple Distribution under a `MAC_APP_STORE` profile.
4. Not yet proven by an upload: `com.apple.pkg` is an accepted UTI for build upload files ([asc-build-uploads.md](asc-build-uploads.md)), and the lane uploads through that API.
5. A Mac App Store build also needs a macOS `Assets.car` for an asset-catalog icon. AssetKit writes the CAR platform as `ios` (`ExtendedMetadata.defaultPlatform`) and its compiler offers no way to choose another, so xless uses an `.icns` icon on macOS.

## Still open

- Add a macOS-capable asset catalog writer (patch AssetKit or use a fork).
- Confirm the whole lane with a real App Store Connect upload.
