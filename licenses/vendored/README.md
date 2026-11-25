# Vendored third-party notices

Verbatim copies of the upstream licence files for everything that is linked statically into the release `xless` binary
(on Linux a musl build with the Swift static Linux SDK 0.1.0 for Swift 6.4.0) and is not a SwiftPM package of this repository.
They are shipped in `share/xless/licenses/` by `scripts/third-party-licenses.sh`, which refuses to copy a file whose
sha256 differs from `SOURCES.tsv`; `Tests/shell/licenses.test.sh` checks the same. Nothing here is hand-written.

## How the linked set was determined

`swift build -c release --product xless --swift-sdk aarch64-swift-linux-musl -v -Xlinker -Map=map.txt` in
`swift:6.4.0-jammy` (SDK from `versions.env`), then the archives that contributed members to the link map:

| Archive (SDK `usr/lib`)                                    | Component and notice                                        |
|------------------------------------------------------------|-------------------------------------------------------------|
| `swift_static/linux-static/libswiftCore.a`, `libswift_Concurrency.a`, `libswift_StringProcessing.a`, `libswift_RegexParser.a`, `libswiftSynchronization.a`, `libswiftMusl.a` | Swift runtime and standard library: `swift` |
| `libFoundation.a`, `libFoundationXML.a`, `libFoundationNetworking.a`, `libCoreFoundation.a`, `lib_CFXMLInterface.a`, `lib_CFURLSessionInterface.a` | `swift-corelibs-foundation` |
| `libFoundationEssentials.a`, `libFoundationInternationalization.a`, `lib_FoundationCollections.a`, `lib_FoundationCShims.a` | `swift-foundation` |
| `lib_FoundationICU.a`                                      | `swift-foundation-icu` and ICU 76.1 (`icu`)                 |
| `libswiftDispatch.a`, `libdispatch.a`, `libBlocksRuntime.a` | `swift-corelibs-libdispatch`                                |
| `libc.a`                                                   | `musl` 1.2.5                                                |
| `libfts.a`                                                 | `musl-fts` 1.2.7                                            |
| `libcurl.a`                                                | `curl` 8.15.0                                               |
| `libssl.a`, `libcrypto.a`                                  | `boringssl`                                                 |
| `libxml2.a`                                                | `libxml2` 2.14.5                                            |
| `libz.a`                                                   | `zlib` 1.3.1                                                |
| `libc++.a`, `libc++abi.a`, `libunwind.a`, `clang/lib/linux/libclang_rt.builtins-aarch64.a` | LLVM: `libcxx`, `libcxxabi`, `libunwind`, `compiler-rt` |

Not linked (present in the SDK, no member reached the link): mimalloc, bzip2, XZ Utils, libarchive.
The SDK's own bill of materials (`sbom.spdx.json`) lists the versions used above; it records no BoringSSL version, so the
BoringSSL notice is the file at the upstream commit named below (the LICENSE has been stable for years).
On macOS the Swift runtime, Foundation, CryptoKit, curl, libxml2, zlib and the C library are the system's, and no archive of
the toolchain reaches the link (`swift build -c release --product xless -Xswiftc -runtime-compatibility-version -Xswiftc none
-Xlinker -map -Xlinker map.txt`: objects of this repository and its packages only, for arm64 and x86_64). A macOS package gets
the notices of what the compiler puts into those objects (`swift`, `compiler-rt`), of BoringSSL (in swift-crypto) and of
libyaml.
libyaml is not in the SDK: SwiftPM's Yams 6.2.2 bundles its source (`Sources/CYaml`), and the notice is libyaml 0.2.5's
(the bundled copy is a later libyaml revision; the licence text of the 0.2.x line is the same MIT licence).
The SwiftPM packages in `Package.resolved` (and the in-repo `ThirdParty/AssetKit`, with its CLZFSE) get their notices from
their own checkouts, in `scripts/third-party-licenses.sh`.

## Files

