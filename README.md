# Twitcher – Twitch for iOS 6

Universal (iPhone + iPad) Twitch client for **jailbroken iOS 6.x** devices (armv7, e.g. iPad 2).
Live streams with chat, past broadcasts with the chat replay, clips, categories, search, favourites – and an
optional Twitch login for the channels you follow and for writing in the chat. Drawn in the glossy iOS 6 look,
light and dark, English and Czech.

Why it is special: Twitch's servers only speak today's TLS, which the iOS 6 networking stack cannot negotiate.
The app ships its own TLS stack (Mbed TLS) and a tiny HTTP client, and the video goes to the system player
through a small HTTP server inside the app (127.0.0.1), which fetches the stream through that stack and cleans
the playlists of what the 2012 player does not know. No relay server, nothing leaves the device but the requests
to Twitch (and, for third-party emotes, to BetterTTV, FrankerFaceZ and 7TV).

## Features

- Live channels (top streams, by category, by language), categories, search for channels and categories
- Player with quality choice (automatic up to what the device decodes, source, 1080p … 160p, audio only),
  full screen, the chat next to or under the video, sound in the background, lock-screen controls
- Chat with badges, Twitch/BetterTTV/FrankerFaceZ/7TV emotes (animated ones too), colours, mentions,
  subscriptions and raids, moderation (deleted messages, timeouts), "new messages" when scrolled up
- Channel pages: past broadcasts, highlights, clips (by period), favourites kept on the device
- Videos with seeking, resume where you left off, and the chat replay in time with the video; clips
- Optional login (device code: you type a short code at twitch.tv/activate on any device): followed channels,
  sending chat messages, your own emotes in the picker
- Light and dark theme, English and Czech

Tested on an iPad 2 (iPad2,2) with iOS 6.1.3. The iPhone layout is implemented but has not been tried on a real iPhone yet.

## Logging in

Watching needs no account. Logging in (*Settings > Twitch account > Log In*) shows a code to type at
twitch.tv/activate on a computer or phone; the app never sees the password. The login goes through the Twitch
application "Samcejko iOS6 Client" (a *Public* client, so there is no secret), whose Client ID is in
`src/Twitch/TWConfig.h`. A fork can register its own at [dev.twitch.tv/console/apps](https://dev.twitch.tv/console/apps)
(category "Application Integration", client type **Public**, any OAuth redirect URL such as `http://localhost`).

## Installing on the device

1. Cydia: **AppSync Unified** (repo `https://cydia.akemi.ai/`) and **IPA Installer Console** (BigBoss),
   plus OpenSSH for the helper scripts.
2. Copy the `.ipa` to the device and run `ipainstaller -f Twitcher.ipa`, or use iFunBox / 3uTools.
   The `.deb` works too (`dpkg -i`, then `uicache`) and installs into `/Applications`.

## Building (GitHub Actions)

No Mac needed. Every push runs `.github/workflows/build.yml` on Ubuntu with Theos, the iOS 9.3 SDK
(deployment target 6.0) and Mbed TLS. Artifacts: `Twitcher-<version>.ipa` and a `.deb`.

Local helpers (Windows PowerShell, no git required; settings in `tools/local.json`):

```powershell
.\tools\gh-push.ps1 -Message "change"                   # push via REST API
.\tools\gh-build.ps1 -Download -Install                 # wait, fetch, install over SSH
.\tools\check-gql.ps1                                   # run every GraphQL query against the live API
. .\tools\ipad.ps1; Get-IPadCrashLogs; Get-IPadSyslog   # debugging
```

URL scheme (other apps, or `uiopen` over SSH): `twitcher:watch/<channel>` opens a stream, `twitcher:channel/<channel>`
a channel page, `twitcher:video/<id>` a past broadcast, `twitcher:clip/<slug>` a clip, `twitcher:search?q=<text>` a search.

Debugging over SSH: with a file named `debug` in the app's Documents folder (`Enable-TwitcherDebug` in
`tools/ipad.ps1`), `uiopen twitcher:snapshot` draws the app's windows and `twitcher:screen` grabs the real screen
(video included) into the app's `tmp/screen.png` (`Get-IPadScreen`), `twitcher:press?n=0` presses a button of the
alert or sheet on screen, `twitcher:press?title=<text>` a button, segment, switch row or list row with that text,
`twitcher:tab?n=1` switches tabs, `twitcher:back` pops the navigation stack and `twitcher:stats` logs the memory in
use. `/var/log/syslog` carries the app's log lines (`[Twitcher]`, `Get-TwitcherLog`).

## Project layout

- `src/Net` – Mbed TLS socket with resolver fallback, HTTP/1.1 client and connection pool, image loader,
  the local media proxy for the player
- `src/Twitch` – GraphQL and Helix clients, playback (tokens, playlists, device capabilities), login, chat
  connection and message parsing, emotes and badges, favourites
- `src/UI` – theme (drawn artwork), the tabs, grids and lists, channel and category pages, the player, the chat
- `vendor` – Mbed TLS config and platform glue (Mbed TLS is fetched at build time)
- `tools` – asset generator, PowerShell helpers, the GraphQL query check

## Privacy

Requests go straight from the device to Twitch; there is no server in between and no analytics. Third-party emotes
come from BetterTTV, FrankerFaceZ and 7TV (they learn the channel you watch; switch them off in Settings > Chat).
The login tokens are stored on the device only: in the Keychain when it is available, otherwise (typical for
fake-signed installs) in the app's preferences file inside its sandbox.

## License

[MIT](LICENSE), copyright (c) 2026 samcejko. Mbed TLS (Apache-2.0) and the Mozilla CA bundle from curl.se
(MPL-2.0) are downloaded at build time and included in the released packages under their own licenses, see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

This is an independent hobby project, not affiliated with Twitch or Apple. Twitch is a trademark of Twitch
Interactive, Inc.
