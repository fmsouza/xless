# What the App Store Connect API covers, and what needs the Apple ID web session

Source: Apple's OpenAPI specification of the App Store Connect API,
https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip
(`openapi.oas.json`, `info.version` **4.6.1**, file dated **2026-11-19**: 1,032 paths, 1,342 operations), read as data.
"Documented" below means the operation is in that file; everything else xless does goes through the web interfaces
Apple's own pages call, signed in with an Apple ID ([security.md](../security.md#the-apple-id-web-session)).

Every documented path xless calls was checked against the file (2026-11-23, at the commit that added this note): the
74 path templates written in `Sources/` (`/v1/…`, `/v2/…`, `/v3/…`) are all in it, besides three generic ones whose
resource is a variable. Re-run the check after changing a call:

```sh
grep -rhoE '"/v[0-9]/[^"]*"' Sources | sed -E 's/\\\([^)]*\)/{id}/g; s/\?.*//' | tr -d '"' | sort -u > /tmp/used.txt
python3 -I - openapi.oas.json /tmp/used.txt <<'EOF'
import json, re, sys
paths = json.load(open(sys.argv[1]))["paths"]
known = [re.compile("^" + re.sub(r"\{[^}]+\}", "[^/]+", p) + "$") for p in paths]
for u in open(sys.argv[2]).read().split():
    if u.split("/")[2] != "{id}" and not any(k.match(u) for k in known):
        print("not in the spec:", u)
EOF
```

(The generic paths, `/v1/{type}/…`, are skipped.)

## The matrix

