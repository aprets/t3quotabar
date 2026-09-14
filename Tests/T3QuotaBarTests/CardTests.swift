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
        item.menu = delegate.menu
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
        #expect(item.button?.accessibilityLabel() == "Claude 5h 95% F 80%, Codex 65% / 65% remaining")
        let image = try #require(item.button?.image)
        #expect(image.isTemplate)
        #expect(image.size.height == 18)
        #expect(image.size.width > 200 && image.size.width < 300)
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
        #expect(item.button?.accessibilityLabel() == "Claude 5h 95% / 78% / ? F 80% / 48% / ? ·, Codex 65% / 65% remaining")
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
