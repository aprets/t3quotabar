import AppKit
import SwiftUI
import Testing
@testable import T3QuotaBar

struct CardTests {
    @Test @MainActor func combinedItemShowsBothProvidersAndKeepsClaudeWeeklyInDropdown() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        delegate.item = item
        for (driver, name) in [("claudeAgent", "claude"), ("codex", "codex")] {
            let url = try #require(Bundle.module.url(forResource: "ProviderIcon-\(name)", withExtension: "svg", subdirectory: "Resources"))
            let icon = try #require(NSImage(contentsOf: url))
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            delegate.icons[driver] = icon
        }
        let checkedAt = ISO8601DateFormatter().string(from: Date())
        let claude = try JSONDecoder().decode(Limits.self, from: Data("""
        {"checkedAt":"\(checkedAt)","windows":[{"id":"five_hour","kind":"session","label":"Session","usedPercent":5},{"id":"seven_day","kind":"weekly","label":"Weekly","usedPercent":10},{"id":"seven_day_fable","kind":"weekly","label":"Weekly · Fable","usedPercent":20}]}
        """.utf8))
        let codex = try JSONDecoder().decode(Limits.self, from: Data("""
        {"checkedAt":"\(checkedAt)","windows":[{"id":"primary","kind":"weekly","label":"Weekly","usedPercent":35}]}
        """.utf8))
        delegate.store.quotas.external = [
            Account(id: "claude", driver: "claudeAgent", name: "Claude", email: nil, plan: nil, source: "CPA", limits: claude, failed: false),
            Account(id: "codex1", driver: "codex", name: "Codex", email: nil, plan: nil, source: "CPA", limits: codex, failed: false),
            Account(id: "codex2", driver: "codex", name: "Codex", email: nil, plan: nil, source: "CPA", limits: codex, failed: false)
        ]
        delegate.store.connected = true
        delegate.updateTitles()
        #expect(item.button?.accessibilityLabel() == "Claude 80%, Codex 65% / 65% remaining")
        #expect(item.button?.toolTip == nil)
        let image = try #require(item.button?.image)
        #expect(image.isTemplate)
        #expect(image.size.height == 18)
        #expect(image.size.width > 100 && image.size.width < 200)
        delegate.menuNeedsUpdate(delegate.menu)
        #expect(delegate.menu.items.filter { $0 is MenuCardMenuItem }.count == 3)
        #expect(delegate.menu.items.contains { $0.title == "Claude Status Page" })
        #expect(delegate.menu.items.contains { $0.title == "Codex Status Page" })
        #expect(delegate.store.quotas.external[0].menuCard(now: Date(), connected: true).metrics.map(\.title) == ["Session", "Weekly", "Fable only"])
        let secondClaude = try JSONDecoder().decode(Limits.self, from: Data("""
        {"checkedAt":"\(checkedAt)","windows":[{"id":"five_hour","kind":"session","label":"Session","usedPercent":22},{"id":"seven_day_fable","kind":"weekly","label":"Weekly · Fable","usedPercent":52}]}
        """.utf8))
        delegate.store.quotas.external.append(Account(id: "claude2", driver: "claudeAgent", name: "Claude", email: nil, plan: nil, source: "CPA", limits: secondClaude, failed: false))
        delegate.store.quotas.external.append(Account(id: "claude3", driver: "claudeAgent", name: "Claude", email: nil, plan: nil, source: "CPA", limits: nil, failed: false))
        delegate.updateTitles()
        #expect(item.button?.accessibilityLabel() == "Claude 80% / 48% / ? ·, Codex 65% / 65% remaining")
        if ProcessInfo.processInfo.environment["T3QUOTABAR_RENDER_FIXTURES"] == "1" {
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ui-checks")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let preview = NSButton(frame: NSRect(x: 0, y: 0, width: image.size.width + 12, height: 24))
            preview.isBordered = false
            preview.wantsLayer = true
            preview.layer?.backgroundColor = NSColor.white.cgColor
            preview.image = image
            preview.imagePosition = .imageOnly
            preview.contentTintColor = .black
            let window = NSWindow(contentRect: preview.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = .white
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = preview
            preview.layoutSubtreeIfNeeded()
            let bitmap = try #require(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
            preview.cacheDisplay(in: preview.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("combined-item.png"))
        }
    }

