# The Apple account from the terminal

The commands grouped under **Apple account** in `xless --help` work on your Apple developer account and App Store
Connect: [`xless auth`](#xless-auth), which signs in to your Apple ID and shows which credentials are used,
[`xless team`](#xless-team), which picks the default team, [`xless secrets`](secrets.md), which keeps the keys, and
`xless api`, which calls any documented App Store Connect endpoint. More commands (devices, bundle IDs, certificates,
profiles, apps, TestFlight, releases) follow the conventions on this page.

They use the App Store Connect API key: `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (or their `_FILE` variables), else
the secret store's `ASC_KEY_P8` entry with its recorded IDs ([secrets.md](secrets.md#how-the-pipeline-finds-a-secret)).
Use a key with the narrowest role that does the job ([below](#errors)).

## Shared options

| Option | What it does |
|---|---|
| `--team <TEAM_ID>` | The team whose key is used: the store's `ASC_KEY_P8` entry recorded for that team (`ASC_KEY_P8@<TEAM_ID>`, or `--team-id` at import). Without it, the default team saved by [`xless team use`](#xless-team), else the only (or unteamed) entry. Keys from the environment are used as they are. |
| `--json` | Prints JSON instead of a table (see [JSON output](#json-output)). |
| `--yes` | Answers yes to the confirmation that every destructive call asks. Without a terminal, such a call is refused unless `--yes` is given; it never goes ahead silently. |
| `--verbose` | Shows every HTTP exchange with Apple on standard error. The trace never shows the key, the token, a cookie or a secret field: they read `<redacted>`. |

## The Apple ID web session

A few things have no documented App Store Connect API: creating the app record, App Store Connect API keys, auth keys
(APNs, Sign in with Apple), App Privacy, app groups and iCloud containers. The commands that do them use your Apple ID
instead, through the web interfaces Apple's own pages use (`appstoreconnect.apple.com/iris` and `/olympus`, and
`developer.apple.com/services-account`), and their `--help` says so. They are undocumented and may change; when one
fails, the error says which interface it was and which page to use in a browser meanwhile.

- The sign-in is Apple's own: SRP (the password itself is never sent) and the two-factor code, typed on the terminal
  (`/dev/tty`); never read from a pipe, a file, an argument or the environment. Accounts with security keys or the old
  two-step verification are not supported.
- The session's cookies stay in memory and are forgotten when the command ends. Nothing is written to disk, ever.
- **Opt-in cache:** `xless auth login --keep 30m` seals the cookies with a random key and keeps both in the Linux kernel
  keyring for that long (at most an hour, never past the session's own expiry). Later commands of the same login
  session use it without signing in; reading it needs that login session, as with `ssh-agent`. `xless auth logout`
  drops it, and the kernel drops it when the time is up. There is no cache on macOS or in containers that block the
  keyring (Docker's default).
- **Teams:** the developer portal knows a team by its team ID, App Store Connect by a provider number; xless matches
  them by name and asks when several App Store Connect teams share it.
- **Agreements:** xless never accepts legal terms. When Apple wants new terms accepted, the command stops and names the
  page: [App Store Connect > Business](https://appstoreconnect.apple.com/agreements) or
  [developer.apple.com/account](https://developer.apple.com/account), where the Account Holder accepts them.

## `xless auth`

```sh
xless auth login                  # sign in, list the teams; nothing is kept
xless auth login --keep 30m       # ... and keep the session for 30 minutes (Linux)
xless auth status                 # which credentials resolve, from where; the kept session's remaining life
xless auth logout                 # forget the kept session
```

`xless auth status` reads no secret and sends nothing: for `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` it says whether
each comes from the environment, a `_FILE` variable (and its path) or the secret store (and the entry), for which team,
and whether an Apple ID session is kept (for whom, until when). App Store Connect does not tell a key its own role, so
the role is shown as unknown unless xless recorded it. `--json` prints the same as a document.

## `xless team`

```sh
xless team list                   # team ID, name, type and App Store Connect provider (Apple ID web session)
xless team use ABCDE12345         # the default team for the account commands
xless team use --clear
```

The default team is saved as `team:` in `$XDG_CONFIG_HOME/xless/config.yml` (`~/.config/xless/config.yml` when
`XDG_CONFIG_HOME` is unset), a plain preference, not a secret. `--team` overrides it.

## JSON output

`--json` output is meant for scripts and stays stable: one JSON document on standard output, keys sorted, indented by
two spaces, `/` unescaped, followed by a newline. Resources keep App Store Connect's shape (`type`, `id`,
`attributes`, `relationships`), so a field Apple adds appears without breaking a reader. Messages, warnings and
`--verbose` traces go to standard error only.

## `xless api`

```sh
xless api GET /v1/apps --paginate
xless api GET /v1/apps -f 'filter[bundleId]=com.example.app' -f 'fields[apps]=name,sku' --include appInfos
xless api GET 'https://api.appstoreconnect.apple.com/v1/apps?cursor=…'      # a links.next, pasted
xless api PATCH /v1/apps/1234567890 --input body.json
xless api DELETE /v1/devices/ABC123 --yes
```

- The method is `GET`, `POST`, `PATCH` or `DELETE`. The path is a documented one (`/v1/…`, `/v2/…`), with or without a
  query, or a full `https://api.appstoreconnect.apple.com/…` URL. No other host is accepted, so the key is never sent
  anywhere else.
- `-f name=value` (`--field`, repeatable) adds a query parameter, for any method. `--include a,b` adds `include=a,b`.
- `--input <file>` (or `-` for standard input) is the JSON body of a `POST`, `PATCH` or `DELETE`.
- `--paginate` (`GET` only) follows `links.next` and prints one document: `{"data": [every item], "included": [each
  included resource once]}`. A listing that does not end after 1,000 pages is an error, never a cut list.
- A method other than `GET` asks for confirmation first (or needs `--yes`). A `POST` is sent once, never retried.
- The response's JSON is printed with sorted keys; an empty response (`204`) prints nothing.

## Rate limits

App Store Connect allows each key's user a number of requests per hour, and says how many are left in every response.
xless warns once, on standard error, when a tenth or less is left. A refused request (HTTP 429) is retried after the
wait Apple asks for (`Retry-After`) when that is at most a minute; when the hour's budget is spent, the command stops
and says how many minutes to wait.

## Errors

An account command that fails prints `[account] cause — fix` on standard error and exits with code **20**. The cause
names the request (`GET /v1/apps/123`) and Apple's error code, detail and the field it points at. A failure of the
Apple ID web session names the interface (App Store Connect's or the developer portal's), says it is undocumented and
gives the page to use meanwhile; a refused session (HTTP 401) asks to sign in again (`xless auth logout` first when a
session was kept). For the App Store Connect API, the fix depends on the status:

| Status | Fix |
|---|---|
| 401 | The key was revoked, `ASC_ISSUER_ID` is not its issuer, or the machine's clock is off. |
| 403 | The key's role is too narrow: the fix names the role the request needs (Admin for users and certificates, identifiers, devices and profiles; Finance or Sales for their reports; App Manager for the app's own resources). |
| 404 | No such resource: check the ID, and that it belongs to the key's team. |
| 409 | A conflict: the fix names the field Apple refused (`name`, `identifier`, …). |
| 429 | The hour's request budget is spent: the fix says how long to wait. |

A usage mistake (an unknown method, a path on another host) exits 64 before anything is sent.
