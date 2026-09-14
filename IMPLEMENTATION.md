# Implementation notes

## Agreed direction

Build a small native macOS app in this repository. Reuse the useful CodexBar UI patterns without carrying its provider authentication, scraping, and polling infrastructure. Connect to the user's installed T3 Code without changing T3 Code or CLIProxyAPI.

LocalFlare needs no changes for the first version. A shared cache is deferred. Each T3 server has its own snapshot; subscribing to an existing snapshot does not consolidate polling across separate T3 servers.

## Source inspection

These findings were inspected against T3 Code commit `211618fd9fe39d3dde01171a6856ce9f633571c9`. Recheck against the installed version before implementing.

- [UsageLimitSources](https://github.com/pingdotgg/t3code/blob/211618fd9fe39d3dde01171a6856ce9f633571c9/apps/server/src/usage/UsageLimitSources.ts) holds external source snapshots in memory and publishes the current set followed by changes.
- [RPC contract](https://github.com/pingdotgg/t3code/blob/211618fd9fe39d3dde01171a6856ce9f633571c9/packages/contracts/src/rpc.ts) exposes `subscribeServerConfig` with the `usageLimitSources` capability flag.
- [Usage contracts](https://github.com/pingdotgg/t3code/blob/211618fd9fe39d3dde01171a6856ce9f633571c9/packages/contracts/src/providerUsageLimits.ts) describe account windows, timestamps, unavailable states, and reset credits.
- [Environment authentication](https://github.com/pingdotgg/t3code/blob/211618fd9fe39d3dde01171a6856ce9f633571c9/docs/internals/environment-auth.md) describes pairing, bearer sessions, and WebSocket tickets.

The authenticated connection has been tested against the installed server. It supplies one Claude CPA account with session, weekly and Fable windows, and two Codex CPA accounts with weekly limits and reset credits.

## Connection

1. Locate the configured T3 server. Desktop normally starts at loopback port 3773 and scans upward when it is occupied. Verify the environment identity using `/.well-known/t3/environment` before sending credentials.
2. Invoke the installed T3 desktop app's bundled `pair` CLI when the user clicks Connect. Exchange its credential for `orchestration:read orchestration:operate` and store the resulting bearer token in Keychain. Operate is required for the ten-minute stale-data refresh; the separate `.operate` Keychain service requires explicit re-pairing when upgrading from the read-only version.
3. Exchange the credential through `POST /oauth/token`, then obtain a ticket through `POST /api/auth/websocket-ticket`.
4. Connect to `/ws?wsTicket=...` and subscribe to server configuration with `usageLimitSources: true`.
5. Read the initial native provider state and subsequent provider updates, together with `usageLimitSourcesUpdated` for CPA accounts.

T3 uses Effect RPC with JSON serialization. Implement only the required request, chunk acknowledgement, heartbeat, and error handling. Confirm the exact framing against the installed release before building the UI around it.

The minimum read scope is broader than quota access: it also permits reading environment files and threads. The app should use only quota-related data and must never log tokens or unrelated configuration payloads.

Bearer sessions default to 30 days. A consumed pairing credential cannot simply be exchanged again. Handle expiration with an explicit re-pair flow unless T3 provides a supported renewal mechanism. Reconnection needs a new WebSocket ticket.

Review confirmed that subscribing triggers T3's native-provider probe. Reconnection therefore uses a one-minute minimum backoff, capped at five minutes. Authorization and incompatible-payload failures stop automatic retries. CPA polling itself follows T3's foreground/background activity policy; this app does not send activity leases.

## Display behavior

Keep every account distinct. Show percentages remaining, derived from `100 - usedPercent`, and preserve separate session, weekly, and model-specific windows.

Never substitute the general weekly limit for a missing Fable limit. Show that the Fable value is unavailable. Preserve last-known good values with a visible stale indicator when T3 disconnects or a probe fails. Do not present an old value as fresh.

T3's source contract currently includes reset-credit count and the next expiry, not the full list of credit expiry dates shown in the CodexBar reference. Display only the information available. Credit redemption is outside the initial display-only scope.

Reserve and headroom are estimates, not upstream quota fields. Inspect the relevant CodexBar calculations before deciding which can be reproduced accurately from T3's window data. Do not invent a plan multiplier or window start time when the source does not supply it.

Status-page links are straightforward. Verify the current public status APIs before adding a cached status submenu. Keep provider-status failures separate from quota freshness.

## First-build completion checks

- Build a runnable macOS app locally.
- Pair with the installed T3 Code through its normal authorization flow.
- Show both Codex accounts and Claude session, weekly, and Fable windows using actual T3 data.
- Compare the dropdown values and reset times with T3's own display.
- Confirm that reading quota snapshots does not call quota-refresh or credit-redemption methods.
- Verify reconnection after T3 restarts and visible stale state while T3 is unavailable.
- Retain license notices for all borrowed CodexBar code and assets.
- Document local build and installation commands before publishing a binary.
