# The Apple account from the terminal

The commands grouped under **Apple account** in `xless --help` work on your Apple developer account and App Store
Connect: [`xless secrets`](secrets.md), which keeps the keys, and `xless api`, which calls any documented App Store
Connect endpoint. More commands (devices, bundle IDs, certificates, profiles, apps, TestFlight, releases) follow the
conventions on this page.

They use the App Store Connect API key: `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (or their `_FILE` variables), else
the secret store's `ASC_KEY_P8` entry with its recorded IDs ([secrets.md](secrets.md#how-the-pipeline-finds-a-secret)).
Use a key with the narrowest role that does the job ([below](#errors)).

## Shared options

| Option | What it does |
|---|---|
| `--team <TEAM_ID>` | The team whose key is used: the store's `ASC_KEY_P8` entry recorded for that team (`ASC_KEY_P8@<TEAM_ID>`, or `--team-id` at import). Without it, the only (or unteamed) entry. Keys from the environment are used as they are. |
| `--json` | Prints JSON instead of a table (see [JSON output](#json-output)). |
| `--yes` | Answers yes to the confirmation that every destructive call asks. Without a terminal, such a call is refused unless `--yes` is given; it never goes ahead silently. |
| `--verbose` | Shows every HTTP exchange with Apple on standard error. The trace never shows the key, the token, a cookie or a secret field: they read `<redacted>`. |

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
names the request (`GET /v1/apps/123`) and Apple's error code, detail and the field it points at. The fix depends on
the status:

| Status | Fix |
|---|---|
| 401 | The key was revoked, `ASC_ISSUER_ID` is not its issuer, or the machine's clock is off. |
| 403 | The key's role is too narrow: the fix names the role the request needs (Admin for users and certificates, identifiers, devices and profiles; Finance or Sales for their reports; App Manager for the app's own resources). |
| 404 | No such resource: check the ID, and that it belongs to the key's team. |
| 409 | A conflict: the fix names the field Apple refused (`name`, `identifier`, …). |
| 429 | The hour's request budget is spent: the fix says how long to wait. |

A usage mistake (an unknown method, a path on another host) exits 64 before anything is sent.
