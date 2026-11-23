# The Apple account from the terminal

The commands grouped under **Apple account** in `xless --help` work on your Apple developer account and App Store
Connect: [`xless auth`](#xless-auth), which signs in to your Apple ID and shows which credentials are used,
[`xless auth api-key`](#xless-auth-api-key), which creates and revokes App Store Connect API keys,
[`xless team`](#xless-team), which picks the default team, [`xless secrets`](secrets.md), which keeps the keys,
[`xless devices`](#xless-devices), which registers the devices of development and ad hoc profiles,
[`xless bundle-ids`](#xless-bundle-ids), which registers bundle IDs and enables their capabilities,
[`xless merchant-ids`](#xless-merchant-ids), which registers Apple Pay merchant IDs,
[`xless certs`](#xless-certs), which creates, downloads and revokes certificates of every type with their private keys
in the secret store, [`xless profiles`](#xless-profiles), which creates, downloads, renews and deletes provisioning
profiles of every type, [`xless app-groups` and `xless icloud-containers`](#xless-app-groups-and-xless-icloud-containers),
which register app groups and iCloud containers and assign them to bundle IDs, [`xless keys`](#xless-keys), which
creates and revokes APNs, Sign in with Apple, DeviceCheck and MusicKit keys with their `.p8` in the secret store,
[`xless apps`](#xless-apps), which lists, shows, updates and creates app records, [`xless store`](#xless-store), which
keeps the App Store listing in an `appstore/` directory, [`xless builds`](#xless-builds), which lists uploaded builds,
waits for their processing, answers their export compliance and expires them, [`xless users`](#xless-users), which
invites, updates and removes the team's App Store Connect users, [`xless testflight`](#xless-testflight), which
manages TestFlight groups and testers, delivers builds and runs external testing, [`xless release`](#xless-release),
which submits a version for review and releases it, and [`xless api`](#xless-api), which calls any documented App Store
Connect endpoint.

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
the role is shown as unknown unless xless recorded it ([`xless auth api-key`](#xless-auth-api-key)). `--json` prints the same as a document.

## `xless auth api-key`

```sh
xless auth api-key create                         # an APP_MANAGER key for all apps, straight into the secret store
xless auth api-key create --role ADMIN --name ci  # another role (repeatable), another name
xless auth api-key create --app 1234567890        # a key that sees only that app (repeatable)
xless auth api-key import --p8-file AuthKey_2X9R4HXF34.p8 --issuer-id 69a6de7e-...
xless auth api-key list                           # the team's keys; * marks the one xless uses
xless auth api-key revoke 2X9R4HXF34              # asks first (--yes without a terminal)
```

The first API key is the one thing an API key cannot create, so `create`, `list` and `revoke` use the
[Apple ID web session](#the-apple-id-web-session) (App Store Connect's `/iris/v1/apiKeys`). Creating a team key needs an
Apple ID that is the Account Holder, or an Admin the Account Holder allowed to generate keys; a 403 says so. The
Account Holder may first have to request API access once, at App Store Connect > Users and Access > Integrations.

`create`, in one process and one sign-in:

1. checks the secret store before anything else: it must exist ([`xless secrets init`](secrets.md)), it is unlocked
   (the passphrase is asked first), and it must not already hold an `ASC_KEY_P8` for the team (revoke or remove that
   one first);
2. creates the key (`--role`, default `APP_MANAGER`; `--name`, default `xless <date>`; all apps unless `--app`) and
   downloads its private key **once**: Apple offers it a single time, so the download is never retried;
3. seals it into the store as `ASC_KEY_P8@<TEAM_ID>` with its key ID, issuer ID, team and role (never on disk in
   clear);
4. checks it with one documented call (`GET /v1/apps?limit=1`; a brand-new key can be refused for a few seconds, so a
   401 is retried a few times) before reporting success.

If anything fails once the key exists (the download, the store, a body xless cannot read), the error says that key
`<KEY_ID>` exists, that xless does not have its private key and that it cannot be downloaded again: revoke it with
`xless auth api-key revoke <KEY_ID>`.

Pick the narrowest role that covers what you plan: `APP_MANAGER` works for apps, the listing, TestFlight, builds,
certificates and profiles; users and invitations need `ADMIN`; `DEVELOPER` cannot create certificates; `FINANCE`,
`SALES` and `ACCESS_TO_REPORTS` read reports. App Store Connect never tells a key its own role, so xless records the
role of the keys it creates (and of imported keys given `--role`), and `xless auth status` shows it.

`import` needs no Apple ID: it reads the `.p8` once, checks that it is a P-256 private key and that App Store Connect
accepts it (`GET /v1/apps`), stores it as `ASC_KEY_P8@<TEAM_ID>` (with `--team` or the saved team) or `ASC_KEY_P8`,
then offers to delete the file. A key that does not work is not stored. `--key-id` defaults to the one in an
`AuthKey_<KEY_ID>.p8` file name.

`revoke` asks before it revokes (Apple cannot undo it; everything using the key stops working), then removes the
store's entries for that key ID. A key that is already revoked only has its entries removed.

Individual keys (each person's own key, App Store Connect's `/iris/v2/apiKeys`, with a key pair made on the client)
and in-app purchase keys are not supported.

## `xless team`

```sh
xless team list                   # team ID, name, type and App Store Connect provider (Apple ID web session)
xless team use ABCDE12345         # the default team for the account commands
xless team use --clear
```

The default team is saved as `team:` in `$XDG_CONFIG_HOME/xless/config.yml` (`~/.config/xless/config.yml` when
`XDG_CONFIG_HOME` is unset), a plain preference, not a secret. `--team` overrides it.

## `xless devices`

```sh
xless devices list                                    # ID, name, UDID, platform, kind, model, status, date added
xless devices list --platform ios --status enabled
xless devices register "Fred's iPhone" 00008030-001A35E80C42802E
xless devices register "Build Mac" 00008103-001234567890001E --platform macos   # an Apple-silicon Mac
xless devices import devices.txt                      # Apple's device file; asks first (--yes without a terminal)
xless devices rename 8U3T4X5YZA "Work iPhone"
xless devices disable 00008030-001A35E80C42802E       # asks first; `enable` undoes it
```

They use the API key (`/v1/devices`), which needs the Admin role. A device is named by its ID (from `list`) or its
UDID. Apple never deletes a device: `disable` takes it out of new profiles, `enable` puts it back.

- **UDIDs are checked before anything is sent:** 40 hex digits (older iPhones and iPads) or 8 and 16 hex digits joined
  by a dash (`00008030-001A35E80C42802E`: newer iPhones and iPads, and Apple-silicon Macs) for `ios`; a Mac's hardware
  UUID (`12345678-1234-1234-1234-123456789ABC`) for `macos`. Without `--platform`, a hardware UUID is a Mac and the
  other forms are iOS devices, so an Apple-silicon Mac's provisioning UDID needs `--platform macos`.
- **Registering twice registers once:** a UDID that is already registered (in any case) is reported with its ID, name
  and status, and nothing is sent; a disabled one is not re-enabled (`enable` does that).
- **`import`** reads the developer portal's device file: one device per line, tab-separated `Device ID`, `Device Name`
  and optionally `Device Platform` (`ios` or `mac`), with or without that header line; blank lines and `#` comments are
  skipped. Every line is checked first, and a bad line or a UDID listed twice stops the import before anything is sent.
  Devices already registered are skipped; the new ones are listed and registered after a confirmation. A failure
  stops the import and names the devices registered before it, so re-running the import finishes the job.
- **The yearly limit:** Apple allows 100 devices of each kind (iPhone, iPad, iPod touch, Apple Watch, Apple TV, Apple
  Vision Pro, Mac) per membership year. A disabled device keeps its slot; when the membership renews, the Account
  Holder can remove devices on [developer.apple.com](https://developer.apple.com/account/resources/devices/list) to
  reset the count. `list` (without `--status`), `register` and `import` warn on standard error when a kind has 90 or
  more devices, and Apple's refusal once the limit is reached is reported with that rule.

With `--json`, `list` prints `{"data": [devices]}`, `register` and `import` print `{"registered": [devices],
"existing": [devices]}`, and `enable`, `disable` and `rename` print the device; each device is App Store Connect's
resource (`type`, `id`, `attributes`, …).

## `xless bundle-ids`

```sh
xless bundle-ids list --platform ios                  # ID, identifier, name, platform, seed ID
xless bundle-ids show com.example.app                 # the bundle ID and its capabilities, with their settings
xless bundle-ids create com.example.app --name "Example App" --platform universal
xless bundle-ids delete com.example.app               # asks first: profiles that use it become invalid
xless bundle-ids capabilities com.example.app list
xless bundle-ids capabilities com.example.app enable ICLOUD --setting ICLOUD_VERSION=XCODE_6
xless bundle-ids capabilities com.example.app enable APPLE_ID_AUTH
xless bundle-ids capabilities com.example.app disable GAME_CENTER   # asks first
```

They use the API key (`/v1/bundleIds`, `/v1/bundleIdCapabilities`), which needs the Admin role. A bundle ID is named by
its ID (from `list`) or its identifier. The [`sign` stage](signing-and-testflight.md) registers its own bundle IDs and
enables the capabilities their entitlements need ([below](#what-sign-enables)); these commands are for the rest.

- **`create`** takes a reverse-DNS identifier (`com.example.app`) or a wildcard (`com.example.*`), checked before anything
  is sent. The name defaults to the identifier's words (`com example app`); Apple accepts only ASCII letters, digits and
  spaces in it. The platform defaults to `universal` (iOS and macOS), as `sign` registers. An identifier the team has
  already is reported with its ID, and nothing is sent.
- **Capabilities** are named as the API names them, in any case (`icloud`, `push-notifications`): `ICLOUD`,
  `IN_APP_PURCHASE`, `GAME_CENTER`, `PUSH_NOTIFICATIONS`, `WALLET`, `INTER_APP_AUDIO`, `MAPS`, `ASSOCIATED_DOMAINS`,
  `PERSONAL_VPN`, `APP_GROUPS`, `HEALTHKIT`, `HOMEKIT`, `WIRELESS_ACCESSORY_CONFIGURATION`, `APPLE_PAY`, `DATA_PROTECTION`,
  `SIRIKIT`, `NETWORK_EXTENSIONS`, `MULTIPATH`, `HOT_SPOT`, `NFC_TAG_READING`, `CLASSKIT`, `AUTOFILL_CREDENTIAL_PROVIDER`,
  `ACCESS_WIFI_INFORMATION`, `NETWORK_CUSTOM_PROTOCOL`, `COREMEDIA_HLS_LOW_LATENCY`, `SYSTEM_EXTENSION_INSTALL`,
  `USER_MANAGEMENT` and `APPLE_ID_AUTH` (Sign in with Apple). Other portal capabilities (App Attest, Declared Age Range,
  Family Controls, …) are not in the API: enable them on
  [developer.apple.com](https://developer.apple.com/account/resources/identifiers).
- **Settings:** three capabilities take one, given as `--setting KEY=OPTION`; without it, a capability being enabled
  gets the default and one enabled already keeps its own.

  | Capability | Setting | Options (default first) |
  |---|---|---|
  | `ICLOUD` | `ICLOUD_VERSION` | `XCODE_6` (CloudKit), `XCODE_5` |
  | `DATA_PROTECTION` | `DATA_PROTECTION_PERMISSION_LEVEL` | `COMPLETE_PROTECTION`, `PROTECTED_UNLESS_OPEN`, `PROTECTED_UNTIL_FIRST_USER_AUTH` |
  | `APPLE_ID_AUTH` | `APPLE_ID_AUTH_APP_CONSENT` | `PRIMARY_APP_CONSENT` |

- **`enable`** on a capability that is enabled already sends nothing, or changes its setting when `--setting` names
  another option. **`disable`** asks first and sends nothing when the capability is not enabled.
- **Linked identifiers:** App Groups, iCloud and Apple Pay are enabled here, but the app group, iCloud container or
  merchant ID they use must still be assigned to the bundle ID, which the API cannot do: with
  [`xless app-groups assign` / `xless icloud-containers assign`](#xless-app-groups-and-xless-icloud-containers), and for
  a merchant ID on [developer.apple.com](https://developer.apple.com/account/resources/identifiers). `enable` says so.
- **Profiles:** a provisioning profile keeps the entitlements it was made with. After a change, regenerate the
  profiles that use the bundle ID; `sign` regenerates its own.

With `--json`, `list` prints `{"data": [bundle IDs]}`, `show` prints `{"data": bundle ID, "capabilities": [...]}`,
`create` prints `{"registered": [...], "existing": [...]}`, `delete` prints `{"deleted": bundle ID}`, `capabilities list`
prints `{"data": [capabilities]}`, `enable` prints the capability and `disable` prints `{"disabled": [capability]}`
(empty when it was not enabled); each is App Store Connect's resource.

### What `sign` enables

`sign` enables, on each bundle's identifier, the capability of every entitlement key that has one, with the setting
the entitlements imply: iCloud with CloudKit (`XCODE_6`), Sign in with Apple as its own primary app, and Data Protection
at the level `com.apple.developer.default-data-protection` names (`NSFileProtectionComplete…`; Complete otherwise). A
capability enabled already is left as it is. On macOS, the profile's push environment
(`com.apple.developer.aps-environment`) replaces the entitlements file's, as on iOS.

| Capability | iOS keys | macOS keys |
|---|---|---|
| `PUSH_NOTIFICATIONS` | `aps-environment` | `com.apple.developer.aps-environment` |
| `ICLOUD` | `com.apple.developer.icloud-container-identifiers`, `…icloud-container-development-container-identifiers`, `…icloud-container-environment`, `…icloud-services`, `…ubiquity-container-identifiers`, `…ubiquity-kvstore-identifier` | the same |
| `APPLE_ID_AUTH` | `com.apple.developer.applesignin` | the same |
| `APP_GROUPS` | `com.apple.security.application-groups` | the same |
| `ASSOCIATED_DOMAINS` | `com.apple.developer.associated-domains` | the same |
| `AUTOFILL_CREDENTIAL_PROVIDER` | `com.apple.developer.authentication-services.autofill-credential-provider` | the same |
| `APPLE_PAY` | `com.apple.developer.in-app-payments` | the same |
| `GAME_CENTER` | `com.apple.developer.game-center` | the same |
| `WALLET` | `com.apple.developer.pass-type-identifiers` | the same |
| `PERSONAL_VPN` | `com.apple.developer.networking.vpn.api` | the same |
| `HOMEKIT` | `com.apple.developer.homekit` | the same |
| `SIRIKIT` | `com.apple.developer.siri` | the same |
| `NETWORK_EXTENSIONS` | `com.apple.developer.networking.networkextension` | the same |
| `COREMEDIA_HLS_LOW_LATENCY` | `com.apple.developer.coremedia.hls.low-latency` | the same |
| `HEALTHKIT` | `com.apple.developer.healthkit`, `…healthkit.access`, `…healthkit.background-delivery` | |
| `DATA_PROTECTION` | `com.apple.developer.default-data-protection` | |
| `INTER_APP_AUDIO` | `inter-app-audio` | |
| `WIRELESS_ACCESSORY_CONFIGURATION` | `com.apple.external-accessory.wireless-configuration` | |
| `MULTIPATH` | `com.apple.developer.networking.multipath` | |
| `HOT_SPOT` | `com.apple.developer.networking.HotspotConfiguration` | |
| `NFC_TAG_READING` | `com.apple.developer.nfc.readersession.formats` | |
| `CLASSKIT` | `com.apple.developer.ClassKit-environment` | |
| `ACCESS_WIFI_INFORMATION` | `com.apple.developer.networking.wifi-info` | |
| `NETWORK_CUSTOM_PROTOCOL` | `com.apple.developer.networking.custom-protocol` | |
| `USER_MANAGEMENT` | `com.apple.developer.user-management` | |
| `MAPS` | | `com.apple.developer.maps` |
| `SYSTEM_EXTENSION_INSTALL` | | `com.apple.developer.system-extension.install` |

`IN_APP_PURCHASE` has no entitlement: enable it with `capabilities … enable`. A gated key with no API type (App Attest,
Declared Age Range, the increased memory limit, …) is left to the portal: `sign` regenerates the profile once in case
it was enabled by hand, then stops and names the capability to enable. When a key whose capability xless enabled is
still missing from the profile, `sign` stops with the `xless bundle-ids capabilities` command that shows it. iCloud
containers (`…icloud-container-identifiers`, `…ubiquity-container-identifiers`), app groups
(`com.apple.security.application-groups`) and merchant IDs (`com.apple.developer.in-app-payments`) must also be
assigned to the bundle ID, which the API cannot do: an identifier the profile does not list stops `sign` with the
commands that create and assign it ([`xless icloud-containers` and `xless app-groups`](#xless-app-groups-and-xless-icloud-containers),
which use the Apple ID web session; `sign` itself never signs in) or, for a merchant ID, `xless merchant-ids create`
and the portal step. A capability Apple refuses to enable (one that needs
its approval, or does not apply to the platform) stops `sign` with Apple's answer.

## `xless merchant-ids`

```sh
xless merchant-ids list                               # ID, identifier, name
xless merchant-ids create merchant.com.example.store --name "Example Store"
xless merchant-ids delete merchant.com.example.store  # asks first
```

They use the API key (`/v1/merchantIds`), which needs the Admin role. A merchant ID is named by its ID or its
identifier, which starts with `merchant.`; `--name` takes ASCII letters, digits and spaces. Registering an identifier
the team has already sends nothing. An app takes Apple Pay payments to a merchant ID through the `APPLE_PAY` capability
of its bundle ID; assigning the merchant ID to the bundle ID is not in the API, so it is done on
[developer.apple.com](https://developer.apple.com/account/resources/identifiers). With `--json`, `list` prints
`{"data": [merchant IDs]}`, `create` `{"registered": [...], "existing": [...]}` and `delete` `{"deleted": merchant ID}`.

## `xless certs`

```sh
xless certs list [--type distribution]… [--expiring 30]     # ID, type, name, serial, expiry, key in the store
xless certs create --type distribution                        # key into the secret store, then the certificate
xless certs create --type developer-id --csr devid.csr        # a key that lives elsewhere: only the CSR is sent
xless certs create --type apple-pay-merchant-identity --merchant-id merchant.com.example.store
xless certs create --type pass-type-id --pass-type-id pass.com.example.ticket
xless certs show 8U3T4X5YZA
xless certs download 8U3T4X5YZA --out distribution.cer        # DER, mode 0644, never overwrites
xless certs revoke 8U3T4X5YZA                                 # asks first, naming the profiles that stop working
```

They use the API key (`/v1/certificates`); creating and revoking need the Admin role, and Developer ID certificates the
Account Holder. `--type` takes the 18 `CertificateType` values of App Store Connect API 4.6.1 (`DISTRIBUTION`,
`DEVELOPMENT`, `IOS_DEVELOPMENT`, `IOS_DISTRIBUTION`, `MAC_APP_DEVELOPMENT`, `MAC_APP_DISTRIBUTION`,
`MAC_INSTALLER_DISTRIBUTION`, `DEVELOPER_ID_APPLICATION(_G2)`, `DEVELOPER_ID_KEXT(_G2)`, `APPLE_PAY`,
`APPLE_PAY_MERCHANT_IDENTITY`, `APPLE_PAY_PSP_IDENTITY`, `APPLE_PAY_RSA`, `PASS_TYPE_ID(_WITH_NFC)`, `IDENTITY_ACCESS`)
in any case, with dashes or underscores; `developer-id` and `installer` stand for `DEVELOPER_ID_APPLICATION_G2` and
`MAC_INSTALLER_DISTRIBUTION` (`list --type developer-id` shows both Developer ID Application generations). Developer
ID Installer certificates are not in the API: create them on
[developer.apple.com](https://developer.apple.com/account/resources/certificates).

`create` without `--csr` generates an RSA-2048 key, keeps it in memory only, and seals it into the
[secret store](secrets.md) **before** the create request: a store that cannot keep it (no store, a wrong passphrase, a
taken name) means nothing is sent. The entry is `XLESS_DIST_KEY`, `XLESS_DEVID_KEY` or `XLESS_INSTALLER_KEY` for the
three certificates `sign` uses, `XLESS_<TYPE>_KEY` otherwise, with `@<TEAM_ID>` when a team is selected; `--name`
chooses another. xless refuses up front when the store already has a key the `sign` stage would read for that team
(also for a `--name` such as `XLESS_DIST_KEY@<TEAM_ID>`). The
create request is sent once, never retried. A definite refusal (a 4xx other than 429) removes the key again; any other
failure may have created the certificate, so the key is kept and the error says to check `xless certs list`. Once the
certificate exists, its ID, type and expiry (and the team, read from the certificate when none was selected) are
recorded with the key. `sign` finds the key through the store and matches it to its certificate by public key.

`create --csr <file>` (PEM or DER) is for keys that live elsewhere (an HSM, another machine): xless checks the CSR and
sends it, and nothing secret touches it. Apple Pay payment processing (`apple-pay`) needs an ECC P-256 key, usually made
by the payment provider, so it always takes `--csr`. Apple Pay certificates need `--merchant-id` (an identifier or
ID, see [`xless merchant-ids`](#xless-merchant-ids)), Wallet pass certificates `--pass-type-id` (an identifier
`pass.…` or ID).

Limits: Apple allows five Developer ID Application certificates per team ([Create Developer ID
certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/), read
2026-11-23), which `create` checks before generating anything. Apple's [certificates
overview](https://developer.apple.com/help/account/certificates/certificates-overview/) gives no number for the other
types; App Store Connect refuses one too many itself (HTTP 409), and the error points to `xless certs revoke`.

`revoke` lists the profiles that contain the certificate (they become invalid), warns that apps signed with a
Developer ID certificate can no longer be installed, and asks (or needs `--yes`). It leaves the store entry holding the
private key in place and names it (`xless secrets rm <name>`). `xless sign bootstrap --type
distribution|developer-id|installer` is `create` for the three certificates `sign` uses, with its own `--allow-new`
check ([bootstrap.md](bootstrap.md#how-sign-bootstrap-behaves)); `--out <file>` keeps its file behaviour.

With `--json`, `list` prints `{"data": [certificates]}`, `show` the certificate, `create`
`{"certificate": certificate, "entry": store entry or absent, "team": team ID or absent}` and `revoke`
`{"revoked", "certificateType", "profiles", "storeEntries"}`.

## `xless profiles`

```sh
xless profiles list [--type ios-app-adhoc]… [--bundle-id com.example.app] [--expiring 30]   # ID, name, type, bundle ID, state, expiry
xless profiles create --type ios-app-development --bundle-id com.example.app             # every fitting certificate, every enabled iPhone/iPad/…
xless profiles create --type ios-app-adhoc --bundle-id com.example.app --cert-type distribution \
                      --devices 00008030-001A35E80C42802E,8U3T4X5YZB --name "Example Ad Hoc"
xless profiles create --type mac-app-direct --bundle-id com.example.mac --cert 8U3T4X5YZA
xless profiles download 8U3T4X5YZA --out Example.mobileprovision                         # checked first; mode 0644, never overwrites
xless profiles renew 8U3T4X5YZA                                                          # asks first: delete, then create again
xless profiles delete 8U3T4X5YZA                                                         # asks first
```

They use the API key (`/v1/profiles`); creating, renewing and deleting need the Admin role. `--type` takes the 14
`ProfileType` values of App Store Connect API 4.6.1 in any case, with dashes or underscores: `IOS_APP_DEVELOPMENT`,
`IOS_APP_STORE`, `IOS_APP_ADHOC`, `IOS_APP_INHOUSE`, `MAC_APP_DEVELOPMENT`, `MAC_APP_STORE`, `MAC_APP_DIRECT`
(Developer ID), `TVOS_APP_DEVELOPMENT`, `TVOS_APP_STORE`, `TVOS_APP_ADHOC`, `TVOS_APP_INHOUSE`,
`MAC_CATALYST_APP_DEVELOPMENT`, `MAC_CATALYST_APP_STORE` and `MAC_CATALYST_APP_DIRECT`. In-house profiles exist only
in the Apple Developer Enterprise Program. `--bundle-id` takes an identifier or an ID
([`xless bundle-ids`](#xless-bundle-ids)); a macOS profile needs a macOS or universal bundle ID, the others an iOS or
universal one.

`create` checks everything before it sends its single request:

- **Certificates:** `--cert <id>` (repeatable) names them; `--cert-type <type>` (repeatable) takes every unexpired
  certificate of that type. Without either, every unexpired certificate of the types that fit: Apple Development plus
  iOS App Development (or Mac Development) for development profiles, Apple Distribution plus iOS Distribution (or Mac
  App Distribution) for App Store, ad hoc and in-house ones, Developer ID Application for `MAC_APP_DIRECT` and
  `MAC_CATALYST_APP_DIRECT`. A certificate of another type, or an expired one, is refused.
- **Devices** (development and ad hoc profiles only; `--devices` on another type is refused): `--devices all`, the
  default, takes every enabled device of the profile's kind: Apple TVs for tvOS, the other iOS-platform devices for iOS,
  Macs for macOS and Mac Catalyst. `--devices <udid,…>` takes UDIDs or device IDs, each registered
  ([`xless devices`](#xless-devices)), enabled and of that kind.
- **Name:** `xless <identifier> <TYPE>` unless `--name` says otherwise, which is the name `xless sign` gives the profiles
  it makes. A profile of that name must not exist yet (names stay unique, so `sign` and `renew` find the right one):
  renew it instead.

`download` reads the profile, checks that it is a CMS envelope around a property list, that its `TeamIdentifier` is
the team (`--team` or the default team, else the bundle ID's App ID prefix, which is the team ID on all but some
older teams), that its `application-identifier` is
`<App ID prefix>.<identifier>` and that its UUID is the one App Store Connect lists, and only then writes it, with
mode 0644, to a file that must not exist yet. The signature is not checked: the file comes from App Store Connect over
TLS, and devices check it.

A profile cannot be edited. `renew` reads its name, type, bundle ID, certificates and (development, ad hoc) devices,
asks, deletes it and creates it again with them, so it gets a new expiry and every capability now enabled on the
bundle ID. Before anything is deleted, it leaves out (and names, on standard error) the certificates that expired or
were revoked and the devices that were disabled; when no certificate (or, for development and ad hoc profiles, no
device) is left, nothing is sent and the error says to `create` a new profile. If the create fails after the delete,
the error gives the exact `xless profiles create` command that makes it again. `delete` asks first; Apple has no undo.

`xless sign` keeps making and replacing its own `xless <identifier> <TYPE>` profiles (`IOS_APP_STORE`,
`MAC_APP_STORE`, `MAC_APP_DIRECT`) through the same create path.

With `--json`, `list` prints `{"data": [profiles]}` (without `profileContent`; each profile's `relationships.bundleId`
names its bundle ID), `create` and `renew` `{"profile": profile, "bundleId": identifier, "certificates": [IDs],
"devices": [IDs]}` (plus `"replaced": old ID` for `renew`), and `delete` `{"deleted", "name", "profileType"}`.

## `xless app-groups` and `xless icloud-containers`

```sh
xless app-groups list                                           # ID, identifier, name
xless app-groups create group.com.example.shared                # --name "Shared" (default: the identifier's words)
xless app-groups assign com.example.app group.com.example.shared
xless app-groups assign com.example.app.widget group.com.example.shared
xless app-groups unassign com.example.app group.com.example.shared   # asks first
xless icloud-containers list                                    # visible and hidden ones
xless icloud-containers create iCloud.com.example.app
xless icloud-containers assign com.example.app iCloud.com.example.app
xless icloud-containers unassign com.example.app iCloud.com.example.app
```

The App Store Connect API can neither create nor assign app groups and iCloud containers, so these commands use the
[Apple ID web session](#the-apple-id-web-session) on the developer portal: iCloud containers through
`services-account/v1/cloudContainers`, app groups through the portal's `listApplicationGroups.action` and
`addApplicationGroup.action`, and assignment by updating the bundle ID (`services-account/v1/bundleIds/{id}`) so that
only its App Groups (or iCloud) capability changes and every other capability stays as it is. When Apple answers the
container listing, the container creation or the bundle ID update as if it did not exist (400, 404, 405, 415, 422),
the matching older `….action` post fastlane uses is tried instead; nothing else is retried another way. Every
assignment is checked by reading the bundle ID again.

- A group or container is named by its identifier (`group.` or `iCloud.`, then reverse-DNS) or by its ID from `list`;
  a bundle ID by its identifier or ID. Registering an identifier the team has already sends nothing. Apple cannot
  delete an iCloud container.
- `assign` keeps what the bundle ID has and adds the rest; App Groups is enabled on the bundle ID if needed. A
  container needs the bundle ID's iCloud capability enabled first (`xless bundle-ids capabilities <bundle-id> enable ICLOUD`,
  which `sign` also does). `unassign` asks first and leaves the capability enabled.
- A provisioning profile lists the groups and containers of the moment it was made, so after a change xless
  regenerates the bundle ID's profiles through the API key ([`xless profiles renew`](#xless-profiles); it asks first,
  or `--yes`). Without an API key, or without a terminal and `--yes`, it says which profiles to renew; `sign`
  regenerates its own. A profile that cannot be made again as it is (no unexpired certificate left) is left with a
  note.

With `--json`, `list` prints `{"data": [{"id", "identifier", "name", "prefix", …}]}`, `create`
`{"registered": [...], "existing": [...]}`, and `assign` / `unassign` `{"bundleId", "changed", "unchanged", "linked",
"regeneratedProfiles"}` (identifiers; each regenerated profile as `xless profiles renew --json` prints it).

## `xless keys`

```sh
xless keys list                                            # key ID, name, services, downloadable, the store entry
xless keys create --service apns --name "Push"             # straight into the secret store as XLESS_APNS_KEY@<TEAM_ID>
xless keys create --service siwa --bundle-id com.example.app
xless keys create --service apns,devicecheck               # several services on one key: XLESS_AUTH_KEY@<TEAM_ID>
xless keys create --service musickit --music-id AB12CD34EF # a MusicKit key for that Music ID
xless keys show 2X9R4HXF34                                 # services, Sign in with Apple bundle IDs, store entry
xless keys revoke 2X9R4HXF34                               # asks first (--yes without a terminal)
```

Auth keys (Certificates, IDs & Profiles > Keys) sign the tokens of token-based APNs, Sign in with Apple's server
side, DeviceCheck and MusicKit. No documented API covers them, so these commands use the
[Apple ID web session](#the-apple-id-web-session) on the developer portal (`services-account/QH65B2/account/auth/key/…`,
the calls fastlane and the App Store Connect CLI make). `--service` takes `apns`, `siwa` (Sign in with Apple, with
`--bundle-id`: the primary App ID, by identifier or ID), `devicecheck` and `musickit` (with `--music-id`, repeatable:
the ID of a Music ID registered in the portal), repeated or comma-separated.
MapKit, WeatherKit and the other services are not supported: their service IDs are not confirmed.

`create`, in one process and one sign-in:

1. checks the secret store before anything else: it must exist ([`xless secrets init`](secrets.md)) and it is
   unlocked (the passphrase is asked first);
2. lists the team's keys and stops, before anything is sent, when the name is taken or a service is at Apple's limit:
   two APNs keys per team (the error lists them; one APNs key serves every app of the team, sandbox and production);
3. creates the key (`--name`, ASCII letters, digits and spaces; default `xless <services> <date>`, e.g.
   `xless APNs 20261123`, with ` 2`, ` 3`… when the team has a key of that name) with one request, never
   retried; when it gets no answer, or a server error, the error says a key may exist and to check `xless keys list`;
4. downloads its `.p8` **once** (Apple offers it a single time, so the download is never retried) and seals it into
   the store as `XLESS_APNS_KEY@<TEAM_ID>` (`XLESS_SIWA_KEY`, `XLESS_DEVICECHECK_KEY`, `XLESS_MUSICKIT_KEY`;
   `XLESS_AUTH_KEY` for several services) with its key ID, team and services; when the team already has an entry
   of that name, `<name>.<KEY_ID>@<TEAM_ID>`, so a lookup of the name stays unambiguous. Then it reports.

If anything fails once the key exists (the download, the store, an answer xless cannot read), the error says that key
`<KEY_ID>` exists, that xless does not have its `.p8` and that it cannot be downloaded again: revoke it with
`xless keys revoke <KEY_ID>`. The `.p8` is never written to a file: `xless secrets export <entry> --out
AuthKey_<KEY_ID>.p8` does that when a server needs one ([secrets.md](secrets.md)).

`revoke` reads the key, asks before it revokes (Apple cannot undo it; every server signing with it stops working),
then removes the store's auth-key entries for that key ID. A key the Apple ID may not revoke is refused before the
question.

With `--json`, `list` prints `{"data": [{"id", "name", "services", "bundleIDs", "canDownload", "canRevoke",
"storeEntries"}]}` (services as `--service` names, unknown ones by Apple's service ID), `show` one such object, and
`create` `{"keyID", "name", "services", "bundleIDs", "musicIDs", "team", "entry"}`.

## `xless apps`

```sh
xless apps list                                   # app ID, name, bundle ID, SKU, primary locale
xless apps show com.example.app                   # the record, its app infos and its App Store versions with their states
xless apps create --bundle-id com.example.app --name "Example" --sku EXAMPLE1 --locale en-US
xless apps create --bundle-id com.example.app --name "Example" --sku EXAMPLE1 --locale en-US --platform ios --platform macos
xless apps update com.example.app --content-rights does-not-use-third-party-content
xless apps update 1234567890 --primary-locale de-DE
xless apps price-points com.example.app                  # every price point in the United States, cheapest first
xless apps price-points com.example.app --territory JPN
xless apps price-points com.example.app --price 0.99    # that point, and its price in every other territory
```

An app is named by its app ID (the digits App Store Connect shows as "Apple ID", from `list`) or its bundle identifier.
`list`, `show` and `update` use the API key (`/v1/apps`; App Manager is enough). `update` sends only the values that
differ from the app's (`PATCH /v1/apps/{id}`), and nothing when none does: `--primary-locale` (App Store Connect's
locales, any case: `en-US`, `de-DE`, `ja`, `zh-Hans`…), `--content-rights` (`uses-third-party-content` or
`does-not-use-third-party-content`, which App Review asks for) and `--bundle-id` (accepted by Apple only until the first
build is uploaded).

The API cannot create an app record, so `create` uses the [Apple ID web session](#the-apple-id-web-session)
(`POST /iris/v1/apps`, the document App Store Connect's New App dialog sends, as fastlane and the App Store Connect CLI
do). The Apple ID needs the Account Holder, Admin or App Manager role. In one process:

1. Every value is checked before anything is sent: the bundle identifier (explicit, no wildcard), the name (2 to 30
   characters), the SKU (letters, digits, `-`, `.` and `_`, not starting with one of those three), the locale, the
   platforms (`--platform ios|macos`, repeatable, default `ios`) and `--app-version` (the first App Store version,
   default `1.0`). `--company-name` (the seller name) is only asked for a team's first app.
2. With an API key for the team, the app is looked up by bundle ID: **an app that already has the bundle ID is reported
   and reused**, nothing is sent and no sign-in happens (a note says when its name, SKU or locale differ from the ones
   given). Otherwise it signs in and checks that the key and the Apple ID session are on the same App Store Connect
   team (their issuer IDs), and stops before anything is sent when they are not (`ASC_KEY_*` in the environment take
   precedence over `--team`'s store entry). The bundle ID must be registered; when it is not, `create` offers to
   register it (universal, as `sign` does; `--yes` without a terminal). Without an API key, both checks go through the
   web session and an unregistered bundle ID is an error that says to run [`xless bundle-ids create`](#xless-bundle-ids).
   A key that resolves but that Apple refuses stops the command: fix or unset it.
3. It sends **one** create request, never retried: the app, its name in the primary locale, and a first
   App Store version with a localization per platform. A refusal is reported as Apple worded it: a name already used on
   the App Store (names are unique across the store) asks for another `--name`, a SKU already used by the team for
   another `--sku`.
4. When the answer is unclear (no answer, a server error, a body xless cannot read), it looks the app up by bundle ID
   before saying anything (through the web session, else the API key): found, it is reported as created; not found,
   the error says so, and the same command can be re-run: if the app appeared meanwhile, it is reported, never created
   twice.

After that, everything else about the app goes through the API key: `xless apps show` sees it at once.

`price-points` lists the prices the app can take in a territory (`--territory`, three letters, default `USA`): each
price point's customer price, proceeds and currency, cheapest first (`GET /v1/apps/{id}/appPricePoints`). With
`--price` (`free` or a customer price such as `0.99`), it shows the point with exactly that price and its
equalizations, the price App Store Connect sets in every other territory that follows it
(`GET /v3/appPricePoints/{id}/equalizations`); a price that is no point is an error naming the nearest ones. These are
the prices `app.yml`'s `pricing` takes ([appstore-manifest.md](appstore-manifest.md#appyml)).

With `--json`, `list` prints `{"data": [apps]}`, `show` `{"data": app, "appInfos": [...], "appStoreVersions": [...]}`
(App Store Connect's resources), `update` the app, and `create` `{"created": [app], "existing": [app]}`, each app as
`{"id", "name", "bundleId", "sku", "primaryLocale"}` (a field App Store Connect did not send is left out).
`price-points` prints `{"data": [points]}`, or with `--price` `{"pricePoint": point, "equalizations": [points]}`, each
point as `{"id", "territory", "currency", "customerPrice", "proceeds"}`.

## `xless store`

```sh
xless store pull --app com.example.app    # the app's listing into ./appstore
xless store validate                      # offline checks of ./appstore
xless store push --dry-run                # what differs at App Store Connect
xless store push                          # send it
xless store privacy pull                  # App Privacy answers into app.yml (web session)
xless store privacy push                  # send them and publish (web session)
```

The App Store listing (text per locale, screenshots, previews, categories, age rating, App Review contact, licence
agreement, price and availability, App Privacy) lives in an `appstore/` directory reviewed like code: its format,
`pull`, `validate` and `push` are in [appstore-manifest.md](appstore-manifest.md). `pull` and `push` use the API key,
except App Privacy, which has no API: `store privacy pull|push`, and `push` when `app.yml` has `privacy:`, use the
Apple ID web session ([App Privacy](appstore-manifest.md#app-privacy-xless-store-privacy)). `pull` never reads the
demo account's password, and `push` sends it from the secret store only when it must.

## `xless builds`

```sh
xless builds list --app com.example.app                        # newest first; expired builds left out
xless builds list --app com.example.app --state processing,failed --app-version 1.2.0
xless builds list --expired                                     # only the expired ones, every app
xless builds show 1.2.0+42 --app com.example.app               # state, expiry, export compliance, TestFlight states
xless builds wait 1.2.0+42 --app com.example.app --timeout 2h  # until processing ends
xless builds update 1.2.0+42 --app com.example.app --uses-non-exempt-encryption false
xless builds update 1.2.0+42 --app com.example.app --encryption-declaration 1a2b3c4d
xless builds expire 1.1.0+17 --app com.example.app             # asks first
```

After [`xless upload`](signing-and-testflight.md) a build is processed by App Store Connect before TestFlight or a
release can use it. `builds` reads and changes builds with the API key (`/v1/builds`; App Manager is enough). A build
is named by its ID (from `list`) or by its version and build number, `<version>+<build number>` (`1.2.0+42`; a
`build: dated` number reads `1.2.0+1.2.0.2026112301`). That lookup covers every app the key sees, expired builds
included; when two apps or two platforms have the same numbers, it is an error naming each, and `--app` (app ID or
bundle identifier) or `--platform` (`ios`, `macos`, `tvos`, `visionos`) narrows it. A bare build number is refused: it
could be an ID. With a build ID, `--app` is checked: a build of another app is refused.

- `list` shows the builds most recently uploaded first (at most `--limit`, default 50; a note says when there may be
  more): ID, app (without `--app`), version, build number, platform, state (`processing`, `valid`, `invalid`, `failed`,
  or `expired`), whether it uses non-exempt encryption (`yes`, `no` or `not answered`), and the upload and expiry
  dates. Builds that expired are left out; `--expired` lists only them. `--app-version`, `--build-number`,
  `--platform` and `--state` (repeatable or comma-separated) filter on App Store Connect's side.
- `show` adds the minimum OS, the audience, the encryption declaration and the TestFlight states, and says how to
  answer export compliance when nothing answers it.
- `wait` reads the build every 30 seconds until its processing ends, saying each state change on standard error. A
  `<version>+<build number>` that is not visible yet (a build just uploaded) is looked up until it appears. It exits
  0 once the build is valid; an invalid or failed build, or the end of `--timeout` (`90s`, `30m`, `2h` or seconds;
  default `60m`, at most `24h`), is an error. It only reads: Ctrl-C stops it (exit 130), and nothing is left behind.
- `update` answers export compliance for a build uploaded without `ITSAppUsesNonExemptEncryption` in its Info.plist
  (Apple refuses the answer when the Info.plist gives it): `--uses-non-exempt-encryption true|false`
  (`PATCH /v1/builds/{id}`), or `--encryption-declaration <id>` to attach one of the app's existing encryption
  declarations (`PATCH /v1/builds/{id}/relationships/appEncryptionDeclaration`; an ID that is not one of the app's is
  refused with the list of its declarations; [`xless store push`](appstore-manifest.md) creates them from `app.yml`).
  Only what differs from the build is sent.
- `expire` asks first (or needs `--yes`): testers can no longer install the build, and it cannot be undone. An expired
  build is reported and nothing is sent.

With `--json`, `list` prints `{"data": [builds], "included": [versions and apps]}` and `show`, `wait`, `update` and
`expire` print `{"data": build, "included": [...]}`: App Store Connect's resources, the build's `version` being its
build number and its `preReleaseVersion` (in `included`) its version and platform.

## `xless users`

```sh
xless users list                                   # ID, email, name, roles, apps seen, provisioning access
xless users list --role admin,app-manager
xless users show grace@example.com                 # every app the user sees
xless users invite grace@example.com --first-name Grace --last-name Hopper --role developer --app com.example.app
xless users invite ops@example.com --first-name Ops --last-name Team --role admin
xless users update grace@example.com --role developer,marketing --all-apps --provisioning
xless users remove grace@example.com               # asks first
xless users invitations list                       # invitations not accepted yet, with their expiry
xless users invitations cancel grace@example.com   # asks first
```

Internal TestFlight testers must be App Store Connect users of the team: `invite` makes one. These commands use the
API key (`/v1/users`, `/v1/userInvitations`), which needs the **Admin** role; a narrower key gets a 403 whose fix says
so and how to create an Admin key (`xless auth api-key create --role ADMIN`, see [above](#xless-auth-api-key)). A
person is named by email address (their Apple ID, compared without regard to case) or by ID (from `list`).

- **Roles** (`--role`, repeatable or comma-separated, any case, `-` or `_`): `ADMIN`, `FINANCE`, `SALES`,
  `MARKETING`, `APP_MANAGER`, `DEVELOPER`, `ACCESS_TO_REPORTS`, `CUSTOMER_SUPPORT`, `CREATE_APPS`,
  `CLOUD_MANAGED_DEVELOPER_ID`, `CLOUD_MANAGED_APP_DISTRIBUTION` and `GENERATE_INDIVIDUAL_KEYS`. `ACCOUNT_HOLDER` can
  only be listed (`list --role account-holder`): Apple gives it to the person who enrolled.
- **Apps:** `--all-apps` (every app, present and future) or `--app <app>` for each app the person sees (an app ID or a
  bundle identifier). An `ADMIN` sees every app, so `--app` is refused with it and `--all-apps` is implied.
  `--provisioning` gives access to Certificates, Identifiers & Profiles.
- **`invite` invites once:** an address that is already a user of the team, or already has a pending invitation, is
  reported with its ID and roles, and nothing is sent; when the roles differ, a hint says how to change them
  (`update`, or `invitations cancel` and invite again). The invitation is sent once, never retried. Apple emails the
  link; the person becomes a user when they accept it.
- **`update`** changes the roles (`--role` replaces them all), the apps (`--all-apps`, `--app`) and the provisioning
  access (`--provisioning`, `--no-provisioning`) in one request, with only what differs; when nothing differs, nothing
  is sent. The Account Holder's roles cannot be changed, and an `ADMIN` cannot be limited to some apps without
  giving other roles.
- **`remove`** and **`invitations cancel`** ask first (or need `--yes`). The Account Holder cannot be removed.
  An address that only has an invitation is not a user: `show`, `update` and `remove` say so and point at
  `invitations`.

With `--json`, `list` and `invitations list` print `{"data": [users or invitations], "included": [apps]}`, `show`
prints `{"data": user, "included": [apps]}`, `update` prints `{"data": user, "included": []}`, `invite` prints
`{"result": "invited" | "existing-user" | "existing-invitation", "data": resource}`, `remove` prints
`{"removed": user}` and `invitations cancel` prints `{"cancelled": invitation}`.

## `xless testflight`

```sh
xless testflight groups list --app com.example.app            # internal/external, automatic distribution, public link
xless testflight groups create "Public Beta" --external --app com.example.app
xless testflight groups create "QA" --all-builds --app com.example.app      # internal, gets every build
xless testflight groups update "QA" --name "QA team" --no-feedback --app com.example.app
xless testflight groups delete "QA team" --app com.example.app              # asks first
xless testflight testers list --app com.example.app --group "Public Beta"
xless testflight testers add ada@example.com grace@example.com --group "Public Beta" --app com.example.app
xless testflight testers remove ada@example.com --group "Public Beta" --app com.example.app   # asks first
xless testflight testers invite grace@example.com --app com.example.app     # Apple emails the invitation again
xless testflight builds add 1.2.0+42 --group "QA" --group "Public Beta" --app com.example.app
xless testflight builds remove 1.2.0+41 --group "Public Beta" --app com.example.app           # asks first
xless testflight whats-new set 1.2.0+42 --app com.example.app --locale en-US --file notes.txt
xless testflight beta-info set --app com.example.app --description-file beta.txt --feedback-email beta@example.com \
  --privacy-policy-url https://example.com/privacy --contact-first-name Ada --contact-last-name Lovelace \
  --contact-email review@example.com --contact-phone "+1 555 0100" --demo-account-name demo --demo-required
xless testflight beta-info show --app com.example.app
xless testflight beta-review submit 1.2.0+42 --app com.example.app
xless testflight beta-review status 1.2.0+42 --app com.example.app
xless testflight public-link enable "Public Beta" --app com.example.app --limit 500
xless testflight public-link disable "Public Beta" --app com.example.app    # asks first
```

TestFlight with the API key (`/v1/betaGroups`, `/v1/betaTesters`, `/v1/betaTesterInvitations`, `/v1/betaAppLocalizations`,
`/v1/betaAppReviewDetails`, `/v1/betaLicenseAgreements`, `/v1/betaAppReviewSubmissions`; App Manager is enough). `--app`
(an app ID or a bundle identifier) names the app; a group is named by its exact, case-sensitive name or its ID; a build
by its ID or `<version>+<build number>`, as in [`xless builds`](#xless-builds) (`--app` and `--platform` narrow it).

- **Groups.** `create` makes an internal group unless `--external` is given; `--all-builds` (internal only) gives the
  group every build (automatic distribution). Whether a group is internal or external, and its automatic distribution,
  cannot change afterwards. A group of that name already there is reported and nothing is sent (a group of the other
  kind is an error). `update` renames a group or turns its feedback on or off, sending only what differs. `delete`
  asks first (or needs `--yes`).
- **Testers.** `add` adds each address to the group: someone already in it is reported and nothing is sent; an
  existing tester is linked to the group; a new one is created with it (sent once; Apple emails them). The testers of an
  internal group must be App Store Connect users of the team: an address that is not one is refused, with the
  [`xless users invite`](#xless-users) to run. That check reads `/v1/users`, which needs an Admin key; without one, a
  note says so and Apple decides. `--first-name` and `--last-name` name a new tester (one address at a time).
  `remove` takes testers out of a group, or without `--group` out of every group and build of the app; it asks first.
  `invite` has Apple email testers of the app their invitation again. Addresses are compared without regard to case.
- **Builds.** `builds add` adds the build to the groups that lack it (groups that have it are left alone); an external
  group's testers get it once Apple approves it. `builds remove` asks first. `whats-new set` sets the build's What to
  Test for `--locale` (default `en-US`, at most 4000 characters, `--text` or `--file`); the same text sends nothing.
  `whats-new show` prints every locale's.
- **Beta information.** `beta-info set` sets, with only what differs: the texts of `--locale` (`--description` or
  `--description-file`, `--feedback-email`, `--marketing-url`, `--privacy-policy-url`), the beta App Review details
  (`--contact-first-name`, `--contact-last-name`, `--contact-phone`, `--contact-email`, `--review-notes`,
  `--demo-account-name`, `--[no-]demo-required`) and the beta license agreement (`--license-file`). `""` clears a text.
  The demo account's **password is never an option**: it comes from the secret `--demo-password-secret-name` names
  (`XLESS_DEMO_PASSWORD` by default: the environment, `NAME_FILE`, or the [secret store](secrets.md)). Apple never
  gives it back, so it is sent only when the demo account is required and had no name, its name changes, it becomes
  required, or with `--resend-demo-account`; it is hidden from `--verbose` traces and scrubbed from Apple's errors. A
  required demo account without a name is refused. `beta-info show` prints all of it, never the password.
- **Beta app review.** `beta-review submit` submits a processed (valid, unexpired) build; a build already submitted
  is reported with its state and nothing is sent. Apple reviews it with the beta information above and the build's
  What to Test. `beta-review status` shows the review state (`waiting for review`, `in review`, `rejected`,
  `approved`) and the build's external testing state.
- **Public links.** `public-link enable` turns on an external group's public link (or changes its limit:
  `--limit` 1–10000, `--no-limit`) and prints it; `show` prints it; `disable` asks first. Internal groups have none.

With `xless ship`, the [`testflight:` block of xless.yml](xless-yml.md#testflight) does the same in one run: testers for
the internal groups, and with `external:` the external groups, their testers, the beta information and the submission.

With `--json`, `groups list` prints `{"data": [groups], "included": []}`, `testers list` `{"data": [testers],
"included": [groups]}`, `groups create` and `beta-review submit` `{"result": "created" | "existing" | "submitted", "data":
resource}`, `testers add` `{"results": [{"email", "result": "created" | "added" | "already-in-group", "data"}]}`,
`beta-info show` and `set` `{"localizations": [...], "reviewDetail": ..., "licenseAgreement": ...}`, `beta-review status`
`{"build", "submission", "externalBuildState"}`, and the other commands the resource they changed.

## `xless release`

```sh
xless release create 1.2 --app com.example.app            # the App Store version to submit
xless release attach 1.2+42                                # its build (or submit --build)
xless release submit --build 1.2+42 --release manual --phased --dry-run
xless release submit --build 1.2+42 --release manual --phased
xless release status
xless release cancel                                       # asks first
xless release publish                                      # a manual release, once approved
xless release phased pause | resume | complete
```

The last step to the App Store, with the App Store Connect API key (`/v1/appStoreVersions`, `/v1/reviewSubmissions`,
`/v1/reviewSubmissionItems`, `/v1/appStoreVersionReleaseRequests`, `/v1/appStoreVersionPhasedReleases`).

- **Which version.** `--app`, `--platform` and `--app-version` name it. Without them, the [`appstore/`
  manifest](appstore-manifest.md) gives the defaults (app.yml's `bundleID`, `platform` and `version`; `--dir` points at
  another directory), else xless.yml's bundle ID, the app's only platform and its newest version (`publish`: the version
  waiting for its release; `phased`: the newest released one). The option is `--app-version` because `--version` is
  xless's own.
- **`create <version>`.** App Store Connect keeps one version in preparation per platform: when there is one, it takes
  the new version string; when the version exists, nothing is sent; a version string already released or in review is
  refused. [`xless store push`](appstore-manifest.md) creates the version from app.yml too.
- **`attach <build>`.** The build (its ID or `<version>+<build number>`, as in [`xless builds`](#xless-builds)) must be
  the app's, of the same platform and version string, and not expired. A build still processing is attached with a
  note.
- **`submit`.** First the **pre-flight**, which only reads and lists every problem at once:

  | Check | What it needs |
  |---|---|
  | manifest | `appstore/` valid as `xless store validate` (without `--draft`) checks it, of this app, platform and version; skipped without a manifest |
  | metadata | `xless store push` would send nothing: the listing on App Store Connect is the manifest's |
  | listing | per locale a name, description, keywords and support URL; a privacy policy URL; a primary category; the content rights declaration |
  | screenshots | in the primary locale, a screenshot for the required display types (iPhone 6.7" or 6.5" for iOS; iPad 13" only warns); none failed |
  | privacy | the App Privacy answers published: checked through an Apple ID web session kept by `xless auth login --keep`, else a warning (it has no API) |
  | pricing, availability | a price schedule, and at least one territory |
  | build, encryption | the build valid, not expired, of the version's string and platform; its export compliance answered |
  | review contact | the App Review contact's name, phone and email; a demo account name when one is required |

  `--release manual|auto|<date>` and `--phased` are what the submission sets: app.yml's `release` values are not
  compared then. When everything passes, only what App Store Connect does not have yet is sent: the build (`--build`;
  default: the one attached), the release type (`manual`: [`publish`](#xless-release) releases it; `auto`: on
  approval; a date `2026-12-01` (midnight UTC) or a time on the hour `2026-12-01T09:00:00Z`: not before then), the
  phased release (`--phased` adds one, `--no-phased` removes one that has not started), then the review submission:
  created, the version added, submitted. A run that stopped half-way (a draft submission with or without the version,
  a build attached) is **resumed** by running it again; a version rejected by App Review is submitted again in its
  submission. `--dry-run` runs the pre-flight and lists the steps.

  Exit codes: **0** submitted (or a dry run that passed), **21** the pre-flight failed (nothing was sent), **22** the
  version is already in review (nothing was sent), **20** any other error. With `--json`, one document:
  `{"outcome": "submitted" | "dryRun" | "preflightFailed" | "alreadyInReview", "appID", "bundleID", "platform",
  "version", "versionID", "versionState", "build", "buildID", "submissionID", "submissionState", "steps", "notes",
  "preflight": {"passed", "checks": [{"name", "status": "ok" | "failed" | "warning" | "skipped", "message", "fix"}]}}`.
- **`status`** shows the version's state, its release type, its build, its phased release (state, day of 7) and the
  review submissions that hold it, with their items' states. App Review's reasons for a rejection are not in the App
  Store Connect API: status says the version was rejected, and Apple emails the reasons to the account holder and the
  admins.
- **`cancel`** withdraws the version from App Review (asks first, or `--yes`): its review submission is canceled, and
  the version can be changed and submitted again.
- **`publish`** releases a version that App Review approved and that waits for a manual release (`pending developer
  release`); a version already released is reported and nothing is sent. With a phased release, the phases start.
- **`phased pause | resume | complete`**: a phased release gives the update to more users each day over 7 days.
  `pause` holds it (at most 30 days in all), `resume` goes on, `complete` gives it to everyone now. A phased release
  already in that state sends nothing; one that has not started (the version is not released) cannot be moved.

With `--json`, `create` prints `{"result": "created" | "renamed" | "existing", "data": version}`, `attach`
`{"result": "attached" | "unchanged", "versionID", "buildID"}`, `status` `{"appID", "bundleID", "version", "build",
"phasedRelease", "submissions": [{"id", "state", "submittedDate", "items"}]}`, `cancel` `{"result": "canceled" |
"unchanged" | "none", "submissionID", "state"}`, `publish` `{"result": "released" | "unchanged", "versionID", "state"}`
and `phased` `{"result", "data": phased release}`.

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

An account command that fails prints `[account] cause — fix` on standard error and exits with code **20** (`xless
release submit` also exits with 21 and 22: [above](#xless-release)). The cause
names the request (`GET /v1/apps/123`) and Apple's error code, detail and the field it points at. A failure of the
Apple ID web session names the interface (App Store Connect's or the developer portal's), says it is undocumented and
gives the page to use meanwhile; a refused session (HTTP 401) asks to sign in again (`xless auth logout` first when a
session was kept). For the App Store Connect API, the fix depends on the status:

| Status | Fix |
|---|---|
| 401 | The key was revoked, `ASC_ISSUER_ID` is not its issuer, or the machine's clock is off. |
| 403 | The key's role is too narrow: the fix names the role the request needs (Admin for users and certificates, identifiers, devices and profiles; Finance or Sales for their reports; App Manager for the app's own resources) and how to create a key with it (`xless auth api-key create --role <ROLE>`). |
| 404 | No such resource: check the ID, and that it belongs to the key's team. |
| 409 | A conflict: the fix names the field Apple refused (`name`, `identifier`, …). |
| 429 | The hour's request budget is spent: the fix says how long to wait. |

A usage mistake (an unknown method, a path on another host) exits 64 before anything is sent.
