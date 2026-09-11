# T3QuotaBar

An unofficial macOS menu-bar client for T3 Code usage limits.

Status: initial project setup. The app is not implemented yet.

T3QuotaBar will display the quota information T3 Code already collects, including native provider accounts and accounts behind CLIProxyAPI. It will read T3's existing snapshots instead of polling provider quota endpoints itself.

## Planned interface

- Separate Claude and Codex menu-bar items with configurable visible windows.
- Claude session, weekly, and Fable-specific percentages remaining.
- Weekly percentages for every Codex account.
- A dropdown with per-account cards, reset countdowns, data age, and available reset credits.
- Reserve and headroom estimates where the source data supports them.
- Provider status and links to the official status pages.

The interface will borrow relevant patterns from [CodexBar](https://github.com/steipete/CodexBar). Any copied code or assets must retain their original license notices.

## Data source

The planned integration pairs with an existing T3 Code server and subscribes to its authenticated WebSocket API. T3 Code must be running for fresh quota data. Its API is internal and may change between releases.

No CLIProxyAPI management key or provider login is needed by this app. Provider status would be fetched separately from public status endpoints.

See [implementation notes](IMPLEMENTATION.md) for the inspected protocol, limitations, and first-build checks.

T3QuotaBar is an independent project and is not affiliated with T3 Code, OpenAI, or Anthropic.
