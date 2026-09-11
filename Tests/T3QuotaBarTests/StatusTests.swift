import AppKit
import SwiftUI
import Testing
@testable import T3QuotaBar

struct StatusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["T3QUOTABAR_LIVE_STATUS"] == "1"))
    @MainActor func liveStatusFeedsPopulateAndRenderBothProviderSubmenus() async throws {
        _ = NSApplication.shared
        let store = Store()
        await store.refreshStatus()
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ui-checks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for driver in ["codex", "claudeAgent"] {
            let components = try #require(store.statusComponents[driver])
            #expect(!components.isEmpty)
            #expect(store.status[driver] != "Status unavailable")
            if driver == "codex" { #expect(components.contains { $0.isGroup }) }
            let view = NSHostingView(rootView: StatusComponentsMenuView(components: components, width: 310).background(Color.white))
            let size = view.fittingSize
            #expect(size.width == 310)
            #expect(size.height < 250)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            window.appearance = NSAppearance(named: .aqua)
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("status-\(driver).png"))
        }
    }

    @Test func groupedFeedPreservesChildrenAndUsesWorstVisibleChildStatus() throws {
        let data = Data(#"{"summary":{"affected_components":[{"component_id":"login","status":"degraded_performance"},{"component_id":"hidden","status":"major_outage"}],"structure":{"items":[{"group":{"id":"chatgpt","name":"ChatGPT","components":[{"component_id":"login","name":"Login"},{"component_id":"chat","name":"Conversations"},{"component_id":"hidden","name":"Hidden","hidden":true}]}},{"component":{"component_id":"codex","name":"Codex"}}]}}}"#.utf8)
        let result = try StatusFeed.parseIncidentIOSummary(data: data)
        #expect(result.components.map(\.name) == ["ChatGPT", "Codex"])
        #expect(result.components[0].children.map(\.name) == ["Login", "Conversations"])
        #expect(result.components[0].indicator == .minor)
        #expect(result.components[0].statusLabel == "Degraded performance")
        #expect(result.components[1].statusLabel == "Operational")
        #expect(result.status.indicator == .minor)
    }

    @Test func claudeFeedKeepsPartialOutageAndProviderOrdering() throws {
        let data = Data(#"{"components":[{"id":"cowork","name":"Claude Cowork","status":"partial_outage","position":5},{"id":"code","name":"Claude Code","status":"operational","position":4}]}"#.utf8)
        let components = try StatusFeed.parseStatuspageComponents(data: data)
        #expect(components.map(\.name) == ["Claude Code", "Claude Cowork"])
        #expect(components[1].indicator == .major)
        #expect(components[1].statusLabel == "Partial outage")
    }

    @Test @MainActor func statusSubmenuHydratesAfterRootOpensAndClearsUnavailableComponents() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let menu = delegate.menu
        delegate.menuNeedsUpdate(menu)
        let submenu = menu.items.first { $0.title == "Codex Status Page" }!.submenu!
        #expect(submenu.items.first?.title == "Open Status Page")
        let child = ProviderStatusComponent(id: "api", name: "API", indicator: .none, status: "operational")
        delegate.store.statusComponents["codex"] = [ProviderStatusComponent(id: "codex", name: "Codex", indicator: .none, status: "operational", children: [child])]
        delegate.menuNeedsUpdate(submenu)
        let hosting = submenu.items.first?.view as? MenuHostingView<StatusComponentsMenuView>
        #expect(hosting?.rootView.components.first?.children == [child])
        #expect(hosting?.frame.width == 310)
        #expect((hosting?.frame.height ?? 0) > 20)
        #expect((hosting?.frame.height ?? 100) < 60)
        #expect(hosting?.rootView.onToggle != nil)
        delegate.menuNeedsUpdate(submenu)
        #expect(submenu.items.first?.view === hosting)
        #expect(submenu.items.last?.title == "Open Status Page")
        #expect(submenu.items.last?.image?.isTemplate == true)
        #expect(submenu.items.last?.representedObject as? String == "codex")
        delegate.store.statusComponents.removeValue(forKey: "codex")
        delegate.menuNeedsUpdate(submenu)
        #expect(submenu.items.first?.view == nil)
        #expect(submenu.items.first?.title == "Open Status Page")
    }
}
