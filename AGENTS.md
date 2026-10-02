# AGENTS.md — Claude Tray Monitor

macOS menu-bar app (Swift Package Manager, `LSUIElement`) that shows Claude plan usage (5-hour / 7-day bars) in the tray. No third-party dependencies; AppKit + SwiftUI, built ad-hoc (unsigned).

## Build & run

- `make build` — release build (verify after every change)
- `make bundle` — produce `build/Claude Tray Monitor.app`
- `make install` — bundle, then copy to `~/Applications/Claude Tray Monitor.app` (overwrites the old copy, quits the running one, relaunches). **Run after every build.**
- `make run` — run from source
- Logs: `~/Library/Logs/ClaudeTrayMonitor/requests.log` (main way to see refresh chain results)
- No test target; verification = clean build + live log.

## Architecture / key files (Sources/ClaudeTrayMonitor/)

- `Poller.swift` — refresh chain: **Desktop session first**, then OAuth fallback with token refresh on 401, force-refresh on settings changes. If the desktop usage response lacks `spend` (Enterprise orgs return `five_hour`/`seven_day` with `utilization: 0` and `spend: null`), probes OAuth candidates for `api.anthropic.com/api/oauth/usage` monthly spend (logs `monthly spend via <source>`).
- `UsageParser.swift` — `parseSpend` reads top-level `spend` (`used`/`limit` as `amount_minor`/`exponent` → dollars) with `extra_usage` (`used_credits`/`monthly_limit`/`decimal_places`) fallback. Enterprise tray = single column: used over limit (compact `$247` / `$1k`), fill = `spend.percent`; `showMonthlySpend` setting (default on) controls auto-switch.
- `DesktopSession.swift` — reads & decrypts the `sessionKey` cookie from Claude Desktop's Chromium cookie DB and fetches usage from `https://claude.ai/api/organizations/{org}/usage` (separate rate bucket from api.anthropic.com).
- `OAuthRefresher.swift` — refresh-token rotation against `POST https://platform.claude.com/v1/oauth/token`; legacy fallback `https://console.anthropic.com/v1/oauth/token` on 404/405.
- `Credentials.swift` — keychain enumeration (`Claude Code-credentials*`, `claude-swap`), token candidates, write-back of rotated tokens.
- `UsageAPI.swift` — OAuth + web endpoints, UA constants (see nuance below).
- `ProcessRunner.swift` — timeout-bounded subprocess runner; ALL `security`/`sqlite3` calls go through it.
- `Accounts.swift` — `AccountSelection` (`auto` / `oauth` / pinned `"<profileDir>|<orgId>"`, stored in `selectedAccountId`) and `AccountStore` (Desktop profiles × `/api/organizations`, cached 10 min). Tray right-click ▸ Account and Settings ▸ Account switch it; a pinned account never falls back to another login (error instead). Settings can rename (`accountNames` id→name, relabels the current snapshot locally — no refetch) and hide (`hiddenAccountIds`; signed-out profiles use `profile:<dir>`) accounts; hiding the selected one switches to Auto.
- `AppSettings.swift` + `Views/SettingsView.swift` — `manualProfileDirs` (user-added Desktop profile folders); legacy `desktopDataDir` is migrated into it and pinned on launch.

## Critical nuances (learned the hard way)

- **Refresh tokens are single-use.** A successful refresh rotates BOTH access and refresh token. If you lose the 200 body (truncated curl output), the old refresh token dies permanently (`invalid_grant`). Never print/handle refresh responses casually.
- **WAF blocks default User-Agents** on api.anthropic.com: plain curl → 429, `axios/1.7.9` → 400. The app UA `claude-tray-monitor/<version>` works. Never "test" API calls with a foreign UA.
- **Version lives in 3 places** — keep in sync on every bump:
  1. `Resources/Info.plist` → `CFBundleShortVersionString` + `CFBundleVersion` (build number = minor+1… actually numeric, e.g. 4)
  2. `Sources/ClaudeTrayMonitor/UsageAPI.swift` → `userAgent` string
  3. `Views/SettingsView.swift` → footer text
- **Never run subprocesses on the main thread.** `security` calls (e.g. `Claude Safe Storage`) can block on an ACL prompt → app hang (1656 blocked frames seen in a profile). Always `ProcessRunner` in a detached task with timeout (~15s).
- **`--user-data-dir` contains spaces** (`…/Application Support/Claude-Personal`). Never split `ps` output on spaces to read it — take the value up to the next ` --` (`DesktopSession.userDataDir(fromCommand:)`). The space-split bug made auto-detect silently fall back to the `Claude` (Enterprise) profile. Main Desktop process = `pgrep -x Claude` (CLI subprocesses are lowercase `claude`).
- **Windows**: not supported (AppKit). Profile paths/process name sit behind `ProfileLocator` (`%APPDATA%\Claude*` stub); a port also needs DPAPI cookie-key decryption instead of the Keychain + PBKDF2 recipe.
- **sqlite3 CLI** must be invoked with `-separator "\t"` (default `|` breaks cookie-row parsing).
- **Cookie decryption recipe**: key = PBKDF2-HMAC-SHA1(keychain item `Claude Safe Storage`/`Claude Key`, salt `saltysalt`, 10003 iters, 16 B) → AES-128-CBC, IV 16×`0x20`, ciphertext `v10`-prefixed; plaintext starts with 32-byte tag to skip.
- **Desktop cookie DB locations** (Auto mode, in order): the running Claude Desktop's `--user-data-dir` (via `ps -o command=`; skipped on main thread), then `~/Library/Application Support/Claude`, then other `Claude-*` dirs, probing both `Cookies` and `Default/Cookies`. Manual profiles + explicit account selection override auto-detect. Modern Claude Desktop (2026+) uses the `Claude` profile; `Claude-Personal` is the old 2025 personal-account profile — picking it first shows the wrong (stale subscription) session when both exist.
- **Source priority**: Claude Desktop session (fast ~2s, own rate bucket) → OAuth candidates with 401-triggered refresh → write rotated tokens back to keychain.
- **Plan label must come from the same source as the limits.** With mixed personal + Enterprise Desktop sessions running, env-based detection (`CLAUDE_CODE_SUBSCRIPTION_TYPE` in `ps eww`) is unreliable: `pgrep -f claude.app/Contents/MacOS/claude` is case-sensitive and only matches Desktop-*spawned CLI* subprocesses, not the main `MacOS/Claude` binary, and multiple sessions' spawns can coexist. Derive the label from the org the usage was actually queried for: `/api/organizations` items carry `billing_type` (`stripe_subscription` → Pro; `stripe_subscription_contracted` → Enterprise; others → fall back to env/OAuth profile).
- **Keychain ACL**: reading `Claude Safe Storage` may surface a one-time macOS prompt; on some macOS versions it doesn't prompt at all. Handle both silently (timeout + fallback to OAuth).

## Release flow (bump → commit → publish)

1. Bump version in the 3 places above (plist short string + numeric build, UA, footer).
2. `make build` to verify, then `make install`.
3. `git add -A && git commit` (message style: short imperative, e.g. "Add X, bump to 0.4.0") and `git push`.
4. `make publish` — builds DMG + zip, then `gh release create` for `v<version>` on `yumedzi/claude-tray-monitor` (deletes + recreates the tag if it already exists). Confirmed by printed release URL.
5. Sanity check: relaunch app from `build/Claude Tray Monitor.app`, confirm `refresh ok via Claude Desktop session` in the log.
