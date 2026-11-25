# CI

A job never opens the secret store: it gets its keys from variables. Make the keys on your own machine, with
[`xless provision`](get-started.md#i-have-nothing-yet) or by hand, and give the job those it needs.

## The secrets

Which variable is needed for what, and the `_FILE` form of each: [signing-and-testflight.md](signing-and-testflight.md#secrets).
An iOS build that goes to TestFlight needs `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` and `XLESS_DIST_KEY`; the account commands
need the three `ASC_` ones. Export each key once, put its contents into the CI's secret store under the variable's name, and
delete the file:

```sh
xless secrets list                                            # the entry names, the key's ID and issuer ID
xless secrets export ASC_KEY_P8@ABCDE12345 --out key.p8       # → ASC_KEY_P8 (with ASC_KEY_ID and ASC_ISSUER_ID from `secrets list`)
xless secrets export XLESS_DIST_KEY@ABCDE12345 --out dist.pem # → XLESS_DIST_KEY
rm key.p8 dist.pem
```

Once an app exists, a release runs on the API key alone. Only new apps, new keys and App Privacy answers need the Apple ID
([why](security.md#the-apple-id-web-session)); do those from a terminal. A key made for CI alone, with the role it needs, can be
revoked alone ([`xless auth api-key`](apple-account.md#xless-auth-api-key)).

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
  empty, and there is no image to give them: one holds Apple's SDK, so it is never pushed to a registry.
- **A build on a Mac** needs the runner's Xcode ([native-install.md](native-install.md#on-a-mac)).

**Never let pull requests of others run on a runner of your own, or in a job that has these secrets.** A build runs the project's
code: [what that code can reach](security.md#the-build-and-your-secrets). To keep the secrets out of the build, run it in two
steps, and give them to the second alone:

```sh
export XLESS_BUILD_NUMBER=$(( $(date +%s) / 60 ))
xless run . --to finalize     # no secret
xless run . --from sign       # with the variables
```

## An example

[examples/example-ios.yml](examples/example-ios.yml) is a GitHub Actions workflow to copy into your app's repository
and adapt. It runs on a self-hosted Linux runner and ships with `xless ship`. It has not been run yet.
