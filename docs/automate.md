# Automate: scripts, several apps, listings

For runs that nobody answers: scripts, several apps at once, checks. [CI](ci.md) is the same with the keys in variables.
The commands here need the App Store Connect API key only, unless a line says *web session*. The scripts are for `sh`, with
[jq](https://jqlang.org/) for the JSON.

## Run without questions

| What | What it does |
|---|---|
| `xless session -- ./script.sh` | Asks the store's passphrase once, before the script starts, and drops it when the script ends ([one unlock for a script](secrets.md#one-unlock-for-a-script)). `--sign-in`: the Apple ID too, once. Not on Windows. |
| `xless unlock --for 2h` | Keeps the store unlocked for the commands of this terminal ([staying unlocked](secrets.md#staying-unlocked)). Not on Windows. |
| `--no-input`, or `XLESS_NO_INPUT=1` | Instead of asking for a passphrase, a sign-in, a choice or a confirmation, a command fails at once, with exit code 23. Every command takes it. |
| `--yes` | Answers yes to the confirmation that every destructive call asks. Without a terminal such a call is refused unless `--yes` is given. |
| `--json` | One JSON document on standard output, of a stable shape; messages go to standard error ([JSON output](apple-account.md#json-output)). |

```sh
xless session -- ./nightly.sh
```

Keep tools that run other people's code (`npm install`, `make`) out of such a script: they could run xless
([who else has it](secrets.md#one-unlock-for-a-script)). To start only when all is there, check `xless auth status --json` first
([how](apple-account.md#xless-auth)).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Done (`release submit`: submitted, or a dry run that passed) |
| 2 | `xless run`: a usage or configuration error of the run itself |
| 10 | A configuration error: `xless.yml`, an overlay |
| 11–19 | The SDK or a stage of a build ([pipeline.md](pipeline.md#stages)) |
| 20 | An account command failed ([errors](apple-account.md#errors)), or `store validate` found something |
| 21, 22 | `release submit`: the pre-flight failed, or the version is in review already. Nothing was sent |
| 23 | `--no-input`: something would have been asked |
| 24 | `sign` with `--no-provisioning-updates`: the account lacks something |
| 64 | A usage mistake: an unknown option or value |

## Several apps

A command finds its app and team in the project: `xless.yml`, or the overlay that `--config` names. So one script goes over all of
them, a directory or an overlay each:

```sh
mkdir -p plans
for app in apps/*/; do
  xless provision plan --project "$app" --json > "plans/$(basename "$app").json" || echo "failed: $app" >&2
done
```

```sh
for overlay in overlays/*.yml; do
  xless provision plan --config "$overlay" --json > "plans/$(basename "$overlay" .yml).json" || echo "failed: $overlay" >&2
done
```

`provision apply --yes --json` in the same loop makes what is missing. It prints what was done, the step that failed and what is
left as one document, even when it fails (exit 20), and running it again does only what is left
([`xless provision`](apple-account.md#xless-provision)). New app records, APNs keys, app groups, iCloud containers and App Privacy
need the web session: run that loop in `xless session --sign-in -- …`.

- **Several teams:** each project's `teamID` picks the key stored for that team; `--team <TEAM_ID>` does, for a command without a
  project ([shared options](apple-account.md#shared-options)).
- **The apps of a team:** `xless apps list --json`.
- **A list of identifiers** (a capability for twenty bundle IDs) is a loop over the one command, or
  [`xless api`](apple-account.md#xless-api) for an endpoint that has none:

  ```sh
  xless api GET /v1/apps --paginate | jq -r '.data[].attributes.bundleId'
  ```

## Check a configuration

None of these changes anything on the account:

| What | Command |
|---|---|
| The listing's files, offline | `xless store validate --json` (`--draft`: what is still missing is a warning) |
| What App Store Connect has that differs | `xless store push --dry-run --json` |
| The account against the project | `xless provision plan --json` |
| A version, before App Review | `xless release submit --dry-run --json` |
| What an overlay's build would do | `xless inspect --config <overlay.yml>` |
| Which credentials are there, what is held | `xless auth status --json` |

To fail a job when an account has drifted from its project:

```sh
xless provision plan --json --no-input | jq -e '.steps == [] and .drift == [] and .blockers == []' > /dev/null
```

Planning never signs in. Without a kept web session, the steps that only it can see are listed as "checked when applied"
(`"checked": false`), so let a job that has none look at the others:

```sh
xless provision plan --json --no-input | jq -e '[.steps[] | select(.checked)] == [] and .blockers == []' > /dev/null
```

## Pulling and pushing listings

`appstore/` beside `xless.yml` (or the overlay) is the listing, as files you can review like code
([appstore-manifest.md](appstore-manifest.md)):

```sh
xless store pull --app com.example.app                    # App Store Connect's listing, into ./appstore
xless store pull --app com.example.app --dir listings/example --live    # the version on the App Store, elsewhere
xless store push --dry-run                                # what would change
xless store push --yes                                    # sends what differs; --yes also answers for what it deletes
xless store push --only text,media                        # some parts only
xless store push --prune --yes                            # also deletes the locales, sets and files that the directory lacks
```

`pull` replaces the directory's text and media by App Store Connect's, so pull into a clean working tree. To pull every app of
the team, each into a directory of its own:

```sh
xless apps list --json | jq -r '.data[].attributes.bundleId' | while read -r id; do
  xless store pull --app "$id" --dir "listings/$id" < /dev/null
done
```

App Privacy is *web session*: `xless store privacy pull` and `push`; a `store push` without a session skips that part, with a note.

## The same in CI

[ci.md](ci.md).
