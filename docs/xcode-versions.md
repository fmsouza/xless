# Xcode: the versions, and the download

**Do you need it?** On a Mac, xless builds with the Xcode that is installed there: you download nothing for xless. The account
commands need no Xcode on any system. To build on Linux, or in Docker on either system, xless takes Apple's SDK out of the
Xcode download, a `.xip` file. It never runs a program from it. A free Apple ID is enough to get it.

## The versions

| Xcode | Build | File to download | Swift, on Linux and in Docker |
|---|---|---|---|
| 27.2 | 27B52 | `Xcode_27.2.xip` | 6.4.2 |
| 27.1 | 27A9275 | `Xcode_27.1.xip` | 6.4.0 |
| 27.0 | 27A266a | `Xcode_27.xip` | 6.4.0 |
| 26.6 | 17F113 | `Xcode_26.6_Universal.xip` | 6.3.3 |
| 26.5 | 17F42 | `Xcode_26.5_Universal.xip` | 6.3.2 |
| 26.4.1 | 17E202 | `Xcode_26.4.1_Universal.xip` | 6.3.1 |
| 26.4 | 17E192 | `Xcode_26.4_Universal.xip` | 6.3.0 |
| 26.3 | 17C529 | `Xcode_26.3_Universal.xip` | 6.2.4 |
| 26.2 | 17C52 | `Xcode_26.2_Universal.xip` | 6.2.3 |
| 26.1.1 | 17B100 | `Xcode_26.1.1_Universal.xip` | 6.2.1 |
| 26.1 | 17B55 | `Xcode_26.1_Universal.xip` | 6.2.1 |
| 26.0.1 | 17A400 | `Xcode_26.0.1_Universal.xip` | 6.2.0 |

Where Apple offers a "Universal" and an "Apple silicon" file, take the Universal one: that is the one xless is checked against
(for 26.2, xless also accepts the Apple silicon file). The Swift is swift.org's open-source release of the Swift in that
Xcode; `xless setup` installs it.

xless recognises the file by its SHA-256, not by its name, and refuses any other with the list of supported versions
([what to do then](troubleshooting.md#xless-setup)). An unpacked `Xcode.app` is accepted too, identified by its
`Contents/version.plist`. Adding a version: [maintainers.md](maintainers.md).

## Get it from the terminal

```sh
xless xcode download 27.0 26.2 --output-dir ~/Downloads
```

It asks for your Apple ID, its password and a two-factor code, signs in to Apple once and downloads every version you name,
keeping nothing of the sign-in unless you say so: [xcode-download.md](xcode-download.md). (Not on Windows.)

## Get it in a browser

1. Open <https://developer.apple.com/download/all/> and sign in with your Apple ID. You accept Apple's Xcode licence when you
   download.
2. Search for the Xcode version and download the file that the table names.
3. Keep it where the browser saved it, and do not unpack it. The commands in these pages assume `~/Downloads`.

Then give it to xless as it is: [build.md](build.md#on-linux).

## What xless takes out of it

[apple-requirements.md](apple-requirements.md#from-xcodexip) lists every file, and why.
