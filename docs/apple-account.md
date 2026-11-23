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
which register app groups and iCloud containers and assign them to bundle IDs, and [`xless api`](#xless-api), which
calls any documented App Store Connect endpoint. More
commands (apps, TestFlight, releases) follow the conventions on this page.

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
