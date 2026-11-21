# Sign in with Fastmail

JMAP Connect signs in to Fastmail with OAuth (PKCE, no client secret). Fastmail needs no registration for native apps:
our client id is the address of a small JSON file (an OAuth Client ID Metadata Document) that names the app, its icon
and the one address Fastmail may send people back to (`app.jmapconnect:/oauth/fastmail`).

- Live client id: https://jmapconnect.app/oauth/client.json (paulobrien-site, `jmapconnect-site/public/oauth/client.json`).
- `client-test.json` here is the same file at a GitHub address, used only to test before the live file is published.
  A build can point at it with `JCOAuthClient` in Info.plist.

App code: `apps/Shared/OAuth.swift`.
