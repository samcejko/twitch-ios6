# Changelog

## 0.1.2 (2026-10-14)

- Settings → About has a "Support the development" row that opens the author's Ko-fi page. The app stays free.
- Twitcher is in the Cydia repository `http://samcejko.eu/repo/` now: add it as a source in Cydia to get updates.

## 0.1.1 (2026-10-03)

- Links (chat, the login's activation page) now open through an "Open in..." chooser offering Safari and, when it is
  installed, Surfari - the iOS 6 browser of this family. (The old build used a stale URL scheme and always fell back
  to Safari.)

## 0.1.0 (2026-10-03)

First version: live streams with chat, past broadcasts with the chat replay, clips, categories, search,
favourites, optional Twitch login (followed channels, sending messages), quality choice, background sound,
light and dark theme, English and Czech. Other apps can open content with the `twitcher:` URL scheme
(`channel/<login>`, `watch/<login>`, `video/<id>`, `clip/<slug>`).
