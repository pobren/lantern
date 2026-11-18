# Lantern

A clean, fast, native mail app for Mail App and Fastmail, built on JMAP. One app for Mac, iPhone and iPad, and it works with any other JMAP server too.

## What's in version 0.3

- The layout people expect: folders on the left, conversations in the middle, the open conversation on the right. On iPhone the three columns become three screens.
- All inboxes together, or any folder of any account, with unread counts.
- Conversations: earlier emails fold to one line; open any of them.
- Reply, reply all and forward (with the original quoted), from any of your addresses.
- Archive, delete, move to a folder, star, mark as read or unread. Swipe on iPhone, right click or keyboard on Mac.
- Search, pull to refresh, and more mail as you scroll.
- Attachments open in Quick Look. Attach files (and photos on iPhone) when you write, or drag them in on Mac.
- Signatures per address, saved to your account so they match everywhere.
- New mail notifications and an unread badge. Instant on Mac while Lantern is open; on iPhone and iPad, background checks when iOS allows.
- Emails show as their senders designed them, with scripts blocked and pictures from the web optional.
- New mail arrives instantly over JMAP push.
- Tokens are kept in the keychain. Mail goes straight from your device to your provider; there is no Lantern server.

## How it's built

- SwiftUI for macOS 14 and iOS 17 and later, no third party code.
- `apps/project.yml` is an XcodeGen project; the Xcode project is generated in CI.
- `.github/workflows/check.yml` checks every Swift file parses on each push (Linux, cheap).
- `.github/workflows/testflight.yml` builds, signs and sends the apps to TestFlight when a commit message starts with `[testflight]` (both), `[testflight ios]` or `[testflight mac]`, or by hand from the Actions tab. It needs the secrets `ASC_KEY`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `APPLE_TEAM_ID`.

## Signing in

Lantern signs in with an API token. In Fastmail, go to Settings, then Privacy and security, then Manage API tokens, and make a new token with access to Email and Email submission.

## Licence

Business Source License 1.1. See [LICENSE](LICENSE). Lantern is not affiliated with Fastmail.