| File | Component | Version / ref | Source | sha256 |
|------|-----------|---------------|--------|--------|
| `swift-LICENSE.txt` | swift | 6.4.0-RELEASE | <https://raw.githubusercontent.com/swiftlang/swift/swift-6.4.0-RELEASE/LICENSE.txt> | `770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55` |
| `swift-corelibs-foundation-LICENSE.txt` | swift-corelibs-foundation | 6.4.0-RELEASE | <https://raw.githubusercontent.com/swiftlang/swift-corelibs-foundation/swift-6.4.0-RELEASE/LICENSE> | `0ca84095d1de77cad1a866ebbad28f8db98a0826c6055d92b0608c5baa1643e2` |
| `swift-foundation-LICENSE.txt` | swift-foundation | 6.4.0-RELEASE | <https://raw.githubusercontent.com/swiftlang/swift-foundation/swift-6.4.0-RELEASE/LICENSE.md> | `2245a990b635558be210fb3eb4f8a6f7a49aebc0fefbf5859146a65ddc7ddcf3` |
| `swift-corelibs-libdispatch-LICENSE.txt` | swift-corelibs-libdispatch | 6.4.0-RELEASE | <https://raw.githubusercontent.com/swiftlang/swift-corelibs-libdispatch/swift-6.4.0-RELEASE/LICENSE> | `0ca84095d1de77cad1a866ebbad28f8db98a0826c6055d92b0608c5baa1643e2` |
| `swift-foundation-icu-LICENSE.txt` | swift-foundation-icu | 6.4.0-RELEASE | <https://raw.githubusercontent.com/swiftlang/swift-foundation-icu/swift-6.4.0-RELEASE/LICENSE.md> | `2245a990b635558be210fb3eb4f8a6f7a49aebc0fefbf5859146a65ddc7ddcf3` |
| `icu-LICENSE.txt` | icu | 76.1 | <https://raw.githubusercontent.com/unicode-org/icu/release-76-1/LICENSE> | `01edac20612b1e590c1c1cfb02b7218c6adc7b0a944eda7a1e03aeee10725aed` |
| `musl-COPYRIGHT.txt` | musl | 1.2.5 | <https://git.musl-libc.org/cgit/musl/plain/COPYRIGHT?h=v1.2.5> | `f9bc4423732350eb0b3f7ed7e91d530298476f8fec0c6c427a1c04ade22655af` |
| `musl-fts-COPYING.txt` | musl-fts | 1.2.7 | <https://raw.githubusercontent.com/void-linux/musl-fts/v1.2.7/COPYING> | `55af87e4017668f54467a3380e7ebbac5e672d8c763bfe95e6fc882a6fdc4046` |
| `curl-COPYING.txt` | curl | 8.15.0 | <https://raw.githubusercontent.com/curl/curl/curl-8_15_0/COPYING> | `e18f1989333b70044b2adfb7dc2f905d0119dbdcac3bc9f4bc9d540e3a29de5b` |
| `libxml2-Copyright.txt` | libxml2 | 2.14.5 | <https://raw.githubusercontent.com/GNOME/libxml2/v2.14.5/Copyright> | `5d4873884a890122a4b9b20ad56ac6f7da1d796a5bfcf04a427970ac96217626` |
| `zlib-LICENSE.txt` | zlib | 1.3.1 | <https://raw.githubusercontent.com/madler/zlib/v1.3.1/LICENSE> | `845efc77857d485d91fb3e0b884aaa929368c717ae8186b66fe1ed2495753243` |
| `boringssl-LICENSE.txt` | boringssl | 83687b75b2a8 | <https://raw.githubusercontent.com/google/boringssl/83687b75b2a884c128658f680965705709679576/LICENSE> | `827c8d8fc207c2392794eef9e00fe246f9f61fdcc132556c275be3dd8c3cd97f` |
| `llvm-libcxx-LICENSE.txt` | libcxx | 6.4.0-RELEASE | <https://raw.githubusercontent.com/swiftlang/llvm-project/swift-6.4.0-RELEASE/libcxx/LICENSE.TXT> | `539dd7aed86e8a4f12cbdd0e6c50c189c7d74847e4fecc64ce2c6ee3a01da38b` |
| `llvm-libcxxabi-LICENSE.txt` | libcxxabi | 6.4.0-RELEASE | <https://raw.githubusercontent.com/swiftlang/llvm-project/swift-6.4.0-RELEASE/libcxxabi/LICENSE.TXT> | `e2b35be49f7284a45b7baca8fc7b3ab7440e7902392b2528a457816b5bb2a15c` |
| `llvm-libunwind-LICENSE.txt` | libunwind | 6.4.0-RELEASE | <https://raw.githubusercontent.com/swiftlang/llvm-project/swift-6.4.0-RELEASE/libunwind/LICENSE.TXT> | `b5efebcaca80879234098e52d1725e6d9eb8fb96a19fce625d39184b705f7b6d` |
| `llvm-compiler-rt-LICENSE.txt` | compiler-rt | 6.4.0-RELEASE | <https://raw.githubusercontent.com/swiftlang/llvm-project/swift-6.4.0-RELEASE/compiler-rt/LICENSE.TXT> | `1a8f1058753f1ba890de984e48f0242a3a5c29a6a8f2ed9fd813f36985387e8d` |
| `libyaml-LICENSE.txt` | libyaml | 0.2.5 | <https://raw.githubusercontent.com/yaml/libyaml/0.2.5/License> | `c40112449f254b9753045925248313e9270efa36d226b22d82d4cc6c43c57f29` |

The LLVM files are from `swiftlang/llvm-project` at `swift-6.4.0-RELEASE` (the fork the Swift toolchain ships); the BoringSSL
ref is the upstream commit `83687b75b2a884c128658f680965705709679576`, the tip when the file was vendored.
