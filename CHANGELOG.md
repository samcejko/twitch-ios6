# Changelog

## 0.2.0 (2026-10-14)

- A second build for 64-bit devices with iOS 14–17 (iPhone X and newer), from the same source tree: the `.deb` with
  `iphoneos-arm64` in its name for rootless jailbreaks (palera1n, Dopamine; it installs into `/var/jb`) and
  `Twitcher-<version>-arm64.ipa` for TrollStore. Tried on an iPhone X with iOS 16.
- On iOS 7 and newer the app draws the glossy iOS 6 bars, the black glass tab bar, bordered bar buttons and rounded
  grouped tables itself, stays in light mode and opens the player full screen, so it looks the same as on the iPad 2.
  The player's controls and the chat keep clear of the notch and the home indicator.
- The 32-bit build gets the same look on devices with iOS 7–10.
- The chat thread no longer crashes when the connection drops (an error object was released too early; iOS 16
  crashed on it, iOS 6 was merely lucky).

## 0.1.2 (2026-10-14)

- Settings → About has a "Support the development" row that opens the author's Ko-fi page. The app stays free.
- Twitcher is in the repository `http://repo.samcejko.eu/` now (Cydia, Sileo, Zebra, Installer): add it as a source to get updates.

## 0.1.1 (2026-10-03)

- Links (chat, the login's activation page) now open through an "Open in..." chooser offering Safari and, when it is
  installed, Surfari - the iOS 6 browser of this family. (The old build used a stale URL scheme and always fell back
  to Safari.)

## 0.1.0 (2026-10-03)

First version: live streams with chat, past broadcasts with the chat replay, clips, categories, search,
favourites, optional Twitch login (followed channels, sending messages), quality choice, background sound,
light and dark theme, English and Czech. Other apps can open content with the `twitcher:` URL scheme
(`channel/<login>`, `watch/<login>`, `video/<id>`, `clip/<slug>`).
