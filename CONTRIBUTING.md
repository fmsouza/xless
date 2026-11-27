# Contributing

xless is developed on GitHub, in [fmsouza/xless](https://github.com/fmsouza/xless),
through pull requests. Releases are made from `main` automatically.

## Branches and pull requests

- Work on a branch of your own, cut from an up-to-date `main`, and open a pull request against `main`.
- `main` is protected: every change arrives through a pull request, the required checks must pass, and force pushes
  are blocked.
- Pull requests are merged by **squash only**. The squash commit takes the pull request's title as its subject and its
  description as its body, so the **title** is what ends up in the history, the release notes and the version.
- Never add Apple files to the repository: no SDK, header, `.tbd`, binary or `.xip` content
  ([apple-requirements.md](docs/apple-requirements.md)).

## Titles: Conventional Commits

Every pull request title (and every commit subject) is a [Conventional Commit](https://www.conventionalcommits.org/),
at most 100 characters. The check is `scripts/check-commit-title.sh`, with this regular expression:

```
^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?: [^[:space:]].*$
```

- **type:** `feat` (a new feature), `fix` (a bug fix), `perf`, `docs`, `style`, `refactor`, `test`, `build`, `ci`,
  `chore` or `revert`;
- **scope** (optional): lower case, in parentheses, for example `fix(install): verify checksums`;
- **`!`** before the colon marks a breaking change, as does a `BREAKING CHANGE:` footer in the body.

Check a title locally with `scripts/check-commit-title.sh "feat(setup): accept an Xcode.app"`.

## Checks on every pull request

The six of the first table are required. `title` is `.github/workflows/title.yml`, the only check that editing a pull request's title or
description re-runs; the others are `.github/workflows/pr.yml`, which runs when commits are pushed:

| Check | What it runs |
|---|---|
| `title` | The pull request title against the regular expression above |
| `linux-tests (x86_64)`, `linux-tests (arm64)` | `swift test`, AssetKit's tests and every `Tests/shell/*.test.sh`, in `swift:6.4.0-jammy`, pinned by digest (`SWIFT_IMAGE` in `versions.env`) |
| `package (x86_64)`, `package (arm64)` | The release tarball built as a release would build it, installed with `scripts/install.sh` from a local release, and run, the agent included |
| `shellcheck` | shellcheck on the shipped scripts |

These run on every pull request too, and a red one is to be fixed like any other. The nightly does not release a commit whose
`pr.yml` run failed or has not ended, for any system: while GitHub has no macOS runner for it, a Linux release waits too, and
the release run says so in a warning.

| Check | What it runs |
|---|---|
| `macos-tests (arm64)` | `swift test`, AssetKit's tests and every shell test that can run on macOS, on GitHub's `xcode-27` runner. One (`xcode-native`) builds the sample with the runner's Xcode, for a device, the simulator and macOS, and signs it with a throw-away certificate; another (`overlay-native`) builds an overlay whose "cargo" tries the sandbox of the build, and a small React Native workspace with xcodebuild |
| `package (macos-arm64)`, `package (macos-x86_64)` | The macOS tarballs built as a release would build them (the x86_64 one cross-compiled) and checked: nothing of Apple's in them, only the system's libraries needed |
| `install (macos-arm64)`, `install (macos-x86_64)` | Each one installed with `scripts/install.sh` and run on a Mac of its architecture, the agent and the prompts included |
| `windows-tests (x86_64)` | The account commands, their libraries and their tests on GitHub's `windows-2022` runner; what can be seen only of a process of its own (no dump of one with a secret, locks, where libraries come from), what counts as a secure connection, and PSScriptAnalyzer on the PowerShell scripts ([maintainers.md](docs/maintainers.md#windows)) |
| `package (windows-x86_64)` | The Windows zip built as a release would build it, and checked: nothing of Microsoft's in it, only Windows' own libraries needed, and the Visual C++ runtime |
| `install (windows-2022)`, `install (windows-2025)` | `scripts/install.ps1` tested and the zip installed with it, by Windows PowerShell and PowerShell 7, and run in a console: a secret store made and opened |

Linux CI never touches an Xcode, an SDK or an image. The macOS jobs compile with the runner's Xcode, as any Swift program
on a Mac is; nothing of it goes into an archive, an artifact or a cache. CI uses no Apple secret.

A shell test that cannot run on a system starts with a guard that prints `SKIP` and the reason; the CI logs list them. The
tests of the xless agent need a session whose leader lives (a terminal's shell; on the runners `scripts/ci-session.sh`
makes one).

Before you push, run what you can locally: `swift test` (in a terminal), `make test-linux` (the tests in Linux, through Docker),
`bash Tests/shell/<name>.test.sh`, and `bash Tests/shell/check-doc-links.test.sh` after editing the documentation. After a
change to `docker/`, run `make images` and `make test-image` (the image holds nothing of Apple's, and builds from a pack
volume read-only: [maintainers.md](docs/maintainers.md#xcode-packs)); a change to what prepares an Xcode pack makes
every pack stale, which that section says too.

The tests pass as root and as a regular user, under any umask and locale, and run in parallel. A test (or code) that
writes a script or stand-in tool and runs it writes it with `ExecutableFile.write` (XlessCore), never with `Data.write`
and a chmod: a file written in-process can still be open for writing in a child another thread is starting, and Linux
then refuses to run it ("Text file busy"). A shell test that lists or sorts names sets `LC_ALL=C`.

A new Swift file of a target that Windows builds gets a line in `Tests/windows/sources.txt`: built there or not
([maintainers.md](docs/maintainers.md#windows)).

## Versions and releases

A release workflow runs every night at 03:00 UTC. It looks at the titles of the commits on `main` since the last
release tag and computes the next version (`scripts/next-version.sh`):

| Commits since the last release | Next version |
|---|---|
| a breaking change (`!` or `BREAKING CHANGE:`) | the next major (`1.4.2` → `2.0.0`); while the major is 0, the next minor (`0.3.1` → `0.4.0`) |
| a `feat` | the next minor (`0.3.1` → `0.4.0`) |
| a `fix`, `perf` or `revert` | the next patch (`0.3.1` → `0.3.2`) |
| only `docs`, `style`, `refactor`, `test`, `build`, `ci` or `chore` | no release that night |

The highest bump wins. The release is tagged `v<version>` and its notes are generated from the same titles. The first
release, `v0.1.0`, is cut by hand ([maintainers.md](docs/maintainers.md#releases)). The source tree's version is always
`0.0.0-dev`; only a release build stamps the real one.

### Reverts

A revert undoes a change users may already have, so it is released: a `revert` title is a patch, or a major (a minor
while the major is 0) with `!` or a `BREAKING CHANGE:` footer, for example when it removes something released as a
feature that users rely on. Title it `revert: <the reverted title>` (GitHub's Revert button proposes `Revert "…"`, which
the title check refuses) and keep the line that names what it reverts in the description: `This reverts commit <sha>.`
as `git revert` writes it, or `Reverts fmsouza/xless#<N>` as GitHub's Revert button does.

When the reverted commit has not been released yet (both land between two nightlies), the two cancel out: neither
counts towards the version or appears in the release notes. Reverting a revert in the same range brings the original
back. Released reverts are listed in the notes under **Reverts**.

## Documentation

xless is one tool for the whole life of an Apple app; a page says which system something is for only where they differ. The root
README is for a newcomer: what xless is, how to install it and a first app. Everything else goes under `docs/`, a page per task, and
[docs/README.md](docs/README.md) is the index: every page is reached from it (a test checks that). An instruction is in one place,
and other pages link to it. A page that moves keeps a pointer at its old path and headings. What is planned is marked so, with its
issue, or left out. The maintainer's private notes (`docs/superpowers/`,
`docs/acceptance/`) are git-ignored and stay local; never commit them.

## Licence

By contributing you agree that your contribution is released under the [MIT licence](LICENSE).
