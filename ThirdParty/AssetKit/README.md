# AssetKit (vendored)

A copy of [xtool-org/AssetKit](https://github.com/xtool-org/AssetKit), the `Assets.car` writer that xless's
`assets` stage uses. xless depends on it as a local SwiftPM package (`.package(path: "ThirdParty/AssetKit")`).

- Upstream revision: `e763558b55fcbb5a443b1d7b2c6f0972d8bd14f7` (also `ASSETKIT_REVISION` in `versions.env`).
- Copied: `Sources/`, `Tests/`, `Package.swift`, `LICENSE` (MIT, unchanged). Not copied: `.github/`, `docs/`,
  `Dockerfile`, `.gitignore` and the upstream `README.md`.
- Run its own tests with `swift test --package-path ThirdParty/AssetKit`.

## Patches on top of upstream

1. **BOM free list** (`Sources/AssetKit/BOM/BOMWriter.swift`). The block index now ends with libBOM's free list
   (count 0 and two zeroed pairs) inside `indexLength`, as libBOM writes it. Upstream ended the index right after
   the block table, so libBOM read the vars table count as the free-list count. `assetutil --info` still read the
   car, but CoreUI could not open it for writing: `assetutil` thinning failed with "is not a valid AssetCatalog",
   the same words as the ITMS-90562 rejection App Store processing gave the xless HelloShip build.
2. **BITMAPKEYS descriptors** (`Sources/AssetKit/CAR/BitmapKeys.swift`, `CARWriter.swift`, `RenditionKey.swift`).
   Each descriptor is now computed from the asset's rendition keys: `[1, 0, 4 + 4n, n]` and then, for each of the
   n KEYFORMAT attributes, a bitmask of the values in use. Appearance, identifier, element and part are always
   -1. Every asset gets an entry, colors included. Upstream wrote fixed templates (for example scale 1x/2x/3x and
   phone only for every app icon) and skipped colors, so `assetutil --validate-file` reported "invalid
   bitmapindex". The rule comes from actool 27.0 output and from `assetutil --update-bitmap`.

3. **Bitmap opacity** (`Sources/AssetKit/CAR/MLECBody.swift`, `Rendition/PNGSource.swift`, `Rendition.swift`). The
   first word after `MLEC` is a flags word, not a compression type: bit 1 (0x2) says every pixel is opaque, and CoreUI
   then draws the rendition without its alpha. Upstream wrote 3 for every bitmap, so a transparent PNG drew on a black
   square (`assetutil --info`: `Opaque: True`). The flags are now 3 when every alpha is 255 and 1 otherwise, the next
   word (upstream's "bytes per pixel") is the compression, 4 (LZFSE). Measured with actool 27.0 on neutral PNGs:
   opacity is decided from the pixels, not the PNG colour type (an RGBA PNG whose alpha is all 255 is opaque, one alpha
   of 254 is not; RGB, gray and palette PNGs are opaque).
4. **Named colors** (`CSIWriter.color`, `RenditionKey`, `FacetKeys`, `ColorRenderer`, `Schema/Contents.swift`). Written
   as actool 27.0 writes them: key and facet element 85, part 217, scale 1; CSI header scale and colour space 0, TVL
   `1004 = (0, 0)` and `1006 = 1`, bitmap count 1; body tag `COLR` as an LE constant (file bytes `RLOC`), version 1,
   the colour space ID (srgb 1, display-p3 3, extended-srgb 4, extended-linear-srgb 5), then the components. A
   component without a decimal point is an 8-bit value ("1" is 1/255), one with a decimal point goes through Float.
   Upstream's colors read in `assetutil` as one component (2e-323) in a "generic" space, and `UIColor(named:)` found
   none.

5. **Tool version fields passed in** (`Sources/AssetKit/CAR/CARHeader.swift`, `CARWriter.swift`, `XCAssetCompiler.swift`).
   A public `CARHeaderValues` (CoreUI version, storage version, main version string, version string, authoring tool)
   is an `XCAssetCompiler` parameter; the CARHEADER and EXTENDED_METADATA blocks are written from it. `assetutil --info`
   reports them as `CoreUIVersion`, `StorageVersion`, `MainVersion`, `AssetStorageVersion` and `Authoring Tool`. The
   default, `CARHeaderValues.default`, is upstream's values, so AssetKit's own callers are unchanged; xless passes the
   values of the image's Xcode's actool (`XcodeToolsProfile`). AssetKit stays free of xless code.

Tests: `BOMWriterTests` (free list), `BitmapKeysTests` (descriptors), `AssetutilParseTests` "assetutil validates and
thins the compiled Assets.car" (macOS: `assetutil --validate-file` and thinning), and `ActoolParityTests` (opacity
and colors against `Fixtures/Parity.expected.<build>.json`, once per recorded Xcode build (27A266a, 27A9275, 27B52, 17C52, 17A400, 17B55): what
`assetutil --info` reports for that actool's car of the neutral `Fixtures/Parity.xcassets`, recorded by
`scripts/assetkit-golden.sh`; macOS also compares AssetKit's car field by field; the header test checks patch 5, with
`assetutil` on macOS). Known gaps against actool: no MultiSized Image rendition for app icons, grayscale PNGs stored as
ARGB in sRGB (actool: 8-bit gray in "gray gamma 22"; same pixels), images stored LZFSE instead of deepmap2, no
display-gamut key attribute for colors (docs/research/parity-known-gaps.md).
