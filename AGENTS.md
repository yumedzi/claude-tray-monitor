# AGENTS.md — Claude Tray Monitor

macOS menu-bar app (Swift Package Manager, `LSUIElement`) that shows Claude plan usage (5-hour / 7-day bars) in the tray. No third-party dependencies; AppKit + SwiftUI, built ad-hoc (unsigned).

## Build & run

- `make build` — release build (verify after every change)
- `make bundle` — produce `build/Claude Tray Monitor.app`
- `make run` — run from source
- Logs: `~/Library/Logs/ClaudeTrayMonitor/requests.log` (main way to see refresh chain results)
- No test target; verification = clean build + live log.

## Architecture / key files (Sources/ClaudeTrayMonitor/)

- `Poller.swift` — refresh chain: **Desktop session first**, then OAuth fallback with token refresh on 401, force-refresh on settings changes.
- `DesktopSession.swift` — reads & decrypts the `sessionKey` cookie from Claude Desktop's Chromium cookie DB and fetches usage from `https://claude.ai/api/organizations/{org}/usage` (separate rate bucket from api.anthropic.com).
- `OAuthRefresher.swift` — refresh-token rotation against `POST https://platform.claude.com/v1/oauth/token`; legacy fallback `https://console.anthropic.com/v1/oauth/token` on 404/405.
- `Credentials.swift` — keychain enumeration (`Claude Code-credentials*`, `claude-swap`), token candidates, write-back of rotated tokens.
- `UsageAPI.swift` — OAuth + web endpoints, UA constants (see nuance below).
- `ProcessRunner.swift` — timeout-bounded subprocess runner; ALL `security`/`sqlite3` calls go through it.
- `AppSettings.swift` + `Views/SettingsView.swift` — `desktopDataDir` setting (empty = auto-detect), change triggers refresh.

## Critical nuances (learned the hard way)

- **Refresh tokens are single-use.** A successful refresh rotates BOTH access and refresh token. If you lose the 200 body (truncated curl output), the old refresh token dies permanently (`invalid_grant`). Never print/handle refresh responses casually.
- **WAF blocks default User-Agents** on api.anthropic.com: plain curl → 429, `axios/1.7.9` → 400. The app UA `claude-tray-monitor/<version>` works. Never "test" API calls with a foreign UA.
- **Version lives in 3 places** — keep in sync on every bump:
  1. `Resources/Info.plist` → `CFBundleShortVersionString` + `CFBundleVersion` (build number = minor+1… actually numeric, e.g. 4)
  2. `Sources/ClaudeTrayMonitor/UsageAPI.swift` → `userAgent` string
  3. `Views/SettingsView.swift` → footer text
- **Never run subprocesses on the main thread.** `security` calls (e.g. `Claude Safe Storage`) can block on an ACL prompt → app hang (1656 blocked frames seen in a profile). Always `ProcessRunner` in a detached task with timeout (~15s).
- **sqlite3 CLI** must be invoked with `-separator "\t"` (default `|` breaks cookie-row parsing).
- **Cookie decryption recipe**: key = PBKDF2-HMAC-SHA1(keychain item `Claude Safe Storage`/`Claude Key`, salt `saltysalt`, 10003 iters, 16 B) → AES-128-CBC, IV 16×`0x20`, ciphertext `v10`-prefixed; plaintext starts with 32-byte tag to skip.
- **Desktop cookie DB locations** (in order): `$HOME/Library/Application Support/Claude-Personal` then `Claude` (older layout), probing both `Cookies` and `Default/Cookies`. Setting `desktopDataDir` overrides auto-detect.
- **Source priority**: Claude Desktop session (fast ~2s, own rate bucket) → OAuth candidates with 401-triggered refresh → write rotated tokens back to keychain.
- **Keychain ACL**: reading `Claude Safe Storage` may surface a one-time macOS prompt; on some macOS versions it doesn't prompt at all. Handle both silently (timeout + fallback to OAuth).

## Release flow (bump → commit → publish)

1. Bump version in the 3 places above (plist short string + numeric build, UA, footer).
2. `make build` to verify.
3. `git add -A && git commit` (message style: short imperative, e.g. "Add X, bump to 0.4.0") and `git push`.
4. `make publish` — builds DMG + zip, then `gh release create` for `v<version>` on `yumedzi/claude-tray-monitor` (deletes + recreates the tag if it already exists). Confirmed by printed release URL.
5. Sanity check: relaunch app from `build/Claude Tray Monitor.app`, confirm `refresh ok via Claude Desktop session` in the log.
