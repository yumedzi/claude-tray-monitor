# Claude Tray Monitor

A native macOS menu-bar app that shows your Claude rate limits at a glance —
two slim vertical bars with your current usage, refreshed on a gentle,
configurable schedule.

<p align="center">
  <img src="assets/screenshot.png" alt="Claude Tray Monitor screenshot" width="720">
</p>

Inspired by [_usage-monitor-for-claude_](https://github.com/jens-duttke/usage-monitor-for-claude)
(Windows) and informed by the API/credential logic of the author's VS Code
extension _claude-context-monitor_.

## Features

- **Vertical or horizontal bars** in the menu bar — switch orientation in
  Settings (`55 || 44` / `s || w` in vertical, two stacked bars with
  marker + value rows in horizontal).
- **Adaptive tray width**: the tray item shrinks to just its bars when labels
  and percentages are hidden, freeing menu-bar space.
- **Pick the quota windows to display** (session, weekly, weekly Sonnet / Opus /
  Fable, and any new ones Anthropic adds) for either bar.
- **Percentages & labels on/off**: show the numbers, and independently show the
  `s`/`w` markers. Without labels, values center against the bars.
- **Auto label color**: labels render black on a light menu bar, white on a
  dark one — no manual color setting.
- **Color-coded limits**: green / orange (warning) / red (error), with
  configurable thresholds.
- **Follows macOS light/dark theme** automatically — or pin it to light/dark
  in Settings (a feature the original Windows app does not have).
- **Configurable polling interval: 1–60 minutes** via a slider in the UI.
  One network request per interval, no more, with built-in 429 throttling.
- **Left-click popover**: all detected quota windows with reset countdowns,
  plan label, FRESH/STALE status badge, and an instant reload button.
- **Popover footer** lists the last update time and credential source, with
  **Settings** and **Exit** buttons.
- **Right-click menu**: Check Now, Settings, Quit.
- **Zero configuration**: works out of the box with a logged-in **Claude
  Desktop**, reading the session cookie straight from the desktop app's local
  profile (`Claude-Personal` or `Claude` under `~/Library/Application Support`).
  If you don't use the desktop app, it falls back to your Claude Code Keychain
  login (`Claude Code-credentials`), auto-refreshing expired OAuth access
  tokens and rotating them back to the keychain.
- **Configurable Desktop profile path**: if your desktop app keeps its profile
  in a non-standard location, point Settings → Claude Desktop → Profile
  directory at it (or use Browse…); empty = auto-detect.
- **Low memory footprint**: native AppKit, no Electron, no webviews, no
  runtime. Idles around 40 MB RSS; SwiftUI is only loaded when the popover or
  settings window is open.

## Requirements

- macOS 14 (Sonoma) or later
- A logged-in Claude app — Claude Desktop is auto-detected; Claude Code CLI /
  VS Code logins are used as a fallback credential source.

## Install

Download the latest `ClaudeTrayMonitor-macos.dmg` from
[Releases](https://github.com/yumedzi/claude-tray-monitor/releases), open it, and
drag **Claude Tray Monitor.app** into your Applications folder (or download the
`ClaudeTrayMonitor-macos.zip` archive and move the app to Applications).

The release is ad-hoc signed; on first launch you may need to right-click the
app and choose **Open** (or run
`xattr -dr com.apple.quarantine "Claude Tray Monitor.app"`). To remove, simply
delete the app.

> **Why the Gatekeeper warning?** This project is free, ad-hoc signed, and not
> notarized — signing + notarizing so macOS trusts the app for *every* Mac
> requires the paid $99/year Apple Developer Program and a Developer ID
> certificate. The DMG itself requires no Apple ID, but first-time users see
> the right-click → Open confirmation once.

## Build from source

```sh
make bundle        # builds release binary and assembles the .app
open "build/Claude Tray Monitor.app"   # or double-click it
make run           # run in place with `swift run`
make dmg           # produce build/ClaudeTrayMonitor-macos.dmg (installer)
make release       # produce build/ClaudeTrayMonitor-macos.zip
make publish       # build + upload DMG/zip to a GitHub Release (requires gh + auth)
```

## How it works

The app reads your usage straight from your Claude account, trying two
data sources in order:

1. **Claude Desktop session** (default): it decrypts the `sessionKey` cookie
   from the desktop app's local Chromium profile (using the `Claude Safe
   Storage` key in your login keychain), then queries
   `claude.ai/api/organizations/…/usage` — the same endpoint the Claude.ai web
   UI uses. This needs no OAuth tokens and has its own rate-limit bucket.
2. **Claude Code OAuth** (fallback): it polls
   `api.anthropic.com/api/oauth/usage` and `/api/oauth/profile` with your
   existing Keychain credentials. If the stored access token is expired or
   rejected, the app refreshes it against `platform.claude.com/v1/oauth/token`
   and writes the rotated tokens back to the Keychain.

If the first credential slot is rejected (e.g. after an account switch), the
app moves to the next stored entry automatically, so monitoring keeps
following your active Claude account.

## Security

- **Single network destination**: `api.anthropic.com` (OAuth usage/profile) or
  `claude.ai` (desktop session usage) only.
- **Credentials stay local**: tokens and cookies are used only in HTTP
  `Authorization`/`Cookie` headers and decrypted in memory — never logged,
  never stored in app settings, never sent elsewhere.
- **First-run Keychain prompt**: reading the desktop session key asks macOS to
  allow **Claude Tray Monitor** access to the `Claude Safe Storage` keychain
  item (the desktop app's own encryption key) — approve it once with
  "Always Allow". Until then, the app silently falls back to the Claude Code
  OAuth route.
- **No files written**: settings live in standard `UserDefaults`; no secrets
  are persisted by the app. Launch-at-Login uses `SMAppService`.
- **No obfuscation**: small, readable modules; your token never appears in the
  UI or tooltips.

## License

[MIT](LICENSE). Independent, community-built project — not created, endorsed,
or officially supported by Anthropic. "Claude" and "Anthropic" are trademarks
of Anthropic, PBC, used here solely to indicate compatibility.