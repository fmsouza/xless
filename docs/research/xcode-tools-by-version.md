# Asset and storyboard tools by Xcode version (27A266a, 27A9275 and 17C52)

Measured black-box on the Mac, 2026-10-17: the tools were run and their outputs read (`--version`, `assetutil --info`,
`plutil`, `nib dump` of xless's own reader, exit codes and messages). Nothing was disassembled. The three Xcodes (27A9275 was measured on 2026-11-12, the same way, from `Xcode_27.1.xip`):

| | 27A266a | 27A9275 | 17C52 |
|---|---|---|---|---|
| `xcodebuild -version` | Xcode 27.0, Build version 27A266a | Xcode 27.1, Build version 27A9275 | Xcode 26.2, Build version 17C52 |
| location used | `~/.cache/xless/Xcode.app` | `~/.cache/xless/xcode-27.1/Xcode.app` | `~/.cache/xless/xcode-26.2/Xcode.app` |

Every command below ran as `DEVELOPER_DIR=<Xcode>/Contents/Developer xcrun <tool> ...`. `<P>` is
`ThirdParty/AssetKit/Tests/AssetKitTests/Fixtures/Parity.xcassets`; the goldens come from `scripts/assetkit-golden.sh`,
`scripts/ib-golden.sh` and `scripts/copypng-golden.sh` (outputs: `Parity.expected.<build>.json`,
`Tests/IBCorpus/golden/<build>/`, `Tests/XlessAssetsTests/Fixtures/copypng/<build>.json`).

Setup note: Xcode 26.2's actool and ibtool refuse to run without an iOS simulator runtime
(`error: iOS 26.2 Platform Not Installed.`). `xcodebuild -downloadPlatform iOS -buildVersion 26.2` answered
`iOS 26.2 is not available for download.`; the same command without `-buildVersion`, under 26.2's `DEVELOPER_DIR`, installed
iOS 26.3.1 (23D8133), and actool and ibtool 26.2 accept it. Xcode 27.1 (27A9275) needed no download: the installed iOS 27.0 runtime was enough.
The 17C52 column's CoreUI-973.1 and CoreThemeDefinition-653.3 rows were measured with the iOS 26.3.1 runtime (23D8133): the car header says "via AssetCatalogSimulatorAgent", so those strings likely come from the installed runtime, not from Xcode 26.2 itself. 27A266a needs only its own iOS 27.0 runtime.

## Summary for the tools profile

Same in all three builds (27A9275 differs from 27A266a only in its version strings, listed below): every `assetutil --info` rendition field of the Parity catalog and of a single-size AppIcon catalog,
the app-icon partial Info.plist, the app-icon PNG bytes, copypng's behaviour on all 40 case/option combinations,
the `Info.plist` and `UIViewController-*.nib` of every storyboard in the corpus, and the `actool`/`ibtool`
log output (empty bar the result paths).

Different (one row per profile field below): the version numbers, the CAR header strings and CoreUI version, three nib
encodings (a key, a default colour, a double precision), font-dictionary uniquing in two cases, and the highest
document capability ibtool accepts.

## actool

| Field | 27A266a | 27A9275 | 17C52 | Observed with |
|---|---|---|---|---|
| `--version` `short-bundle-version` | `27.0` | `27.1` | `26.2` | `xcrun actool --version --output-format xml1` |
| `--version` `bundle-version` | `25098` | same as 27A266a | `24506` | same |
| CAR header `CoreUIVersion` | `1010` | same as 27A266a | `973` | `xcrun assetutil --info <out>/Assets.car` (first array entry) after `xcrun actool --output-format human-readable-text --errors --platform iphoneos --minimum-deployment-target 16.0 --target-device iphone --target-device ipad --compile <out> --output-partial-info-plist <out>/partial.plist <P>` |
| CAR header `StorageVersion` | `17` | same as 27A266a | `17` | same |
| CAR header `SchemaVersion` | `2` | same as 27A266a | `2` | same |
| CAR header `DumpToolVersion` | `1010` | `1011.4` (`xcrun assetutil --version` prints `version: 1011.40`; assetutil's own version, not stored in the car, so not a profile field) | `1010` | same (assetutil's own version; `xcrun assetutil --version` prints `version: 1010.00` under both) |
| CAR header `AssetStorageVersion` | `Xcode 27.0 (27A266a) via AssetCatalogAgent-AssetRuntime` | `Xcode 27.1 (27A9275) via AssetCatalogAgent-AssetRuntime` | `Xcode 26.2 (17C52) via AssetCatalogSimulatorAgent` | same |
| CAR header `Authoring Tool` | `@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-664 [LAR] [IIO-2851][LAR] AppleJPEG[1][32]  CMPhoto[1][219]] [IR-120(hw)]` | same as 27A266a | `@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-653.3  [IIO-2784.3.4]` | same |
| CAR header `MainVersion` | `@(#)PROGRAM:CoreUI  PROJECT:CoreUI-1010 [LAR]` | same as 27A266a | `@(#)PROGRAM:CoreUI  PROJECT:CoreUI-973.1` | same |
| CAR header `Platform`, `PlatformVersion`, `Appearances`, `Key Format` | `ios`, `16.0`, any 0 / dark 1, the nine `kCRTheme*` keys | same as 27A266a | identical | same |
| `Timestamp` | the compile time | same as 27A266a | the compile time | same (varies per run; not a profile field) |
| Rendition fields (Parity catalog, 15 renditions, minus `SHA1Digest`, `SizeOnDisk`, `NameIdentifier`) | `Parity.expected.27A266a.json` | `Parity.expected.27A9275.json`; `diff` against 27A266a shows only the `actool` and `xcodeBuild` lines | `Parity.expected.17C52.json`; `diff` of the two files shows only the `actool` and `xcodeBuild` lines | `scripts/assetkit-golden.sh` |
| App icon, one 1024x1024 universal image, `--app-icon AppIcon` | phone and pad `Icon Image` plus two `MultiSized Image` entries (see the next rows) | same as 27A266a | identical entries | `xcrun actool ... --app-icon AppIcon --compile <out> --output-partial-info-plist <out>/partial.plist c.xcassets`, then `xcrun assetutil --info` |
| App icon, loose files written | `AppIcon60x60@2x.png`, `AppIcon76x76@2x~ipad.png` (byte-identical between the two builds, checked with `cmp`) | same as 27A266a | same | same |
| App icon, partial Info.plist | `CFBundleIcons.CFBundlePrimaryIcon` = `CFBundleIconFiles ["AppIcon60x60"]`, `CFBundleIconName AppIcon`; `CFBundleIcons~ipad` = `["AppIcon60x60","AppIcon76x76"]` | same as 27A266a | identical | `plutil -convert json -o - <out>/partial.plist` |
| Parity catalog partial Info.plist | `<dict/>` | same as 27A266a | `<dict/>` | same |
| stdout (`human-readable-text`) | `/* com.apple.actool.compilation-results */` and the two output paths | same as 27A266a | identical | the compile command above |
| Exit code | 0 | same as 27A266a | 0 | same |
| Needs a simulator runtime of its own | no beyond iOS 27.0 | no beyond iOS 27.0 (the installed runtime was enough) | yes: an iOS 26.x runtime (`iOS 26.2 Platform Not Installed` without one) | `scripts/ib-golden.sh` before the download |

## ibtool

| Field | 27A266a | 27A9275 | 17C52 | Observed with |
|---|---|---|---|---|
| `--version` `short-bundle-version` | `27.0` | `27.1` | `26.2` | `xcrun ibtool --version --output-format xml1` |
| `--version` `bundle-version` | `25098` | same as 27A266a | `24506` | same |
| `IBTOOL_VERSION` line 1 | `ibtool 27.0 (25098)` | `ibtool 27.1 (25098)` | `ibtool 26.2 (24506)` | `scripts/ib-golden.sh`, from the line above |
| Highest accepted capability `minToolsVersion` | `27.0` (`27.1` is refused: `error: This document requires at least Xcode 27.1.`) | `27.1` (`27.2` is refused: `error: This document requires at least Xcode 27.2.`; 28.0 likewise) | `26.2` (`26.3` is refused: `error: This document requires at least Xcode 26.3.`) | corpus storyboard `view-plain-default.storyboard` with the `<capability name="documents saved in the Xcode 8 format" minToolsVersion="8.0"/>` value replaced by 16.0, 17.0, 18.0, 26.0 to 26.4, 27.0, 27.1, 28.0, each compiled with `xcrun ibtool --errors --warnings --notices --output-format human-readable-text --module IBProbe --target-device iphone --minimum-deployment-target 16.0 --compile <out>.storyboardc <file>`; exit 0 or 1 |
| Highest accepted `<document toolsVersion>` | no limit: 23727, 24506, 25098, 25099, 26000, 27000, 50000 and 999999 all compile (exit 0) | same as 27A266a | same, no limit (25098 compiles under 17C52) | same storyboard with `toolsVersion` replaced, same command |
| `<plugIn ... version>` limit | none: 24506, 25098, 99999 compile | same as 27A266a | none | same, with the `IBCocoaTouchPlugin` `version` replaced |
| Refusal of a newer document | only through a capability whose `minToolsVersion` is above the Xcode's short version, exit 1, `IBDocumentMissingCapabilityException` logged by `ibtoold` | same as 27A266a | same | the `minToolsVersion` row |
| Log output of a clean compile and link | empty | same as 27A266a | empty | `scripts/ib-golden.sh` fails on any output; it did not |
| `Info.plist` of every compiled `.storyboardc` (298 corpus cases, 4 flag sets) | identical to 17C52 | identical to 27A266a: `diff -rq Tests/IBCorpus/golden/27A266a Tests/IBCorpus/golden/27A9275` lists only `IBTOOL_VERSION` | identical | `diff -rq Tests/IBCorpus/golden/27A266a Tests/IBCorpus/golden/17C52`: 420 lines, 419 of them `.nib` files, the rest `IBTOOL_VERSION`; no `Info.plist` and no `UIViewController-*.nib` differs |

Task 3 note: a stale storyboard `toolsVersion` is not what ibtool refuses. The limit that makes an older ibtool refuse a
newer document is the capability `minToolsVersion` against the Xcode's `short-bundle-version` (27.0 and 26.2 above). A plain
`toolsVersion="25098"` document compiles under 26.2.

### Compiled nib differences (view nibs only, 419 files of 924)

Xcode 27.1 (27A9275) writes the same nibs as 27.0: `diff -rq Tests/IBCorpus/golden/27A266a Tests/IBCorpus/golden/27A9275` (all 298 corpus cases, 4 flag sets) lists only `IBTOOL_VERSION`, so the 27A9275 column of the tables below repeats the 27A266a one.

Measured with `xless nib dump` (xless's own reader) on `Tests/IBCorpus/golden/27A266a/<case>/<flagset>.storyboardc/*.nib` and
`.../17C52/...`, normalised for object ids (`@N`). All other bytes of those nibs are the same; the offset lines
(`UINibEncoderEmptyKey = @N`) only move with the object counts.

| Field | 27A266a | 27A9275 | 17C52 | Observed with |
|---|---|---|---|---|
| `IBUINibLNEVersionKey = int8 1` in the nib's root object | present in the view nib (409 of the 419 differing files; 920 of the 920 `.nib` files under `golden/27A266a`) | same as 27A266a | absent from the view nib in those 409 files (511 of the 920 `.nib` files under `golden/17C52` carry it, the view-controller nibs among them) | `find <dir> -name "*.nib" -print0` looped NUL-safe over `xless nib dump <nib> \| grep -q IBUINibLNEVersionKey` (file names contain spaces). The other 10 differing files carry it in both builds; what decides it was not established here (Task 3 established it: next row) (those 10 are `view-plain-default`, `view-clips`, `view-opaque-no`, `view-userinteraction-no`, `view-hugging-250/251/custom`, `view-contentmode-center/redraw`, `color-system-systemBlueColor`, all at `universal-16`) |
| Which view nibs carry it under 17C52 (Task 3, from the corpus inputs against the goldens) | all | same as 27A266a | exactly the view nibs whose views are all plain `UIView`s with safe-area layout: no `UILabel`, no `UIImageView`, no legacy `_UILayoutGuide` top/bottom guides (51 of the 460 view nibs; every one of the 409 others has at least one of the three). Without the key the nib also ends at the class names, with no `LNE\0` trailer | the class lists of all 920 `xless nib dump`s of `golden/17C52`, tabulated against the key |
| Default tint colour (system blue) baked into the nib, in the 10 files above (all plain-view nibs; in a nib with a label or image view 17C52 writes `0 0.533 1` like 27A266a, `color-default-forms`, `image-tint`) | `UIGreen = float 0.53333336`, `UIGreen-Double 0.5333333333`, `NSRGB "0 0.533 1"` | same as 27A266a | `UIGreen = float 0.47843137`, `UIGreen-Double 0.4784313725`, `NSRGB "0 0.478 1"` (red 0, blue 1 in both) | `xless nib dump` of `view-plain-default/universal-16.storyboardc/01J-lp-oVM-view-Ze5-6b-2t3.nib` and `color-system-systemBlueColor/...` |
| Precision of `UIRed-Double`, `UIGreen-Double`, `UIBlue-Double` (and `UIAlpha-Double`) of system colours (Task 3: colours written in the storyboard with decimals are rounded in both builds, `color-srgb-precision`, `color-srgb-small-grid`; the difference is only system colours, in nibs other than plain-view ones) | the decimal rounded to 10 digits, then parsed: e.g. `0.5333333333` (`3fe11111110c7c41`), `0.2352941176` (`3fce1e1e1e043f2d`) | same as 27A266a | the double nearest the colour, no rounding: `0.5333333333333333` (`3fe1111111111111`), `0.23529411764705882` (`3fce1e1e1e1e1e1e`) | `xless nib dump` of `color-default-forms`, `image-tint`, `label-color-forms` and others (39 files differ in the green component, 18 in red and blue) |
| Float `UIGreen` etc. of the same colours | same in both except the system-blue row | same as 27A266a | same | same |
| `label-font-grid`: `NSDictionary` objects for font descriptor attributes | 402 objects | same as 27A266a | 404 objects: 2 more `NSDictionary` (`NSInlinedValue = true`) | `xless nib dump` object counts of `label-font-grid/*/01J-lp-oVM-view-Ze5-6b-2t3.nib`, 4 flag sets |
| `label-font-grid` (Task 3): which italic fonts share the `{NSCTFontSymbolicTrait: 1}` dictionary | all eight sizes share one | same as 27A266a | 0.5, 1, 9 and 13 pt share one; 20 pt has its own; 28, 48 and 100 pt share a third. Those are the 2 extra `NSDictionary` objects | same |
| `label-custom-font-grid`: an extra 17 pt font (Task 3: the second label with the same unresolved font `NoSuchFont-Bold` 17 gets its own `UIFont`, descriptor and dictionary; its strings and number are shared; measured with two labels only, so that three or more behave the same is an assumption) | 82 objects | same as 27A266a | 85 objects: one more `UIFont` (17.0, `UISystemFont false`), `UIFontDescriptor` and `NSDictionary` | same, `label-custom-font-grid`, 4 flag sets |
| `label-behavior-grid` (Task 3, not in the first count): a label without text | `UIText = nil` | same as 27A266a | no `UIText` key | the `diff` of the two dumps, 4 flag sets |

## copypng

| Field | 27A266a | 27A9275 | 17C52 | Observed with |
|---|---|---|---|---|
| Output of all cases (10 PNGs x `-compress -strip-PNG-text`, `-compress`, `-strip-PNG-text`, no option) | the fields recorded in `copypng/27A266a.json` | identical to `copypng/27A266a.json` in every field (`diff` shows only `xcodeBuild`) | identical to `copypng/17C52.json` in every field (`diff` shows only `xcodeBuild`) | `scripts/copypng-golden.sh`, running `xcrun copypng [options] in.png out.png`; `xcrun --find copypng` is a different path per Xcode |
| 8-bit RGBA / RGB with `-compress` | `CgBI` first, bytes `50002002` (RGBA) or `50002006` (RGB-turned-RGBA), then `IHDR`, `IDAT`, `IEND`; an input `tEXt` is kept by `-compress` alone and dropped with `-strip-PNG-text` | same as 27A266a | same | the JSON files |
| 16-bit inputs (RGB, RGBA, gray) | with `-compress` and/or `-strip-PNG-text`: output byte-identical to the input, `libpng warning: Warning: Input PNG does not have an 8 bit input depth.` on stderr; exit 0 | same as 27A266a | same | the JSON files |
| 8-bit gray (`gray-1x1`) | with `-compress` and/or `-strip-PNG-text`: rewritten (not byte-identical to the input) but not CgBI-converted: colorType stays 0, `cgbi` null, chunk order `IHDR, IDAT, IEND`; with no option: byte-identical copy | same as 27A266a | same | `copypng/<build>.json` cases `gray-1x1` |
| 8-bit RGB with `sRGB` chunk (`rgb-1x1-srgb`) | with `-compress` and/or `-strip-PNG-text`: converted to colorType 6 with `CgBI` `50002006`, chunk order `CgBI, IHDR, gAMA, sRGB, cHRM, IDAT, IEND`; with no option: byte-identical copy, chunk order `IHDR, sRGB, IDAT, IEND`, colorType 2; the shim refuses both the gray and the sRGB case as not measured | same as 27A266a | same | `copypng/<build>.json` cases `rgb-1x1-srgb` |

Task 3 note: nothing in copypng differs between the three builds, so it needs no profile field.

## Concerns recorded while measuring

- `Tests/IBCorpus/golden/<build>/` holds the compiled `.storyboardc` files (nibs and `Info.plist`) that ibtool wrote. That is
  Apple tool output, not only `assetutil`/`plutil` fields. The 27A266a set was committed that way before this task, and
  the 17C52 set follows the same form so the two can be compared; this is recorded as a concern, not a policy change.
- The corpus storyboards, the Parity catalog and the copypng PNGs are xless-made.
