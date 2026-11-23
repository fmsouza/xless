# App Store Connect TestFlight delivery API (verified)

Source: Apple's official OpenAPI spec,
https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip
(`openapi.oas.json`, downloaded 2026-10-14, parsed as data). Every name below was read from the spec.

## Paths used
| Purpose | Request | Notes |
|---|---|---|
| Find the app | `GET /v1/apps?filter[bundleId]=<id>` | Same call as the upload stage. |
| List an app's groups | `GET /v1/betaGroups?filter[app]=<id>&limit=200` | Follows `links.next`. xless does not use `filter[name]`: it is an array filter that ASC splits on commas, so a name like "QA, iOS" would never match. Names are compared client-side, exactly (case-sensitive). |
| Create a group | `POST /v1/betaGroups` | `201` with a single BetaGroup; `409` on conflict. |
| Add a build to a group | `POST /v1/betaGroups/{id}/relationships/builds` | Body is `{ "data": [ { "type": "builds", "id": "<build>" } ] }`; `204` with no body; `409` possible. |
| Confirm a build is in a group | `GET /v1/betaGroups?filter[id]=<group>&filter[builds]=<build>&limit=1` | Bounded membership check after a `409`/`422` from the add; a non-empty `data` means the build is in the group. |
| Count a group's testers | `GET /v1/betaGroups/{id}/betaTesters` | Params: `fields[betaTesters]`, `limit`. The response carries `meta.paging.total` (`PagingInformation`), so `limit=1` is enough. |
| Read a build's What to Test | `GET /v1/builds/{id}/betaBuildLocalizations` | Params: `fields[betaBuildLocalizations]`, `limit`. |
| Create What to Test | `POST /v1/betaBuildLocalizations` | |
| Update What to Test | `PATCH /v1/betaBuildLocalizations/{id}` | |

`xless ship` never deletes a group nor changes an existing one. `xless testflight` (#100) also uses
`PATCH`/`DELETE /v1/betaGroups/{id}` and the paths below.

## Testers, external testing and public links (`xless testflight`, `testflight.testers`, `testflight.external`)
| Purpose | Request | Notes |
|---|---|---|
| An app's (or a group's) testers | `GET /v1/betaTesters?filter[apps]=<app>[&filter[betaGroups]=<group>]&include=betaGroups` | `fields[betaGroups]=name`, `limit[betaGroups]=50`. |
| A tester by address | `GET /v1/betaTesters?filter[email]=<email>` | Compared again client-side without regard to case; addresses with a comma are refused (array filter). |
| Create a tester in a group | `POST /v1/betaTesters` | `BetaTesterCreateRequest`: `email*`, `firstName`, `lastName`, relationships `betaGroups`; sent once, a `409` is settled by looking the address up. |
| Add / remove testers of a group | `POST` / `DELETE /v1/betaGroups/{id}/relationships/betaTesters` | `[ {type: betaTesters, id} ]`. |
| Remove testers from an app | `DELETE /v1/apps/{id}/relationships/betaTesters` | Every group and build of the app. |
| Send an invitation again | `POST /v1/betaTesterInvitations` | Relationships `app*`, `betaTester`; no attributes. |
| Groups that have a build | `GET /v1/betaGroups?filter[app]=<app>&filter[builds]=<build>` | |
| Add / remove a build to groups | `POST` / `DELETE /v1/builds/{id}/relationships/betaGroups` | |
| Beta texts | `GET /v1/apps/{id}/betaAppLocalizations`, `POST /v1/betaAppLocalizations`, `PATCH /v1/betaAppLocalizations/{id}` | `feedbackEmail`, `marketingUrl`, `privacyPolicyUrl`, `description`, `locale` (create only). |
| Beta App Review details | `GET /v1/apps/{id}/betaAppReviewDetail`, `PATCH /v1/betaAppReviewDetails/{id}` | Read with `fields[betaAppReviewDetails]` without `demoAccountPassword`; no create (one per app). |
| Beta license agreement | `GET /v1/apps/{id}/betaLicenseAgreement`, `PATCH /v1/betaLicenseAgreements/{id}` | `agreementText`. |
| Beta app review | `GET /v1/betaAppReviewSubmissions?filter[build]=<build>`, `POST /v1/betaAppReviewSubmissions` | Relationship `build*`; `betaReviewState`: `WAITING_FOR_REVIEW`, `IN_REVIEW`, `REJECTED`, `APPROVED`. |
| Public link | `PATCH /v1/betaGroups/{id}` | `publicLinkEnabled`, `publicLinkLimitEnabled`, `publicLinkLimit`; the response's `publicLink` is the URL. |

Not verified against a real account: internal testers created with `POST /v1/betaTesters` (fastlane and the open-source
`asc` CLI do it for App Store Connect users), the `409` wording on a duplicate tester, `DELETE` on an app's testers,
the invitation endpoint for internal testers, the beta review states after submission, `publicLink` in the `PATCH`
answer.

## BetaGroupCreateRequest
`data { type: "betaGroups", attributes { name*, isInternalGroup?, hasAccessToAllBuilds?, publicLinkEnabled?, publicLinkLimitEnabled?, publicLinkLimit?, feedbackEnabled? }, relationships { app* { data { type: "apps", id } }, builds?, betaTesters? } }`

xless sends `name`, `isInternalGroup: true`, `hasAccessToAllBuilds: true` and the `app` relationship. `hasAccessToAllBuilds: true`
is the "automatic distribution" setting: every build of the app is delivered to the group.

## BetaGroup (response) attributes
`name`, `createdDate`, `isInternalGroup`, `hasAccessToAllBuilds`, `publicLinkEnabled`, `publicLinkId`, `publicLinkLimitEnabled`,
`publicLinkLimit`, `publicLink`, `feedbackEnabled`, `iosBuildsAvailableForAppleSiliconMac`, `iosBuildsAvailableForAppleVision`.

`BetaGroupUpdateRequest` has no `isInternalGroup` and no `hasAccessToAllBuilds`: neither can change after creation. An existing
external group therefore cannot be turned into an internal one, and xless refuses to deliver to one instead of touching it.

## BetaGroupBuildsLinkagesRequest
`data [ { type: "builds", id } ]` (both required).

## BetaBuildLocalization
- Create: `data { type: "betaBuildLocalizations", attributes { locale*, whatsNew? }, relationships { build* { data { type: "builds", id } } } }`
- Update: `data { type: "betaBuildLocalizations", id, attributes { whatsNew? } }` (`locale` cannot be changed)
- Response attributes: `whatsNew`, `locale`.

xless looks the build's localizations up first and updates the one whose `locale` equals `testflight.locale` (default `en-US`);
otherwise it creates one. The first call is needed because App Store Connect may already hold a localization for the build.

## Error mapping
All calls run inside the upload stage's error wrapper, so every failure prints `[upload] <step>: <cause> — <fix>` and exits 17.
401/403 get the API-key hints; 429/5xx are retried (at most 5 attempts) except group creation (single attempt, so a retry cannot
leave a duplicate group). The fix text always says the build itself is already uploaded and processed.

## Not verifiable from the spec
- Whether `POST .../relationships/builds` on a group with `hasAccessToAllBuilds: true` is accepted or answers `409` because the
  build is already there. For automatic-distribution groups xless treats `409` and `422` as "check membership" (bounded query above) and, if still unconfirmed, warns that the build will appear via automatic distribution. Other groups keep the error.
- Internal testers are App Store Connect users of the team: xless checks the address against `/v1/users` (Admin key)
  before it adds one to an internal group, and otherwise lets Apple decide.
