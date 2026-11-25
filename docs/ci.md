# CI

A job never opens the secret store: it gets its keys from variables. Make the keys on your own machine, with
[`xless provision`](get-started.md#i-have-nothing-yet) or by hand, and give the job those it needs.

## The secrets

Which variable is needed for what, and the `_FILE` form of each: [signing-and-testflight.md](signing-and-testflight.md#secrets).

| The job | Its variables |
|---|---|
| An iOS build to TestFlight | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `XLESS_DIST_KEY` |
| Account commands | the three `ASC_` ones |
| `provision plan`, `provision apply` | those, and the signing key of each lane of the project (`XLESS_DIST_KEY`, `XLESS_DEVID_KEY`, `XLESS_INSTALLER_KEY`): without a store, a lane whose key is missing is a blocker |

Export each key once, into a directory **outside** the repository: the copies are in clear. Give them to the CI's secret store, here
GitHub's, and delete them, also when one of the commands fails:

```sh
xless secrets list                                                  # the entry names, the key's ID and issuer ID
d=$(mktemp -d)                                                      # for you alone
xless secrets export ASC_KEY_P8@ABCDE12345 --out "$d/key.p8"
xless secrets export XLESS_DIST_KEY@ABCDE12345 --out "$d/dist.pem"
gh secret set ASC_KEY_P8 < "$d/key.p8"                              # in the app's repository; elsewhere, paste the file's text
gh secret set XLESS_DIST_KEY < "$d/dist.pem"
rm -r "$d"
gh secret set ASC_KEY_ID --body <KEY_ID>
gh secret set ASC_ISSUER_ID --body <ISSUER_ID>
```

Once an app exists, a release runs on the API key alone. Only new apps, new keys and App Privacy answers need the Apple ID
([why](security.md#the-apple-id-web-session)); do those from a terminal. A key made for CI alone, with the role it needs, can be
revoked alone ([`xless auth api-key`](apple-account.md#xless-auth-api-key)).

## Install

Pin the release, so that a job changes xless only when you do:

```sh
v=vX.Y.Z    # the release you use
curl -fsSLo install.sh "https://github.com/fmsouza/xless/releases/download/$v/install.sh"
gh attestation verify install.sh -R fmsouza/xless    # optional; gh needs a token (GH_TOKEN)
XLESS_VERSION=$v sh install.sh
echo "$HOME/.local/bin" >> "$GITHUB_PATH"             # GitHub Actions: for the next steps
```

The installer checks the download against the release's checksums. To check the download's own attestation:
[install.md](install.md#check-a-download). On Windows: [native-install.md](native-install.md#windows).

## Flags for a job

- `--no-input` (or `XLESS_NO_INPUT=1` for the whole job): a command fails with exit code 23 instead of asking.
- `--yes`: for what asks for a confirmation.
- `--no-provisioning-updates` (or `provisioningUpdates: false` in `xless.yml`): `sign` changes nothing on the account, and fails
  with exit code 24 when it would have to ([what `sign` changes](signing-and-testflight.md#what-sign-changes-on-the-account)).
- `--json`, and every exit code: [automate.md](automate.md#exit-codes).
- **Build numbers** must increase across every machine that uploads, so use one scheme everywhere, not the CI's run number
  ([build numbers](signing-and-testflight.md#build-numbers)).

## The runner

- **The account commands** run on any Linux, macOS or Windows runner, with nothing but xless and the variables.
- **A build on Linux** needs Apple's SDK on the runner, so it is a runner of your own that was set up once (`xless setup
  --sdk <dir>`, from [a copy of the SDK export](maintainers.md#images-on-other-machines)). The runners that GitHub offers start
  empty, and there is no image to give them: one holds Apple's SDK, so it is never pushed to a registry. Nor does the SDK go into a
  CI cache or an artifact: not `~/.cache/xless/sdk`, and not what `xless setup` makes of it (`~/.local/share/xless-native`, the
  `swift-sdks` directory).
- **A build on a Mac** needs the runner's Xcode ([native-install.md](native-install.md#on-a-mac)).

## Build without the secrets

**Never let pull requests of others run on a runner of your own, or in a job that has these secrets.** A build runs the project's
code, and that of its packages, as the runner's user: [what that code can reach](security.md#the-build-and-your-secrets).

So build in one step, without any secret, and sign and upload in another:

```yaml
env:
  XLESS_NO_INPUT: 1
steps:
  - name: The build number
    id: number
    run: echo "minutes=$(( $(date +%s) / 60 ))" >> "$GITHUB_OUTPUT"
  - name: Build (no secret)
    env:
      XLESS_BUILD_NUMBER: ${{ steps.number.outputs.minutes }}
    run: xless run . --to finalize
  - name: What the build changed in the project (no secret)
    run: git diff --exit-code
  - name: Sign and upload
    env:
      XLESS_BUILD_NUMBER: ${{ steps.number.outputs.minutes }}
      ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
      ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
      ASC_KEY_P8: ${{ secrets.ASC_KEY_P8 }}
      XLESS_DIST_KEY: ${{ secrets.XLESS_DIST_KEY }}
    run: xless run . --from sign
```

Both runs need the same build number: without one, each takes the minute it starts in, and `upload` refuses the difference.

That is for code that you mostly trust. On one machine, what the build's code can still do:

- **Change `xless.yml`** (the team, the bundle ID) or an entitlements file, as nothing keeps a native build from it. The third step
  stops at that, unless the build hid it (it can write `.git` too).
- **Reach the later steps**: write `$GITHUB_ENV` and `$GITHUB_PATH`, which set the environment and the programs of the steps after it,
  or change what those start (xless itself, where it belongs to the same user).
- **Outlive the build.** xless does not end what a build leaves running on a Mac, nor natively on Linux. It can read the environment
  of the last step as the same user.
- **Read a file of a `_FILE` variable** that is there already: write such files after the build, in the last step.

### In two jobs

The stronger form, for an `xless.yml` app, is two jobs on two machines (the runners that GitHub offers are new for each job): the
second has the secrets and gets nothing but the built app. It takes `xless.yml` and the entitlements from the commit.

```yaml
permissions:
  contents: read
env:
  XLESS_NO_INPUT: 1
jobs:
  build:
    runs-on: [self-hosted, build]    # no secret; a runner that is new for each job
    outputs:
      number: ${{ steps.number.outputs.minutes }}
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with: { persist-credentials: false }
      - id: number
        run: echo "minutes=$(( $(date +%s) / 60 ))" >> "$GITHUB_OUTPUT"
      - env: { XLESS_BUILD_NUMBER: "${{ steps.number.outputs.minutes }}" }
        run: xless run . --to finalize
      - run: tar -C .xless/build/ios -cf app.tar final    # a tar: an artifact keeps no file modes
      - uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with: { name: app, path: app.tar, retention-days: 1 }
  ship:
    needs: build
    runs-on: [self-hosted, sign]     # another machine, for this workflow only
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with: { persist-credentials: false }
      - uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093 # v4.3.0
        with: { name: app, path: "${{ runner.temp }}/built" }
      - run: |
          mkdir -p .xless/build/ios
          tar -C .xless/build/ios --no-same-owner -xf "$RUNNER_TEMP/built/app.tar" final
          git diff --exit-code
      - env:
          XLESS_BUILD_NUMBER: ${{ needs.build.outputs.number }}
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          ASC_KEY_P8: ${{ secrets.ASC_KEY_P8 }}
          XLESS_DIST_KEY: ${{ secrets.XLESS_DIST_KEY }}
        run: xless run . --from sign --no-provisioning-updates
```

- `.xless/build/ios/final` is all that `--from sign` needs of the build of an iOS `xless.yml` app. (`dSYMs` beside it, where the build kept any, only makes
  the `.dSYM.zip` next to the `.ipa`.) On Linux the signing machine needs `xless setup` too, for the signer; on a Mac the first command
  that signs fetches it.
- **The account.** The bundle IDs of app extensions that `xless.yml` does not declare come from the build's Info.plists, and `sign`
  would register them, with their profiles. So run `xless provision apply` first, from a terminal, and sign with
  `--no-provisioning-updates`, as above: nothing that the build wrote then changes the account (`sign` fails with exit code 24
  instead). Declare the app's extensions too (`platforms.ios.extensions`, [xless-yml.md](xless-yml.md#app-extensions)).
- **The runners.** The build's keeps what the build left on it: register it with `--ephemeral`, or use a new virtual machine for
  each job. The signing one takes jobs of this workflow only (a runner group that only this repository and workflow may use), so
  that no other job lands where the keys are.
- Use no cache in the second job: the first could have filled it.
- The artifact is the unsigned app. Whoever may read the repository can download it while it is kept.
- The app is still the build's: the second job signs and uploads what the first one made
  ([what the build decides](security.md#the-build-and-your-secrets)). For code that you do not trust, build with
  `--docker` in the first job, which shows the build nothing but the project, and read that page first.

This was tried in pieces, without Apple's answer: the signing, in a fresh checkout with that directory alone, up to its first call to App
Store Connect, the packaging, and the upload up to its own. It has not been run as a workflow.

## An example

[examples/example-ios.yml](examples/example-ios.yml) is a GitHub Actions workflow, with the two steps, to copy into your app's
repository and adapt. It runs on a self-hosted Linux runner. It has not been run yet.
