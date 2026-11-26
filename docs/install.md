# Install: upgrades, versions, checking a download

The install lines for each system are in the [README](../README.md#install). This page is about what they do and how to change
it. None of them needs an Apple account, Xcode or Docker: the account commands work right after the install, and what a build
needs is in [build.md](build.md).

## Linux and macOS

The line puts `xless` in `~/.local/bin` and its support files in `~/.local/share/xless`, on Linux (x86_64, arm64) and on
macOS 14 or later (Intel, Apple silicon). It checks the download against the release's checksums before it replaces
anything, and needs no `sudo`.

- **PATH.** If it says that `~/.local/bin` is not on `PATH` in this shell, run the `export` line it prints, and add that line to
  the file it names. On Linux, open a new terminal first: many systems add `~/.local/bin` at login once it exists.
- **Check it:** `xless --version`.
- **Upgrade:** run the line again. It replaces the program and its support files together, and keeps your secret store. xless
  refuses support files from another release than its own ([troubleshooting.md](troubleshooting.md#installing)).
- **A given release, or another place:** `XLESS_VERSION` and `XLESS_PREFIX`
  ([the line with both](troubleshooting.md#installing)).
- **The macOS program is signed ad hoc**, not by an Apple developer: [what that means](security.md#linux-and-macos). Install it
  with the line rather than from a browser's download.

## Windows

The line for Windows installs the account commands. What it needs, where things go, how to upgrade or remove it, and what is
not there: [native-install.md](native-install.md#windows). Builds run inside WSL 2, or on a Mac or Linux.

## WSL 2

Inside a WSL 2 distribution, use the line for Linux, in the distribution's own shell. **Before you build there, read
[In WSL](security.md#in-wsl):** on a distribution as it is installed, a build can reach Windows, and be root in the
distribution, whatever xless does. [A distribution for builds](security.md#a-distribution-for-builds) says how to set one up
for that.

## Check a download

The installers check the release's checksum, and need no `gh` for it. Each release file (the tarballs, the Windows zip,
`SHA256SUMS`, `install.sh` and `install.ps1`) also carries a signed build provenance attestation: proof that the release
workflow of `fmsouza/xless` built it, from which commit. To check a file yourself with the
[GitHub CLI](https://cli.github.com/), signed in with `gh auth login`:

```sh
gh attestation verify xless-<version>-<linux|macos>-<arch>.tar.gz -R fmsouza/xless
```

## From source

[native-install.md](native-install.md#from-a-source-checkout) for a checkout on Linux; [CONTRIBUTING.md](../CONTRIBUTING.md) for
working on xless.

## Remove it

[uninstall.md](uninstall.md).
