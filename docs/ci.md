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
- **A build on Linux** needs Apple's SDK on the runner, so it is a runner of your own that was set up once, from
  [a copy of the SDK export](maintainers.md#images-on-other-machines): natively (`xless setup --sdk <dir>`), or with Docker
  (`xless setup --docker --sdk <dir>`: the xless image and the Xcode pack's volume, for `xless run --docker` or for
  [jobs in the image](#in-the-image)). The xless image holds nothing of Apple's, but a build needs the Xcode pack too,
  which does: the SDK export and the packs never go to a registry, a CI cache or an artifact (not `~/.cache/xless/sdk`,
  not the store `~/.local/share/xless-native/xcodes`, not a pack volume). So the runners that GitHub offers, which start
  empty, do not build.
- **A build on a Mac** needs the runner's Xcode, and for an overlay its Rust, Node or Ruby
  ([native-install.md](native-install.md#on-a-mac)).

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

That is for code that you mostly trust: the steps keep a mistake of the build away from the secrets, not code that means harm,
and the `git diff` step is a check for accidents. For code that means harm, use [two jobs](#in-two-jobs)
([what keeps such a build from the secrets, and what does not](security.md#a-build-that-means-harm)). On one machine,
what the build's code can still do:

- **Change `xless.yml`** (the team, the bundle ID) or an entitlements file, as nothing keeps a native build from it. The third step
  finds such a change made by mistake, not one that the build hides: it can write `.git`, so it can stage its change in the
  index (`git diff` compares with the index), or name a program in `.git/config` (`core.fsmonitor`, `diff.external`) that the
  `git diff` of the third step then runs, as the runner's user, before the secrets come.
- **Reach the later steps**: write `$GITHUB_ENV` and `$GITHUB_PATH`, which set the environment and the programs of the steps after it,
  or change what those start: xless itself, where it belongs to the same user, and every file of the checkout that a later step
  runs or reads (a script of the repository, a local action under `.github/actions`, a `Makefile`).
- **Outlive the build.** xless does not end what a build leaves running on a Mac, nor natively on Linux. It can read the environment
  of the last step as the same user.
- **Read a file of a `_FILE` variable** that is there already: write such files after the build, in the last step.

### In two jobs

For code that you do not trust, the form for an `xless.yml` app is two jobs on two machines (the runners that GitHub offers are new
for each job): the second has the secrets and gets nothing of the build but the built app. It takes `xless.yml` and the
entitlements from the commit ([why](security.md#a-build-that-means-harm)).

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
- **The runners.** What must hold is that nothing a build job wrote is on the signing job's machine, other than the
  artifact. A runner that is new for each job gives that (register it with `--ephemeral`, or use a new virtual machine for
  each job); a runner that is kept, and also runs build jobs, does not, unless its workspace, caches and tool directories
  are apart from theirs. The build's runner keeps what the build left on it, so make it new for each job too. The signing
  one also takes jobs of this workflow only (a runner group that only this repository and workflow may use), so that no
  other job lands where the keys are.
- Use no cache in the second job: the first could have filled it.
- The artifact is the unsigned app. Whoever may read the repository can download it while it is kept.
- **The second job runs nothing that the build made**: no script and no `git` on it. It checks out the commit, unpacks the
  tar's `final` alone into `.xless/build/ios` of that checkout, and runs xless's signing on it. GNU tar refuses member
  names with `..`; given a tar whose links lead out of `final` and whose later members go through them, GNU tar 1.34 wrote
  nothing outside and failed, so the step stops.
- The app is still the build's: the second job signs and uploads what the first one made
  ([what the build decides](security.md#the-build-and-your-secrets)). xless looks at it as a tree before it signs a copy,
  which keeps the build from reaching outside the app through it, and proves nothing about what the app does. The first
  job has no secret, so how it builds (natively, `--docker`, in the image) changes what its runner keeps, not the signing.

This was tried in pieces, without Apple's answer: the signing, in a fresh checkout with that directory alone, up to its first call to App
Store Connect, the packaging, and the upload up to its own. It has not been run as a workflow.

### In the image

On a runner of your own with Docker, where `xless setup --docker --sdk <dir>` made the xless image and the pack volume
once, each step can be a container of the image ([images.md](images.md#using-the-image-directly)): the build in one
without any secret, the signing in another, with the pack read-only in both. Nothing of the runner but the checkout and the
pack is in either.

This is one job on one runner: like the native steps above, it keeps a build's mistake away from the secrets, not code
that means harm ([security.md](security.md#a-build-that-means-harm)); for that, use [two jobs](#in-two-jobs). The
build's container writes the checkout as the runner's user, and what it leaves there is on the runner when the secrets
come. What the job below still does, as hardening, and what each part does not close:

- **`.git` is read-only in the build's container** (a mount of its own over the checkout's). It closes the top
  repository's `.git/config` (`core.fsmonitor`, `core.pager`, `diff.external`, an alias), its hooks, its index and its
  refs: the build can neither name a program there nor stage or commit what it changed. It does not close a `.git` in
  the working tree below it: the build can make a repository of its own in any directory (`git init`), also in a
  submodule's path, empty or not (where `actions/checkout` fetched the submodule, its `.git` is a file the build can
  rewrite). So mounting only the app's directory gives nothing of this: a `git` started there reads the build's own
  repository.
- **The check runs at the repository's top, as `git -C "$GITHUB_WORKSPACE" --no-optional-locks diff --exit-code
  --ignore-submodules=all`.** Without `--ignore-submodules=all`, `git diff` looks into each submodule's path, and a
  repository the build made there has the runner run what its configuration names. With it, git looks
  into none, and a change to a tracked file is still reported. It does not close a filter or a diff driver that the
  runner's own git configuration defines (git-lfs's is common): a `.gitattributes` the build wrote can select it for its
  files. It compares tracked files only: an untracked or ignored file the build wrote (an entitlements file that git
  ignores, say) is not compared. Options such as `-c core.fsmonitor=` do not stand in for the read-only `.git`.
- **Nothing else of the checkout runs on the runner after the build**: no script of the repository, local action
  (`.github/actions`), `Makefile` or tool that reads its configuration from the working directory; the signing runs in a
  container of the xless image, which runs xless alone. It does not cover what runs there anyway: `actions/checkout`'s
  post step runs `git submodule foreach --recursive …` in the workspace to remove credentials (v4.2.2, whatever
  `persist-credentials` says), which enters a repository the build made in a submodule's path and runs what its
  configuration names, after the signing step.
- **The build's container gets the checkout and the pack, and nothing else of the runner**: not `$RUNNER_TEMP` (where
  `$GITHUB_ENV` and `$GITHUB_PATH` are), not the runner's home or its tool cache, not Docker's socket. What the build
  leaves running ends with its container (Docker stops every process of a container when its first one ends).
- **A runner that keeps its workspace** keeps what the build wrote in it for the next job: register it with
  `--ephemeral`, or use a new virtual machine for each job.

```yaml
env:
  XLESS_NO_INPUT: 1
  IMAGE: xless:1.4.0-amd64                      # the image xless setup --docker built on this runner
  PACK: xless-xcode-26.2-17C52-amd64            # the pack volume of the Xcode the project pins
steps:
  - id: number
    run: echo "minutes=$(( $(date +%s) / 60 ))" >> "$GITHUB_OUTPUT"
  - name: Build (no secret)
    env:
      XLESS_BUILD_NUMBER: ${{ steps.number.outputs.minutes }}
    run: |
      docker run --rm --pull=never --user "$(id -u):$(id -g)" -e HOME=/tmp -e XLESS_NO_INPUT -e XLESS_BUILD_NUMBER \
        --mount "type=volume,src=$PACK,dst=/xcodes,readonly" \
        -v "$GITHUB_WORKSPACE:/work" -v "$GITHUB_WORKSPACE/.git:/work/.git:ro" -w /work "$IMAGE" xless run . --to finalize
  - name: What the build changed in the project, a check for accidents (no secret)
    run: git -C "$GITHUB_WORKSPACE" --no-optional-locks diff --exit-code --ignore-submodules=all
  - name: Sign and upload
    env:
      XLESS_BUILD_NUMBER: ${{ steps.number.outputs.minutes }}
      ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
      ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
      ASC_KEY_P8: ${{ secrets.ASC_KEY_P8 }}
      XLESS_DIST_KEY: ${{ secrets.XLESS_DIST_KEY }}
    run: |
      docker run --rm --pull=never --user "$(id -u):$(id -g)" -e HOME=/tmp -e XLESS_NO_INPUT -e XLESS_BUILD_NUMBER \
        -e ASC_KEY_ID -e ASC_ISSUER_ID -e ASC_KEY_P8 -e XLESS_DIST_KEY --mount "type=volume,src=$PACK,dst=/xcodes,readonly" \
        -v "$GITHUB_WORKSPACE:/work" -v "$GITHUB_WORKSPACE/.git:/work/.git:ro" -w /work "$IMAGE" xless run . --from sign
```

- `-e NAME` without a value passes the step's variable on, so the secrets are not on the command line.
- `.git` must be a directory, as `actions/checkout` makes it. Where it is a file (a worktree, a submodule), the build
  could rewrite where it points: check out a plain clone.
- The signing container reads what the build wrote in the project: the app, and the xless.yml and entitlements, which the
  check compared with the commit when git tracks them. What the app is stays the build's
  ([what the build decides](security.md#the-build-and-your-secrets)).
- This is for an `xless.yml` app. For a Tauri, Cargo or React Native app, `xless run --docker --config …` on the runner
  starts the build's container itself, in the kit's image, and the steps with the secrets in the xless image
  ([images.md](images.md#what-a-run-does), [what that does and does not keep apart](security.md#a-build-that-means-harm)).
- After an upgrade of xless, set `IMAGE` to the new image; the pack stays, unless the new xless prepares it in another
  way, and then `xless setup --docker --sdk <dir>` on the runner prepares it again.

[examples/example-ios-image.yml](examples/example-ios-image.yml) is the same as a whole workflow.

## An example

[examples/example-ios.yml](examples/example-ios.yml) is a GitHub Actions workflow, with the two steps, to copy into your app's
repository and adapt. It runs on a self-hosted Linux runner with xless set up natively.
[examples/example-ios-image.yml](examples/example-ios-image.yml) runs the two steps in containers of the xless image, with the
pack volume read-only ([above](#in-the-image)). Both are one job: for code you do not trust, use [two jobs](#in-two-jobs). Neither has been run as a workflow. The commands of the steps of
example-ios-image.yml, and those above with the app at the repository's top, were run by hand on a copy of
`samples/HelloShip` in a git repository (Docker on an arm64 Mac, with `GITHUB_WORKSPACE` set): the build, with the pack of
Xcode 26.2 and with that of Xcode 27.0, made the finalized app with `.git` read-only, and left nothing for the `git diff`
to report (what it writes, `.xless/` and the build's own directories, is not tracked); the signing, without the secrets,
stopped where it asks for `ASC_KEY_P8` (exit code 10).
