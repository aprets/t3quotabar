# CodexBar UI source

Copied from the local CodexBar fork at revision `7ba403f26df6965b118f157c8b9883f5d5836a57`, based on [CodexBar](https://github.com/steipete/CodexBar). The original MIT license is included in `Sources/T3QuotaBar/Resources/CodexBar-LICENSE` and bundled in the app.

The UI lives in `Sources/T3QuotaBar/CodexBarUI`. Preserve the upstream rendering code when updating it; keep T3 mapping in `Account.menuCard` in `App.swift`.

| Local file | CodexBar source | Changes |
| --- | --- | --- |
| UsageProgressBar.swift | Sources/CodexBar/UsageProgressBar.swift | Attribution header only. |
| UsageMenuCardLayout.swift | Sources/CodexBar/UsageMenuCardLayout.swift | Attribution header only. |
| MetricRow.swift | MetricRow and MetricRowHeader in Sources/CodexBar/MenuCardView.swift | Removed file-private visibility. Rendering bodies unchanged. |
| CodexResetCreditsContent.swift | Sources/CodexBar/MenuCardView+CodexResetCredits.swift | View extracted unchanged; removed Core import. |
| MenuCardMenuItem.swift | Sources/CodexBar/StatusItemController+MenuCardItems.swift | Class extracted unchanged. |
| MenuHostingView.swift | Sources/CodexBar/StatusItemController+MenuPresentation.swift | Class extracted unchanged. |
| MenuTextRows.swift | Sources/CodexBar/StatusItemController+MenuTextRows.swift | Wrapped secondary text rows copied unchanged except the owning controller name. |
| MenuHighlightStyle.swift | Sources/CodexBar/MenuHighlightStyle.swift | Removed refresh monitor. Expanded @Entry to EnvironmentKey because the local Command Line Tools lack SwiftUIMacros. Color methods unchanged. |
| UsageMenuCardView.swift | Sources/CodexBar/MenuCardView.swift | Kept stacked metrics, header and credits. Removed unrelated providers, costs, dashboards, error-copy actions and refresh monitor. Metric model retains the original shape except the unavailable session-equivalent forecast. Header reads T3 subtitle/stale state. |
| Presentation.swift | Sources/CodexBarCore/UsageFormatter.swift; Sources/CodexBar/MenuCardView+CodexResetCredits.swift; Sources/CodexBar/SettingsStore.swift | Copied percentage/countdown formatting and credit presentation. Removed snapshot factories, unrelated formatters and settings labels. Added English localization adapter. |

Hosting preserves the 310-point base width, 6-point row padding plus 1-point descender allowance, vibrancy, primary menu text color and native separators between account cards. Provider colors are copied from the Claude and Codex provider descriptors. Menus attach to their NSStatusItem for native positioning/highlighting, and pin to NSApplication.effectiveAppearance as in CodexBar's StatusMenuAppearance. This prevents a dark menu-bar wallpaper from overriding the app's light appearance. Status summary rows use the copied wrapping layout.

T3 supplies only the next credit expiry, so the original credit view receives one expiry item, never a fabricated full inventory. Its tooltip labels that item as the next expiry. T3's generic Claude plan is not rewritten as Max 20x. Pace text is derived from T3's explicit window duration and reset, using the same even-pace calculation and labels, including the 3%-elapsed gate for session windows; historical pace and session-quota forecasts are not available. Warning markers default to CodexBar's 20% and 50% thresholds. Local UserDefaults overrides use `<driver>.<window-kind>.warningMarkers`; this installation's Claude weekly markers were copied from the user's CodexBar configuration. The app does not continually read CodexBar's config or import workday settings.

To render a light-mode fixture without opening a window:

```sh
T3QUOTABAR_RENDER_FIXTURES=1 bash scripts/test.sh
```

The PNG is written to `.build/ui-checks/claude.png`. It uses synthetic account data and the same view as the live menu.