| Area | Documented API (API key) | Not in the API, so the web session | xless |
|---|---|---|---|
| Devices | `devices`: list, register, rename, enable/disable (no delete) | | [`xless devices`](../apple-account.md#xless-devices) |
| Bundle IDs and capabilities | `bundleIds`, `bundleIdCapabilities` (28 capability types) | | [`xless bundle-ids`](../apple-account.md#xless-bundle-ids) |
| Merchant IDs, pass type IDs | `merchantIds`, `passTypeIds` | assigning a merchant ID to a bundle ID (a portal step xless does not do) | [`xless merchant-ids`](../apple-account.md#xless-merchant-ids) |
| Certificates | `certificates` (18 types; no Developer ID Installer) | | [`xless certs`](../apple-account.md#xless-certs) |
| Provisioning profiles | `profiles` (14 types): list, create, delete (no update) | | [`xless profiles`](../apple-account.md#xless-profiles) |
| App groups, iCloud containers | none | create, list, assign to bundle IDs | [`xless app-groups`, `xless icloud-containers`](../apple-account.md#xless-app-groups-and-xless-icloud-containers) |
| Auth keys (APNs, Sign in with Apple, DeviceCheck, MusicKit) | none | create, list, download once, revoke | [`xless keys`](../apple-account.md#xless-keys) |
| App Store Connect API keys | none | create, list, download once, revoke | [`xless auth api-key`](../apple-account.md#xless-auth-api-key) |
| Teams | none (a key belongs to one team) | the portal's teams, App Store Connect's providers | [`xless team`](../apple-account.md#xless-team) |
| App record | `apps`: `GET`, `PATCH` (no `POST`) | create | [`xless apps`](../apple-account.md#xless-apps) |
| Listing: text, categories, age rating, review details, EULA, encryption, accessibility | `appInfos`, `appInfoLocalizations`, `appStoreVersionLocalizations`, `appCategories`, `ageRatingDeclarations`, `appStoreReviewDetails`, `endUserLicenseAgreements`, `appEncryptionDeclarations`, `accessibilityDeclarations` | | [`xless store`](../appstore-manifest.md) |
| Screenshots, previews, review attachments, compliance documents | `appScreenshotSets`, `appScreenshots`, `appPreviewSets`, `appPreviews`, `appStoreReviewAttachments`, `appEncryptionDeclarationDocuments` (upload operations) | | `xless store push` |
| Pricing and availability | `appPricePoints`, `appPriceSchedules` (v1), `appAvailabilities` (v2), `territoryAvailabilities`, `territories` | | `xless store push`, `xless apps price-points` |
| App Privacy | none | the data usages, their catalogue and the published state | [`xless store privacy`](../appstore-manifest.md#app-privacy-xless-store-privacy) |
| Builds | `builds`, `buildUploads`, `buildUploadFiles`, `preReleaseVersions`, `buildBetaDetails` | | `xless upload`, [`xless builds`](../apple-account.md#xless-builds) |
| TestFlight | `betaGroups`, `betaTesters`, `betaTesterInvitations`, `betaAppLocalizations`, `betaBuildLocalizations`, `betaAppReviewDetails`, `betaAppReviewSubmissions`, `betaLicenseAgreements` | | [`xless testflight`](../apple-account.md#xless-testflight) ([details](asc-testflight.md)) |
| Users and invitations | `users`, `userInvitations` | | [`xless users`](../apple-account.md#xless-users) |
| Review submission, release, phased release | `appStoreVersions`, `reviewSubmissions`, `reviewSubmissionItems`, `appStoreVersionReleaseRequests`, `appStoreVersionPhasedReleases` | | [`xless release`](../apple-account.md#xless-release) |
| In-app purchases, subscriptions | `inAppPurchases` (v2), `inAppPurchaseLocalizations`, `inAppPurchasePriceSchedules`, `inAppPurchaseAvailabilities`, `inAppPurchaseAppStoreReviewScreenshots`, `inAppPurchaseVersions`, `inAppPurchaseSubmissions`, `subscriptionGroups`, `subscriptionGroupLocalizations`, `subscriptions`, `subscriptionLocalizations`, `subscriptionPrices`, `subscriptionPricePoints`, `subscriptionAvailabilities`, `subscriptionAppStoreReviewScreenshots`, `subscriptionVersions`, `subscriptionGroupVersions`, `subscriptionSubmissions` | | [`xless store`](../appstore-manifest.md#in-app-purchases-and-subscriptions), [`xless iap`, `xless subscriptions`](../apple-account.md#xless-iap-and-xless-subscriptions), `xless release submit`; offers, promoted purchases and images: `xless api` |
| Sandbox testers | `sandboxTesters` (v2: list, update), `sandboxTestersClearPurchaseHistoryRequest` | | [`xless sandbox-testers`](../apple-account.md#xless-iap-and-xless-subscriptions) (created in App Store Connect only) |
| Customer reviews | `customerReviews`, `customerReviewResponses` | | [`xless reviews`](../apple-account.md#xless-reviews); review summarizations: `xless api` |
| Sales and finance reports | `salesReports`, `financeReports` | | [`xless reports`](../apple-account.md#xless-reports) |
| Webhooks | `webhooks` | | [`xless webhooks`](../apple-account.md#xless-webhooks); deliveries, pings, updates: `xless api` |
| Analytics reports | `analyticsReportRequests`, `analyticsReports`, `analyticsReportInstances`, `analyticsReportSegments` | | `xless api` |
| Agreements (Paid Apps, tax, banking) | none | detected only (`/olympus/v1/contractMessages`): a person accepts legal terms in a browser | the error names the page |

`xless api` reaches every documented operation, including the ones xless has no command for (Game Center, App Clips,
custom product pages, experiments, in-app events, Xcode Cloud).

## The web endpoints

The requests are the ones Apple's own pages send. Each one is reproduced from open-source clients that use it today;
the source files are named in the code next to each call (`Sources/XlessAppleID/`). None of them is documented by
Apple, and **none has been exercised against a real Apple account yet**: the tests replay recorded answers built from
those sources. The real-account check is [#105](https://github.com/fmsouza/xless/issues/105).

### Sign-in (`idmsa.apple.com`)

| Request | Used for | Source |
|---|---|---|
| `GET /appleauth/auth/signin?widgetKey=…` (a proof-of-work challenge), `POST …/signin/init`, `POST …/signin/complete` | SRP-6a sign-in: the password never leaves the machine | fastlane (spaceship), xcodes |
| `GET /appleauth/auth`, `POST …/verify/trusteddevice/securitycode`, `PUT …/verify/phone`, `POST …/verify/phone/securitycode`, `GET …/2sv/trust` | the two-factor code (trusted device or text message), then finishing the sign-in | fastlane (spaceship), xcodes |
| `POST …/verify/security/key` (after `fsaChallenge` in `GET /appleauth/auth`) | a security key's WebAuthn assertion (rpId `apple.com`, origin `https://idmsa.apple.com`) as the second factor | XcodesLoginKit (`Client+SecurityKey.swift`, LibFido2Swift), the asc CLI (`internal/web/auth_security_key.go`) |
| `HEAD https://appstoreconnect.apple.com/logout`, `GET /olympus/v1/app/config?hostname=itunesconnect.apple.com` | the sign-in widget key | fastlane (spaceship) |

### App Store Connect (`appstoreconnect.apple.com`)

| Request | Used for | Source |
|---|---|---|
| `GET /olympus/v1/session`, `POST /olympus/v1/session` | the provider (team) in use, switching it | fastlane `spaceship/client.rb`, `spaceship/connect_api/tunes/client.rb` |
| `GET /olympus/v1/contractMessages` | agreements waiting to be accepted | fastlane (spaceship) |
| `GET`, `POST /iris/v1/apiKeys`, `GET /iris/v1/apiKeys/{id}?fields[apiKeys]=privateKey` (once), `PATCH /iris/v1/apiKeys/{id}` (`isActive: false`) | `xless auth api-key create`, `list`, `revoke` | App Store Connect CLI `internal/web/api_keys.go`; RevenueCat CLI `internal/appleconnect/keys.go` |
| `GET /iris/v1/apps?filter[bundleId]=…`, `POST /iris/v1/apps` | `xless apps create` | fastlane `spaceship/connect_api/tunes/tunes.rb` (`post_app`); App Store Connect CLI `internal/web/apps.go`; RevenueCat CLI `internal/appleconnect/apps.go` |
| `GET /iris/v1/apps/{id}/dataUsages`, `POST /iris/v1/appDataUsages`, `DELETE /iris/v1/appDataUsages/{id}`, `GET /iris/v1/appDataUsageCategories`, `…Purposes`, `…DataProtections`, `GET /iris/v1/apps/{id}/dataUsagePublishState`, `PATCH /iris/v1/appDataUsagesPublishState/{id}` | `xless store privacy`, App Privacy in `store push` and `provision` | fastlane `spaceship/connect_api/tunes/tunes.rb` (`appDataUsage*`); App Store Connect CLI `internal/web/privacy.go` |

### Developer portal (`developer.apple.com/services-account/`)

| Request | Used for | Source |
|---|---|---|
| `POST QH65B2/account/listTeams.action` | `xless team list`, choosing the team | fastlane `spaceship/portal/portal_client.rb` |
| `POST QH65B2/account/ios/profile/listProvisioningProfiles.action` (one item) | the CSRF tokens a write needs | fastlane `spaceship/portal/portal_client.rb` |
| `GET v1/bundleIds?filter[identifier]=…`, `GET v1/bundleIds/{id}`, `PATCH v1/bundleIds/{id}` (the whole capability graph) | assigning app groups and iCloud containers | App Store Connect CLI `internal/web/developer_bundle_ids.go`, `developer_app_groups.go` |
| `POST QH65B2/account/ios/identifiers/listApplicationGroups.action`, `addApplicationGroup.action` | `xless app-groups list`, `create` | fastlane `spaceship/portal/portal_client.rb` |
| `GET`, `POST v1/cloudContainers`; fallback `POST QH65B2/account/cloudContainer/listCloudContainers.action`, `addCloudContainer.action` | `xless icloud-containers list`, `create` | App Store Connect CLI `internal/web/developer_icloud_containers*.go`; fastlane |
| `POST QH65B2/account/ios/identifiers/assignApplicationGroupToAppId.action`, `assignCloudContainerToAppId.action` | fallback when `PATCH v1/bundleIds/{id}` is refused as if it did not exist | fastlane `spaceship/portal/portal_client.rb` |
| `POST QH65B2/account/auth/key/list`, `…/get`, `…/v2/create`, `…/download` (once), `…/revoke` | `xless keys` | fastlane `spaceship/portal/portal_client.rb` (L816–885), `spaceship/portal/key.rb`; App Store Connect CLI `internal/web/developer_sign_in_keys.go` |

The `v1/…` portal requests are JSON:API sent as `POST` with `X-HTTP-Method-Override` (a `GET` carries its query in the
body), as the portal's pages do. Writes first get the `csrf` / `csrf_ts` tokens, and every answer's tokens go back on the
next request.

### Xcode downloads

`xless xcode download` (not an account command) signs in the same way, then uses
`QH65B2/downloadws/listDownloads.action`, `developerservices2.apple.com/services/download` and
`download.developer.apple.com` ([xcode-download.md](../xcode-download.md)), as fastlane and xcodes do.

## Not verified on a real account

Everything above runs in the tests against recorded answers only. What a real account still has to confirm, per area,
is listed in [#105](https://github.com/fmsouza/xless/issues/105); the biggest unknowns are the web session's shapes
(session and provider switch, team listing, the GET-override envelope, `v1/cloudContainers`, the `PATCH` of a bundle
ID's capability graph, the auth-key create answer, the App Privacy publish state on a new app) and a few documented
requests whose bodies the spec allows but Apple may refuse (capability settings, the price schedule with local IDs,
availability created with every territory, resubmitting a rejected version).
