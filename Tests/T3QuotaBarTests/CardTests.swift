import AppKit
import SwiftUI
import Testing
@testable import T3QuotaBar

struct CardTests {
    @Test @MainActor func fullMenuUsesApplicationAppearanceAndWrappedStatusSummary() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        let menu = NSMenu()
        delegate.menus["codex"] = menu
        delegate.store.status["codex"] = "Partial System Degradation"
        delegate.store.statusUpdatedAt["codex"] = Date().addingTimeInterval(-3600)
        menu.appearance = NSAppearance(named: .darkAqua)
        delegate.menuNeedsUpdate(menu)
        delegate.menuWillOpen(menu)
        #expect(menu.appearance === app.effectiveAppearance)
        let status = menu.items.first { $0.title == "Status Page" }
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
