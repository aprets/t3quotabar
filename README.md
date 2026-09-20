# T3QuotaBar

An unofficial macOS menu-bar client for T3 Code usage limits.

Native macOS app. Requires macOS 14 or newer and a running local T3 Code desktop installation.

T3QuotaBar displays the quota information T3 Code already collects, including native provider accounts and accounts behind CLIProxyAPI. It reads T3's existing snapshots instead of polling provider quota endpoints itself.

<img src="Assets/Screenshot.png" alt="T3QuotaBar showing combined Claude and Codex usage in the macOS menu bar, with per-account quotas and provider status in the dropdown" width="360">

Account labels in this screenshot have been anonymized.

## Interface

- One menu-bar item with Claude and Codex readouts side by side.
- Claude Fable-specific percentages remaining, without a label: `48% / 80% / 100%`. All limits remain in the dropdown.
- A `5h! 18% / 22%` warning appears only for accounts with session remaining below 25%, preserving their relative account order. It disappears when no sessions are below 25%.
- Weekly percentages for every Codex account.
- “Show totals” above Reconnect switches each provider to a total, such as `225%` instead of `48% / 80% / 97%`. It becomes “Show per-account limits” to switch back. The choice persists across restarts and defaults to per-account. Totals add account percentages without plan weighting and describe remaining capacity now, not a shared reset period. Missing values appear as `+ ?`; low-session warnings stay per account.
- “Show reserve” switches the same windows to pace, with T3 Code’s glyphs: `↘12%` means 12 points under linear use through the window, `↗8%` means ahead of it, spending faster than the window elapses, and a gauge marks anything within 5 points as on pace. It becomes “Show limits” to switch back and also persists. With totals on, reserve shows the average across accounts rather than a sum, so it stays on a ±100 scale however many accounts you have. An untouched account shows `↘` alone and stays out of the average, since Claude reports no reset until something is used. Banked Codex reset credits appear as up to three pips along the bottom of the pace glyph, pooled in average mode. Pace also assumes the CPA balancer will redeem the soonest credit just before it expires: when that expiry lands before the natural reset, the window is judged as ending there, so an account being drained ahead of an imminent credit reads as on pace rather than ahead. Its card then shows “Banked reset in …” as the reset and moves the normal weekly reset to the pace line. Turn off balancer redemption and this reads optimistic.
- A dropdown with per-account cards, reset countdowns, data age, and available reset credits.
- Even-pace reserve estimates when T3 supplies the window duration.
- Provider status and links to the official status pages.

The interface uses copied [CodexBar](https://github.com/steipete/CodexBar) card views, progress bars, menu hosting, layout and icons. Its MIT license is bundled in the app, as is the ISC license for the [Lucide](https://lucide.dev) pace arrows T3 Code uses. [Source provenance](PROVENANCE.md) lists the exact upstream revision and adaptations for T3.

## Download

[Download T3QuotaBar for Apple Silicon](https://github.com/aprets/t3quotabar/releases/latest/download/T3QuotaBar-macOS-arm64.zip).

Every successful `main` build publishes a new [release](https://github.com/aprets/t3quotabar/releases) numbered by build, and the link above always resolves to the newest one. Downloads do not require a GitHub account and do not expire after 30 days.

Unzip it and move `T3QuotaBar.app` to Applications. These builds are ad-hoc signed, not notarized. If macOS blocks opening it, use **System Settings → Privacy & Security → Open Anyway** after attempting to launch. Updates may require connecting to T3 Code again because CI builds do not share a stable signing identity.

## Build and run

```sh
bash scripts/test.sh
bash scripts/build-app.sh
open dist/T3QuotaBar.app
```

Copy `dist/T3QuotaBar.app` to Applications to install. Click the menu-bar item, then **Connect to T3 Code**. The app invokes T3's bundled `pair` CLI and saves its bearer session in macOS Keychain. Upgrading from the read-only version requires pairing once for refresh permission. It supports T3 Code and T3 Code Alpha installed in `/Applications`, using the default `~/.t3` data directory.

To check the connection without printing account emails or credentials:

```sh
dist/T3QuotaBar.app/Contents/MacOS/T3QuotaBar --diagnose
dist/T3QuotaBar.app/Contents/MacOS/T3QuotaBar --check-reconnect
```

Add `--pair` for the first diagnostic connection. The app has no standalone window; both account cards and actions live in native menu-bar menus.

Builds are not notarized. No automatic updater or launch-at-login setting is included.
Use a stable signing certificate to retain Keychain access across rebuilds. Set `CODE_SIGN_IDENTITY` or put its fingerprint in the gitignored `.signing-identity` file. Without one, the build falls back to ad-hoc signing and requires pairing again after code changes. Background Keychain reads never display authorization dialogs. A blocked read stops reconnect attempts and asks you to connect explicitly.

## Data source

The integration pairs with an existing T3 Code server and subscribes to its authenticated WebSocket API. T3 Code must be running for fresh quota data. Its API is internal and may change between releases. The app requests `orchestration:read` and `orchestration:operate` because T3 requires operate permission for `server.refreshProviders`. These scopes also permit unrelated environment reads and changes; T3QuotaBar uses only quota/configuration subscriptions and provider refresh.

No CLIProxyAPI management key or provider login is needed by this app. Provider status is fetched separately from public status endpoints every five minutes.

Failed probes and disconnected sessions keep last-good data in memory. A dot in the menu bar and a warning in the dropdown mark stale values. Snapshots older than 20 minutes are also marked stale. Last-good data is not persisted across app restarts. Expired authorization requires clicking Connect again. Each T3 server still has its own cache; this app does not coordinate refreshes across machines.

T3's default background policy can pause CPA polling when its window is unfocused. T3QuotaBar checks snapshot age every 20 seconds while connected and requests a provider refresh when any displayed account is at least 10 minutes old. Fresh snapshots suppress requests; attempts have a 10-minute cooldown and never overlap. T3's untargeted refresh includes all native providers and CPA sources, so this does cause upstream traffic. Requests time out after two minutes; RPC failures pause automatic refresh with a message in the dropdown until reconnection. This does not coordinate refreshes across separate machines. T3QuotaBar does not change T3's background settings or submit activity leases. Reconnects back off from one to five minutes.

For a one-shot refresh diagnostic, run `dist/T3QuotaBar.app/Contents/MacOS/T3QuotaBar --check-refresh`. This explicitly refreshes providers even when snapshots are fresh.

Native and CPA entries with the same provider and email are shown once, preferring CPA. Missing Fable stays unavailable. Reset credits show the count and next expiry only, because T3 does not provide every expiry. No credit redemption is performed.

See [implementation notes](IMPLEMENTATION.md) for the inspected protocol, limitations, and first-build checks.

T3QuotaBar is an independent project and is not affiliated with T3 Code, OpenAI, or Anthropic.

## License

[MIT](LICENSE). Copied CodexBar code and assets retain their [original MIT notice](Sources/T3QuotaBar/Resources/CodexBar-LICENSE).
