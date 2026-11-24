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

All six are required. `title` is `.github/workflows/title.yml`, the only check that editing a pull request's title or
description re-runs; the others are `.github/workflows/pr.yml`, which runs when commits are pushed:

| Check | What it runs |
|---|---|
| `title` | The pull request title against the regular expression above |
| `linux-tests (x86_64)`, `linux-tests (arm64)` | `swift test`, AssetKit's tests and every `Tests/shell/*.test.sh`, in `swift:6.4.0-jammy`, pinned by digest (`SWIFT_IMAGE` in `versions.env`) |
| `package (x86_64)`, `package (arm64)` | The release tarball built as a release would build it, installed with `scripts/install.sh` from a local release, and run |
| `shellcheck` | shellcheck on the shipped scripts |

CI never touches an Xcode, an SDK or an image, and uses no Apple secret.

Before you push, run what you can locally: `swift test`, `make test-linux` (the tests in Linux, through Docker),
`bash Tests/shell/<name>.test.sh`, and `python3 -I scripts/check-doc-links.py README.md CONTRIBUTING.md docs/*.md`
after editing the documentation.

The tests pass as root and as a regular user, under any umask and locale, and run in parallel. A test (or code) that
writes a script or stand-in tool and runs it writes it with `ExecutableFile.write` (XlessCore), never with `Data.write`
and a chmod: a file written in-process can still be open for writing in a child another thread is starting, and Linux
then refuses to run it ("Text file busy"). A shell test that lists or sorts names sets `LC_ALL=C`.

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

The root README is for a newcomer: what xless is, how to install it and build a first app. Everything else goes under
`docs/` ([docs/README.md](docs/README.md) is the index). The maintainer's private notes (`docs/superpowers/`,
`docs/acceptance/`) are git-ignored and stay local; never commit them.

## Licence

By contributing you agree that your contribution is released under the [MIT licence](LICENSE).
