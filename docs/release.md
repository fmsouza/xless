# Release a version

The listing lives in `appstore/`: change it there, review it like code, push it
([appstore-manifest.md](appstore-manifest.md)).

```sh
xless store validate                          # what a submission needs, offline
xless store push --dry-run                    # what would change on App Store Connect
xless store push                              # sends only what differs; asks before deleting anything
xless run .                                   # build 1.1 (42), upload it, deliver it to TestFlight; ends once it is processed
xless release submit --release manual --dry-run   # the pre-flight: every problem at once; names the build it would send
xless release submit --release manual             # the build the testers have
xless release status                          # waiting for review, in review, approved…
xless release publish                         # once approved, when you choose
```

- **The version.** `store push` creates the App Store version from app.yml's `version` when it does not exist yet (`xless release
  create 1.1` does it on its own).
- **The pre-flight.** `release submit` checks first, and sends nothing when something is missing: the listing in
  every locale, screenshots, App Privacy published, a price and territories, the build valid with its export compliance
  answered, the App Review contact. Run it again after fixing: it resumes where it stopped.
- **The build** is the one `--build 1.1+42` names (`xless run` prints the command), else the one attached to the version
  (`xless release attach`), else the one uploaded last from this project, if App Store Connect says that it is the version's
  newest valid build; it is named before anything is sent.
- **When it goes out.** `--release auto` releases on approval, a date (`2026-12-01`) not before then, and `--phased` spreads an
  update over seven days (`xless release phased pause|resume|complete`).
- **Rejected?** App Review's reasons are not in the API: Apple emails them.
- **An overlay's app:** give `--config <overlay.yml>` to the commands of `store` and `release`.

Nothing is sent to App Review but by `release submit`. Every option: [`xless release`](apple-account.md#xless-release).

What was tried on a real account so far: the submission, and withdrawing it. The approval and `release publish` were not
([acceptance-m7.md](acceptance-m7.md#what-the-run-did-not-check), [#181](https://github.com/fmsouza/xless/issues/181)).
