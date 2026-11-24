# M7 acceptance app

The app [#105](https://github.com/fmsouza/xless/issues/105) takes from zero to the App Store on a real account, driven
by [`scripts/acceptance-m7.sh`](../../scripts/acceptance-m7.sh) ([docs/acceptance-m7.md](../../docs/acceptance-m7.md)).
A one-screen SwiftUI iOS app that needs a capability (push notifications: `ios.entitlements`), with an
[`appstore/`](appstore) listing in two languages (en-US, pt-BR), screenshots for the iPhone 6.9" and iPad 13" displays,
App Privacy ("Data Not Collected"), a free price and every territory but China mainland (its
declarations have no API).

Placeholders, replaced by the script in its own copy of this directory (never here):

| Placeholder | Where | Replaced by |
|---|---|---|
| `com.example.xless.m7` | `xless.yml`, `appstore/app.yml` | `XLESS_M7_BUNDLE_ID` (default: a new `dev.xless.m7.<random>`, never registered) |
| `ABCDE12345` | `xless.yml` | `XLESS_M7_TEAM` |
| `XLESSM7SKU` | `appstore/app.yml` | `XLESS_M7_SKU` (default: from the bundle ID) |
| `xless M7 Acceptance` | `appstore/*/name.txt` | `XLESS_M7_APP_NAME` (App Store names are unique: default adds the random part) |
| the review contact | `appstore/app.yml` | `XLESS_M7_CONTACT_FIRST`, `_LAST`, `_PHONE`, `_EMAIL` |

The icon and the screenshots are drawn by `make-images.py` (Python's standard library only): run it again after
changing it. `PRIVACY.md` is the privacy policy the listing links to.
