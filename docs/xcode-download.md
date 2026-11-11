# Downloading Xcode with `xless xcode download`

`xless xcode download` signs in to Apple once, in the terminal, and downloads any number of Xcode `.xip` files in that
session. It does what you would do at <https://developer.apple.com/download/all/> in a browser, without the browser:

```sh
xless xcode download 26.2 27.0 --output-dir ~/Downloads
```

It asks for your Apple ID (email), its password (not shown as you type) and the two-factor code, then downloads each
version in turn, showing progress. When it ends, each file's path is printed with whether it is one of the Xcodes xless
supports. Then give each file to `xless setup --xcode <path>`.

## Choosing versions

Versions are Apple's names without "Xcode", as separate arguments, comma-separated, or both:

| You type | Downloads Apple's |
|---|---|
| `26.2` | Xcode 26.2 |
| `27` or `27.0` | Xcode 27 (trailing `.0`s do not matter) |
| `"26 beta 3"` | Xcode 26 beta 3 |
| `16.4,26.2 27` | Xcode 16.4, Xcode 26.2 and Xcode 27 |

`xless xcode download --list` signs in and prints every Xcode release Apple offers your Apple ID, with its `.xip` and
size, and downloads nothing. Every version you ask for is checked against that list before anything downloads, so a typo
fails at once rather than after an hour of downloads. Where Apple offers a "Universal" and an "Apple silicon" `.xip`, the
Universal one is taken.

Each file goes to `<output-dir>/<Apple's file name>` (`--output-dir` defaults to the current directory) through a
`<name>.part` file. If the run is interrupted, run the same command again: it signs in again, keeps the files that are
complete and resumes the `.part`. Before it starts, it checks that the disk has room for what is left to download.

After each download the file's SHA-256 is compared with the Xcodes in `versions.env`. A file xless does not support yet
prints the `XCODE_XIP_SHA256_<build>` value to record for it ([maintainers.md](maintainers.md)).

## What happens to your Apple ID and password

Nothing of the sign-in is kept, and none of it leaves for anywhere but Apple:

- The Apple ID, password and code are read from the terminal itself (`/dev/tty`), never from a pipe, a file, an
  argument or an environment variable; without a terminal the command refuses to run. The password is read with echo
  off.
- The password is never sent, to Apple or anyone. The sign-in is Apple's own SRP protocol, the one its web sign-in
  uses: xless sends a proof computed from the password, and keeps only a hash of it for the few milliseconds that takes.
- The session's cookies live in the process's memory. Nothing is written to disk (no cookie file, no cache), logged,
  printed, or passed to another program; the downloads run inside xless, not through `curl`. Cookies are only sent to
  the Apple hosts that set them, over https.
- Core dumps are turned off for the command, so a crash cannot write its memory to disk.
- When the command ends, the session is gone; the next run signs in again.

## What it does not do

- Apple IDs that sign in with a hardware security key, managed (federated) Apple IDs, and the old two-step
  verification are refused with a message. Two-factor codes from a trusted device or by text message work.
- It downloads Xcode `.xip`s only (not the Command Line Tools, simulators or older `.dmg` Xcodes), one at a time.
- It does not run `xless setup`.

The first time an Apple ID downloads Xcode, Apple may ask it to accept the Apple Developer Agreement. If the command says
Apple refused the download list, sign in once at <https://developer.apple.com/download/all/> in a browser, accept what it
shows, and run the command again.

## How it signs in

The same steps fastlane and xcodes use, all over https to Apple:

1. The sign-in key: App Store Connect's sign-out page redirects to a URL carrying it (Olympus' app config is the
   fallback).
2. A proof of work Apple asks for (`X-Apple-HC`), then SRP-6a with Apple's 2048-bit group and SHA-256: `signin/init`,
   then `signin/complete` with the client proof.
3. The two-factor code (`verify/trusteddevice/securitycode`, or a text message with `verify/phone`), then `2sv/trust`.
4. The download list (`listDownloads.action`), and each file from `download.developer.apple.com`.

Apple does not document this interface; if Apple changes it, the command fails with a message saying so.
`XLESS_LIVE_APPLE=1 swift test --filter LiveAppleEndpointsTests` checks the first steps against Apple without signing
in.
