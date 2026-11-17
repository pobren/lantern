# Lantern

A calm, native Mac mail app for Fastmail, built on JMAP. It also works with Mail App and any other JMAP server.

## What's in version 0.1

- **Today**: your inbox sorted into three piles. Needs you (real people), updates and receipts, and reading for later.
- **People**: email as conversations, one person at a time, with quoted replies trimmed away.
- **Focus**: one unread email at a time in a dark room, with keyboard keys for reply (R), done (E), later (L), skip (S) and read (Space).
- **Inbox**: the plain list, for when you want it.
- Send from any of your addresses across accounts, reply, archive, star and delete.
- New mail arrives instantly over JMAP push.
- Tokens are kept in the Mac's keychain. Mail goes straight from your Mac to your provider; there is no Lantern server.

## How it's built

- SwiftUI for macOS 14 and later, no third party code.
- `apps/project.yml` is an XcodeGen project; the Xcode project is generated in CI.
- `.github/workflows/check.yml` checks every Swift file parses on each push (Linux, cheap).
- `.github/workflows/testflight.yml` builds, signs and sends the app to TestFlight when a commit message starts with `[testflight]`, or by hand from the Actions tab. It needs the secrets `ASC_KEY`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `APPLE_TEAM_ID`.

## Signing in

Lantern signs in with an API token. In Fastmail, go to Settings, then Privacy and security, then Manage API tokens, and make a new token with access to Email and Email submission.

## Licence

Business Source License 1.1. See [LICENSE](LICENSE). Lantern is not affiliated with Fastmail.