    @Test @MainActor func claudeWarningShowsOnlySessionsBelowTwentyFiveAndDisappearsAfterReset() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        delegate.item = item
        delegate.store.connected = true
        let checkedAt = ISO8601DateFormatter().string(from: Date())
        for (used, expected) in [
            ([82, 75, 78], " 5h! 18% / 22%"),
            ([100, 75, 0], " 5h! 0%"),
            ([0, 75, 0], "")
        ] {
            delegate.store.quotas.external = try used.enumerated().map { index, usedPercent in
                let limits = try JSONDecoder().decode(Limits.self, from: Data("""
                {"checkedAt":"\(checkedAt)","windows":[{"id":"five_hour","kind":"session","label":"Session","usedPercent":\(usedPercent)},{"id":"seven_day_fable","kind":"weekly","label":"Weekly · Fable","usedPercent":\(index * 10)}]}
                """.utf8))
                return Account(id: "claude\(index)", driver: "claudeAgent", name: "Claude", email: nil, plan: nil, source: "CPA", limits: limits, failed: false)
            }
            delegate.updateTitles()
            #expect(item.button?.accessibilityLabel() == "Claude 100% / 90% / 80%\(expected), Codex ? remaining")
        }
    }

    @Test @MainActor func sumTogglePersistsTotalsWithoutHidingLowSessionsOrMissingAccounts() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let suite = "T3QuotaBarTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        delegate.preferences = preferences
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        delegate.item = item
        delegate.store.connected = true
        let checkedAt = ISO8601DateFormatter().string(from: Date())
        for (index, driver) in ["claudeAgent", "claudeAgent", "codex", "codex"].enumerated() {
            let limits = try JSONDecoder().decode(Limits.self, from: Data("""
            {"checkedAt":"\(checkedAt)","windows":[{"id":"five_hour","kind":"session","label":"Session","usedPercent":82},{"id":"seven_day_fable","kind":"weekly","label":"Weekly · Fable","usedPercent":20}]}
            """.utf8))
            delegate.store.quotas.external.append(Account(id: "account\(index)", driver: driver, name: driver, email: nil, plan: nil, source: "CPA", limits: limits, failed: false))
        }
        delegate.toggleSumAccountLimits()
        #expect(UserDefaults(suiteName: suite)?.bool(forKey: "sumAccountLimits") == true)
        #expect(item.button?.accessibilityLabel() == "Claude 160% 5h! 18% / 18%, Codex 160% remaining")
        delegate.menuNeedsUpdate(delegate.menu)
        let toggleIndex = try #require(delegate.menu.items.firstIndex { $0.title == "Show per-account limits" })
        #expect(delegate.menu.items[toggleIndex].state == .off)
        #expect(delegate.menu.items[toggleIndex].image?.size == NSSize(width: 16, height: 16))
        #expect(delegate.menu.items[toggleIndex + 1].title == "Reconnect to T3 Code")
        #expect(delegate.menu.items.filter { $0 is MenuCardMenuItem }.count == 4)
        delegate.store.quotas.external[0].limits = nil
        delegate.updateTitles()
        #expect(item.button?.accessibilityLabel() == "Claude 80% + ? 5h! 18% ·, Codex 160% remaining")
        delegate.toggleSumAccountLimits()
        #expect(preferences.bool(forKey: "sumAccountLimits") == false)
        delegate.menuNeedsUpdate(delegate.menu)
        let totals = try #require(delegate.menu.items.first { $0.title == "Show totals" })
        #expect(totals.state == .off)
        #expect(totals.image?.size == NSSize(width: 16, height: 16))
        #expect(item.button?.accessibilityLabel() == "Claude ? / 80% 5h! 18% ·, Codex 80% / 80% remaining")
    }

    @Test @MainActor func reserveToggleShowsPaceArrowsAndAveragesInsteadOfSumming() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let suite = "T3QuotaBarTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        delegate.preferences = preferences
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        delegate.item = item
        for (key, name, size) in [("claudeAgent", "ProviderIcon-claude", 18.0), ("codex", "ProviderIcon-codex", 18.0), ("↗", "PaceIcon-ahead", 12.0), ("↘", "PaceIcon-under", 12.0)] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Resources"))
            let icon = try #require(NSImage(contentsOf: url))
            icon.size = NSSize(width: size, height: size)
            icon.isTemplate = true
            delegate.icons[key] = icon
        }
        delegate.store.connected = true
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let checkedAt = formatter.string(from: Date())
        // Two of seven days elapsed, so linear pace expects about 28.6% used.
        let reset = formatter.string(from: Date().addingTimeInterval(5 * 86_400))
        func limits(fable: Double?, codex: Double?, resets: Bool = true, session: Double = 82) throws -> Limits {
            let resetsAt = resets ? "\"\(reset)\"" : "null"
            let windows = fable.map { "{\"id\":\"five_hour\",\"kind\":\"session\",\"label\":\"Session\",\"usedPercent\":\(session)},{\"id\":\"seven_day_fable\",\"kind\":\"weekly\",\"label\":\"Weekly · Fable\",\"usedPercent\":\($0),\"resetsAt\":\(resetsAt),\"windowDurationMins\":10080}" }
                ?? "{\"id\":\"primary\",\"kind\":\"weekly\",\"label\":\"Weekly\",\"usedPercent\":\(codex ?? 0),\"resetsAt\":\(resetsAt),\"windowDurationMins\":10080}"
            return try JSONDecoder().decode(Limits.self, from: Data("{\"checkedAt\":\"\(checkedAt)\",\"windows\":[\(windows)]}".utf8))
        }
        delegate.store.quotas.external = [
            Account(id: "claude1", driver: "claudeAgent", name: "Claude", email: nil, plan: nil, source: "CPA", limits: try limits(fable: 20, codex: nil), failed: false),
            Account(id: "claude2", driver: "claudeAgent", name: "Claude", email: nil, plan: nil, source: "CPA", limits: try limits(fable: 40, codex: nil), failed: false),
            // Untouched: Claude reports no reset until something is used, so there is no clock to pace against.
            Account(id: "claude3", driver: "claudeAgent", name: "Claude", email: nil, plan: nil, source: "CPA", limits: try limits(fable: 0, codex: nil, resets: false, session: 0), failed: false),
            Account(id: "codex1", driver: "codex", name: "Codex", email: nil, plan: nil, source: "CPA", limits: try limits(fable: nil, codex: 20), failed: false),
            Account(id: "codex2", driver: "codex", name: "Codex", email: nil, plan: nil, source: "CPA", limits: try limits(fable: nil, codex: 20, resets: false), failed: false)
        ]
        delegate.updateTitles()
        #expect(item.button?.accessibilityLabel() == "Claude 80% / 60% / 100% 5h! 18% / 18%, Codex 80% / 80% remaining")
        delegate.toggleShowReserve()
        #expect(preferences.bool(forKey: "showReserve") == true)
        #expect(item.button?.accessibilityLabel() == "Claude ↘9% / ↗11% / ↘ 5h! 18% / 18%, Codex ↘9% / ? reserve")
        if ProcessInfo.processInfo.environment["T3QUOTABAR_RENDER_FIXTURES"] == "1" {
            let image = try #require(item.button?.image)
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ui-checks")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let preview = NSButton(frame: NSRect(x: 0, y: 0, width: image.size.width + 12, height: 24))
            preview.isBordered = false
            preview.wantsLayer = true
            preview.layer?.backgroundColor = NSColor.white.cgColor
            preview.image = image
            preview.imagePosition = .imageOnly
            preview.contentTintColor = .black
            let window = NSWindow(contentRect: preview.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = .white
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = preview
            preview.layoutSubtreeIfNeeded()
            let bitmap = try #require(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
            preview.cacheDisplay(in: preview.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("reserve-item.png"))
        }
        delegate.menuNeedsUpdate(delegate.menu)
        let limitsRow = try #require(delegate.menu.items.firstIndex { $0.title == "Show limits" })
        #expect(delegate.menu.items[limitsRow].image?.size == NSSize(width: 16, height: 16))
        #expect(delegate.menu.items[limitsRow + 1].title == "Show average")
        #expect(delegate.menu.items[limitsRow + 2].title == "Reconnect to T3 Code")
        delegate.toggleSumAccountLimits()
        #expect(item.button?.accessibilityLabel() == "Claude ↗1% 5h! 18% / 18%, Codex ↘9% + ? reserve")
        delegate.menuNeedsUpdate(delegate.menu)
        #expect(delegate.menu.items.contains { $0.title == "Show per-account reserve" })
        delegate.toggleShowReserve()
        #expect(item.button?.accessibilityLabel() == "Claude 240% 5h! 18% / 18%, Codex 160% remaining")
        delegate.menuNeedsUpdate(delegate.menu)
        #expect(delegate.menu.items.contains { $0.title == "Show reserve" })
        #expect(delegate.menu.items.contains { $0.title == "Show per-account limits" })
    }

    @Test @MainActor func fullMenuUsesApplicationAppearanceAndWrappedStatusSummary() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        let menu = delegate.menu
        delegate.store.status["codex"] = "Partial System Degradation"
        delegate.store.statusUpdatedAt["codex"] = Date().addingTimeInterval(-3600)
        menu.appearance = NSAppearance(named: .darkAqua)
        delegate.menuNeedsUpdate(menu)
        delegate.menuWillOpen(menu)
        #expect(menu.appearance === app.effectiveAppearance)
        let status = menu.items.first { $0.title == "Codex Status Page" }
        #expect(status?.image != nil)
        #expect(status?.image?.size == NSSize(width: 16, height: 16))
        #expect(status?.image?.isTemplate == true)
        #expect(status?.submenu?.appearance === app.effectiveAppearance)
        let summary = menu.items.first { $0.toolTip?.contains("Partial System Degradation") == true }
        #expect(summary?.view?.frame.width == 310)
        #expect(summary?.view?.frame.height ?? 0 < 45)
    }

    @Test func newSessionDoesNotShowPaceBeforeThreePercentElapsed() throws {
        let now = Date()
        let limits = try JSONDecoder().decode(Limits.self, from: Data("""
        {"checkedAt":"\(ISO8601DateFormatter().string(from: now))","windows":[{"id":"five_hour","kind":"session","label":"Session","usedPercent":2,"windowDurationMins":300,"resetsAt":"\(ISO8601DateFormatter().string(from: now.addingTimeInterval(295 * 60)))"}]}
        """.utf8))
        let account = Account(id: "claude", driver: "claudeAgent", name: "Claude", email: nil, plan: nil, source: "CPA", limits: limits, failed: false)
        let model = account.menuCard(now: now, connected: true)
        #expect(model.metrics[0].detailLeftText == nil)
        #expect(model.metrics[0].detailRightText == nil)
        #expect(model.metrics[0].pacePercent == nil)
    }

    @Test @MainActor func copiedCardFitsWithoutClippingAndMapsT3Windows() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = ISO8601DateFormatter()
        let limits = try JSONDecoder().decode(Limits.self, from: Data("""
        {"checkedAt":"\(formatter.string(from: now.addingTimeInterval(-120)))","windows":[
          {"id":"five_hour","kind":"session","label":"Session","usedPercent":27,"windowDurationMins":300,"resetsAt":"\(formatter.string(from: now.addingTimeInterval(3600)))"},
          {"id":"seven_day","kind":"weekly","label":"Weekly","usedPercent":7,"windowDurationMins":10080,"resetsAt":"\(formatter.string(from: now.addingTimeInterval(504000)))"},
          {"id":"seven_day_fable","kind":"weekly","label":"Weekly · Fable","usedPercent":13,"windowDurationMins":10080,"resetsAt":"\(formatter.string(from: now.addingTimeInterval(504000)))"}
        ]}
        """.utf8))
        let account = Account(id: "claude", driver: "claudeAgent", name: "Claude", email: "primary@example.com", plan: "Claude Max 20x Subscription", source: "CPA", limits: limits, failed: false)
        let model = account.menuCard(now: now, connected: true)
        #expect(model.metrics.map(\.title) == ["Session", "Weekly", "Fable only"])
        #expect(model.metrics.map(\.percent) == [73, 93, 87])
        #expect(model.metrics[0].resetText == "Resets in 1h")
        #expect(model.metrics[0].detailLeftText == "53% in reserve")
        #expect(model.planText == "Max 20x")
        #expect(model.subtitleText == "Updated 2m ago")

        let view = NSHostingView(rootView: UsageMenuCardView(model: model, width: 310)
            .foregroundStyle(MenuHighlightStyle.primary(false)).background(Color.white))
        let size = view.fittingSize
        #expect(size.width == 310)
        #expect(size.height > 210 && size.height < 330)
        let hosting = MenuHostingView(rootView: UsageMenuCardView(model: model, width: 310))
        let menuHeight = ceil(hosting.measuredFittingHeight(width: 310) + 7)
        hosting.applyMeasuredHeight(width: 310, height: menuHeight)
        #expect(hosting.intrinsicContentSize.height == menuHeight)
        #expect(hosting.allowsVibrancy)

        if ProcessInfo.processInfo.environment["T3QUOTABAR_RENDER_FIXTURES"] == "1" {
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ui-checks")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            window.appearance = NSAppearance(named: .aqua)
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppFailure(message: "Cannot render card fixture") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppFailure(message: "Cannot encode card fixture") }
            try png.write(to: output.appendingPathComponent("claude.png"))
        }
    }

    @Test @MainActor func resetCreditInventoryDoesNotInventMissingExpiries() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let limits = try JSONDecoder().decode(Limits.self, from: Data("""
        {"checkedAt":"2027-01-15T08:00:00Z","windows":[{"id":"primary","kind":"weekly","label":"Weekly","usedPercent":30,"windowDurationMins":10080,"resetsAt":"2027-01-18T23:00:00Z"}],"resetCredits":{"availableCount":3,"nextExpiresAt":"2027-01-25T08:00:00Z"}}
        """.utf8))
        let account = Account(id: "codex", driver: "codex", name: "Codex", email: nil, plan: "ChatGPT Pro 20x Subscription", source: "CPA", limits: limits, failed: false)
        let model = account.menuCard(now: now, connected: true)
        #expect(model.planText == "Pro 20x")
        #expect(model.codexResetCredits?.text == "3 available")
        #expect(model.codexResetCredits?.items.count == 1)
        if ProcessInfo.processInfo.environment["T3QUOTABAR_RENDER_FIXTURES"] == "1" {
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ui-checks")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let view = NSHostingView(rootView: UsageMenuCardView(model: model, width: 310)
                .foregroundStyle(MenuHighlightStyle.primary(false)).background(Color.white))
            let size = view.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            window.appearance = NSAppearance(named: .aqua)
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppFailure(message: "Cannot render credit fixture") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppFailure(message: "Cannot encode credit fixture") }
            try png.write(to: output.appendingPathComponent("codex.png"))
        }
    }
}
