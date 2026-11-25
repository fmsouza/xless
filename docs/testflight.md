# Invite testers

A build reaches its testers through TestFlight groups. `xless run` uploads a build and delivers it to the groups that
`testflight:` in `xless.yml` or the overlay names ([xless-yml.md](xless-yml.md#testflight)); it prints how many testers of each
group have it. Every option is in [`xless testflight`](apple-account.md#xless-testflight) and
[`xless users`](apple-account.md#xless-users).

## Internal testers

Up to 100, every build at once, no review. They must be App Store Connect users of the team. Invite
them with an Admin key, then add them to a group once they accepted Apple's email:

```sh
xless users invite ada@example.com --first-name Ada --last-name Lovelace --role developer --app com.example.app
xless users invitations list                       # until Ada accepts
xless testflight testers add ada@example.com --group Internal --app com.example.app
```

Or list them in `xless.yml`, and every `xless ship` adds the missing ones to its groups:

```yaml
testflight:
  groups: [Internal]
  testers: [ada@example.com]
```

## External testers

Anyone; Apple emails them once beta app review approved the build:

```sh
xless testflight groups create "Public Beta" --external --app com.example.app
xless testflight testers add grace@example.com --group "Public Beta" --app com.example.app
xless testflight builds add 1.0+42 --group "Public Beta" --app com.example.app
xless testflight beta-review submit 1.0+42 --app com.example.app
xless testflight public-link enable "Public Beta" --app com.example.app --limit 500   # or a link to share
```

`testflight.external` in `xless.yml` does the same at every ship, with the beta information and review contact
([xless-yml.md](xless-yml.md#testflight)).

Next: [release the version](release.md).
