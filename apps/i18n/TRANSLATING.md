# Translating JMAP Connect

JMAP Connect speaks English plus the 40 languages in `languages.json`. Every phrase lives in
`Shared/Localizable.xcstrings`, which `build_catalog.py` makes from:

- `keys.json`: every English phrase the apps show, found by `extract.py`
- `tr/<code>.json`: one file per language, `{ "English phrase": "translation" }`

## Each release

1. `python3 i18n/extract.py` (from `apps/`) to pick up new and changed phrases.
2. Translate the phrases that are new in `keys.json` into each `tr/<code>.json` (we use AI translation).
3. `python3 i18n/build_catalog.py` checks every translation and writes the catalog.

## Rules for translations

- Keep every placeholder: `%@` (a name, address or other text) and `%lld` (a whole number). If the word order
  needs them swapped, number them: `%1$@`, `%2$lld`.
- A phrase with one `%lld` may be given plural forms instead of one string:
  `{"one": "...", "other": "..."}`, plus `"few"`, `"many"`, `"two"` or `"zero"` where the language uses them.
- Leave these as they are: JMAP Connect, JMAP, Fastmail, Mail App, Stalwart, Thundermail, Mailbux, Cyrus, Gravatar,
  API, URL, and keyboard shortcuts such as (⇧⌘J).
- Apple's own names (Apple Watch, Apple Intelligence, iCloud Keychain, Focus, Settings, Home Screen, Lock Screen,
  Quick Look) and everyday mail words (Inbox, Archive, Drafts, Sent, Spam, Bin, Reply, Forward) use the words Apple
  uses in that language on iPhone and Mac.
- Friendly and plain, as Apple writes its own apps in that language; sentence case where the language has it.
- Keep it about as short as the English: buttons and Watch screens are small.
- Keep line breaks (`\n`) where the English has them.
