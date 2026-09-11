import AppKit
import SwiftUI
import Security
import LocalAuthentication

struct AppFailure: LocalizedError {
    let message: String
    var retryable = true
    var errorDescription: String? { message }
}

@MainActor final class Store: ObservableObject {
    @Published var quotas = Quotas()
    @Published var connected = false
    @Published var message = "Connecting to T3 Code…"
    @Published var status: [String: String] = [:]
    @Published var statusUpdatedAt: [String: Date] = [:]
    @Published var statusComponents: [String: [ProviderStatusComponent]] = [:]
    var onChange: (() -> Void)?
    private var connection: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var reconnectCheckStarted = false
    private var lastFrameAt = Date()
    private var sessionTokens: [String: String] = [:]

    func start(pair: Bool = false) {
        connection?.cancel()
        heartbeat?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        connected = false
        message = "Connecting to T3 Code…"
        onChange?()
        connection = Task {
            var delay: UInt64 = 60
            var shouldPair = pair
            while !Task.isCancelled {
                do {
                    try await listen(pair: shouldPair)
                } catch is CancellationError { return }
                catch {
                    if connected { delay = 60 }
                    connected = false
                    if Task.isCancelled { return }
                    message = (error as? AppFailure)?.message ?? "T3 connection unavailable (\((error as NSError).code)). Retrying…"
                    if error is DecodingError { message = "T3 returned an incompatible response. Update T3QuotaBar or reconnect after updating T3." }
                    NSLog("T3QuotaBar connection: %@", message)
                    onChange?()
                    if (error as? AppFailure)?.retryable == false || error is DecodingError {
                        heartbeat?.cancel()
                        socket?.cancel(with: .goingAway, reason: nil)
                        return
                    }
                }
                shouldPair = false
                heartbeat?.cancel()
                socket?.cancel(with: .goingAway, reason: nil)
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
                delay = min(delay * 2, 300)
            }
        }
    }

    private func request(_ url: URL, method: String = "GET", token: String? = nil, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AppFailure(message: code == 401 ? "T3 authorization expired. Click Connect to T3 Code." : "T3 request failed (HTTP \(code)).", retryable: code != 401 && code != 403)
        }
        return data
    }

    private func listen(pair: Bool) async throws {
        struct Runtime: Decodable { let origin: String }
        struct Descriptor: Decodable { let environmentId: String }
        let runtimeURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata/server-runtime.json")
        let runtime = try JSONDecoder().decode(Runtime.self, from: Data(contentsOf: runtimeURL))
        guard let origin = URL(string: runtime.origin), origin.scheme == "http", ["127.0.0.1", "localhost", "[::1]"].contains(origin.host ?? "") else {
            throw AppFailure(message: "T3 runtime must point to a local server.")
        }
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: await request(origin.appendingPathComponent(".well-known/t3/environment")))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "net.t3quotabar.session.signed", kSecAttrAccount as String: descriptor.environmentId]
        var token = sessionTokens[descriptor.environmentId]
        if token == nil && !pair {
            var result: CFTypeRef?
            var readQuery = query
            readQuery[kSecReturnData as String] = true
            let authentication = LAContext()
            authentication.interactionNotAllowed = true
            readQuery[kSecUseAuthenticationContext as String] = authentication
            let keychainStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
            guard keychainStatus == errSecSuccess || keychainStatus == errSecItemNotFound else {
                throw AppFailure(message: "Keychain access is unavailable. Click Connect to T3 Code to pair this build.", retryable: false)
            }
            token = (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
            sessionTokens[descriptor.environmentId] = token
        }
        if pair {
            message = "Pairing with T3 Code…"
            let pairingToken = try await Task.detached {
                let candidates = ["/Applications/T3 Code (Alpha).app", "/Applications/T3 Code.app"]
                guard let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                    throw AppFailure(message: "Install T3 Code in Applications first.")
                }
                let executable = URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "\(app)/Contents/MacOS/\(executable)")
                process.arguments = ["\(app)/Contents/Resources/app.asar/apps/server/dist/bin.mjs", "pair", "--base-dir", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3").path, "--label", "T3QuotaBar"]
                var environment = ProcessInfo.processInfo.environment
                environment["ELECTRON_RUN_AS_NODE"] = "1"
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let output = String(data: data, encoding: .utf8),
                      let line = output.components(separatedBy: .newlines).first(where: { $0.hasPrefix("Token: ") }) else {
                    throw AppFailure(message: "T3 pairing failed. Check that T3 Code is running.")
                }
                return String(line.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            }.value
            var form = URLComponents()
            form.queryItems = [
                URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:token-exchange"),
                URLQueryItem(name: "subject_token", value: pairingToken),
                URLQueryItem(name: "subject_token_type", value: "urn:t3:params:oauth:token-type:environment-bootstrap"),
                URLQueryItem(name: "requested_token_type", value: "urn:ietf:params:oauth:token-type:access_token"),
                URLQueryItem(name: "scope", value: "orchestration:read"),
                URLQueryItem(name: "client_label", value: "T3QuotaBar"),
                URLQueryItem(name: "client_device_type", value: "desktop"),
                URLQueryItem(name: "client_os", value: "macOS")
            ]
            struct Session: Decodable { let access_token: String; let scope: String }
            let session = try JSONDecoder().decode(Session.self, from: await request(origin.appendingPathComponent("oauth/token"), method: "POST", body: form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)))
            guard session.scope == "orchestration:read" else { throw AppFailure(message: "T3 returned unexpected session permissions.") }
            token = session.access_token
            sessionTokens[descriptor.environmentId] = token
            let attributes = [kSecValueData as String: Data(session.access_token.utf8)]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw AppFailure(message: "Cannot save T3 session to Keychain (\(status)).", retryable: false) }
        }
        guard let token else { throw AppFailure(message: "Click Connect to T3 Code to pair this app.", retryable: false) }
        struct Ticket: Decodable { let ticket: String }
        let ticket = try JSONDecoder().decode(Ticket.self, from: await request(origin.appendingPathComponent("api/auth/websocket-ticket"), method: "POST", token: token))
        try Task.checkCancellation()
        var components = URLComponents(url: origin.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
        components.scheme = "ws"
        components.queryItems = [URLQueryItem(name: "wsTicket", value: ticket.ticket)]
        let ws = URLSession.shared.webSocketTask(with: components.url!)
        socket = ws
        ws.resume()
        lastFrameAt = Date()
        try await ws.send(.string("{\"_tag\":\"Request\",\"id\":\"1\",\"tag\":\"subscribeServerConfig\",\"payload\":{\"usageLimitSources\":true},\"headers\":[]}"))
        heartbeat = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                    guard Date().timeIntervalSince(lastFrameAt) < 60 else {
                        ws.cancel(with: .goingAway, reason: nil)
                        return
                    }
                    try await ws.send(.string("{\"_tag\":\"Ping\"}"))
                } catch {
                    if !Task.isCancelled { ws.cancel(with: .goingAway, reason: nil) }
                    return
                }
            }
        }
        while !Task.isCancelled {
            let frame = try await ws.receive()
            lastFrameAt = Date()
            let data: Data
            switch frame { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
            struct Envelope: Decodable { let _tag: String; let requestId: String?; let values: [ConfigEvent]? }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            if envelope._tag == "Chunk", let values = envelope.values {
                for event in values { quotas.apply(event) }
                connected = true
                message = "Reading T3 Code snapshots"
                onChange?()
                try await ws.send(.string("{\"_tag\":\"Ack\",\"requestId\":\"1\"}"))
                if CommandLine.arguments.contains("--check-reconnect"), !quotas.external.isEmpty {
                    if !reconnectCheckStarted {
                        reconnectCheckStarted = true
                        ws.cancel(with: .goingAway, reason: nil)
                        throw AppFailure(message: "Reconnect check: deliberately disconnected; retaining \(quotas.accounts.count) accounts.")
                    }
                    print("Reconnect check passed: subscription restored with \(quotas.accounts.count) accounts.")
                    NSApplication.shared.terminate(nil)
                }
                if CommandLine.arguments.contains("--diagnose"), !quotas.external.isEmpty {
                    for account in quotas.accounts {
                        print("\(account.driver): \(account.compact); windows=\(account.limits?.windows.map(\.id).joined(separator: ",") ?? "none"); credits=\(account.limits?.resetCredits?.availableCount ?? 0)")
                    }
                    NSApplication.shared.terminate(nil)
                }
            } else if ["Exit", "Defect", "ClientProtocolError"].contains(envelope._tag) {
                throw AppFailure(message: "T3 closed the quota subscription. Reconnecting…")
            }
        }
    }

    func refreshStatus() async {
        for (driver, host) in [("codex", "status.openai.com"), ("claudeAgent", "status.claude.com")] {
            do {
                struct Summary: Decodable {
                    struct Status: Decodable { let description: String }
                    struct Page: Decodable { let updated_at: String? }
                    let status: Status
                    let page: Page?
                }
                let data = try await request(URL(string: "https://\(host)/api/v2/status.json")!)
                let summary = try JSONDecoder().decode(Summary.self, from: data)
                status[driver] = summary.status.description
                statusUpdatedAt[driver] = summary.page?.updated_at.flatMap(parseDate)
            } catch {
                status[driver] = "Status unavailable"
                statusUpdatedAt.removeValue(forKey: driver)
                NSLog("T3QuotaBar status fetch failed for %@: %@", driver, error.localizedDescription)
            }
            do {
                if driver == "codex" {
                    do {
                        let data = try await request(URL(string: "https://\(host)/proxy/\(host)")!)
                        statusComponents[driver] = try StatusFeed.parseIncidentIOSummary(data: data).components
                        continue
                    } catch {
                        NSLog("T3QuotaBar grouped status fetch failed for %@; using Statuspage feed: %@", driver, error.localizedDescription)
                    }
                }
                let data = try await request(URL(string: "https://\(host)/api/v2/components.json")!)
                statusComponents[driver] = try StatusFeed.parseStatuspageComponents(data: data)
            } catch {
                statusComponents.removeValue(forKey: driver)
                NSLog("T3QuotaBar status components fetch failed for %@: %@", driver, error.localizedDescription)
            }
        }
    }
}

extension Account {
    func menuCard(now: Date, connected: Bool) -> UsageMenuCardView.Model {
        var metrics = (limits?.windows ?? []).map { window -> UsageMenuCardView.Model.Metric in
            let title: String
            if window.isFable { title = "Fable only" }
            else if window.id == "seven_day" { title = "Weekly" }
            else if window.kind == "session" { title = "Session" }
            else { title = window.label }
            var pacePercent: Double?
            var paceOnTop = true
            var left: String?
            var right: String?
            if let minutes = window.windowDurationMins, minutes > 0, let reset = window.reset {
                let duration = minutes * 60
                let remainingTime = reset.timeIntervalSince(now)
                let elapsed = duration - remainingTime
                if remainingTime > 0, remainingTime <= duration, elapsed > 0, window.remaining > 0 {
                    let expectedUsed = elapsed / duration * 100
                    let reserve = expectedUsed - window.usedPercent
                    if expectedUsed >= 3 {
                        let onPace = abs(reserve) <= 2
                        left = onPace ? "On pace" : "\(Int(abs(reserve).rounded()))% in \(reserve >= 0 ? "reserve" : "deficit")"
                        pacePercent = onPace ? nil : 100 - expectedUsed
                        paceOnTop = reserve >= 0
                        if reserve >= 0 {
                            right = "Lasts until reset"
                            let projectedUsage = window.usedPercent * remainingTime / elapsed
                            if driver == "codex", reserve > 15, projectedUsage > 0, window.remaining / projectedUsage >= 1.5 {
                                right = "Lasts until reset · 1.5× headroom"
                            }
                        } else if window.usedPercent > 0 {
                            let eta = window.remaining * elapsed / window.usedPercent
                            let countdown = UsageFormatter.resetCountdownDescription(from: now.addingTimeInterval(eta), now: now)
                            right = window.kind == "session" ? "Projected empty \(countdown)" : "Runs out \(countdown)"
                        }
                    }
                }
            }
            return .init(
                id: window.id, title: title, percent: window.remaining, percentStyle: .left,
                resetText: window.reset.map { "Resets \(UsageFormatter.resetCountdownDescription(from: $0, now: now))" },
                detailText: nil, detailLeftText: left, detailRightText: right,
                pacePercent: pacePercent, detailIsPaceDerived: left != nil, paceOnTop: paceOnTop,
                warningMarkerPercents: window.isFable ? [] : (UserDefaults.standard.array(forKey: "\(driver).\(window.kind).warningMarkers") as? [Double] ?? [20, 50]))
        }
        if driver != "codex", !metrics.contains(where: { $0.title == "Fable only" }) {
            metrics.append(.init(id: "fable-unavailable", title: "Fable only", percent: 0, percentStyle: .left,
                                 statusText: "Unavailable", resetText: nil, detailText: nil,
                                 detailLeftText: nil, detailRightText: nil, pacePercent: nil, paceOnTop: true))
        }
        let credits = limits?.resetCredits.map { credits in
            let items: [CodexResetCreditPresentationItem] = credits.nextExpiresAt.flatMap(parseDate).map { expiry in
                let countdown = UsageFormatter.resetCountdownDescription(from: expiry, now: now)
                return [.init(expiryText: "Next credit expires \(countdown)", compactExpiryText: countdown.hasPrefix("in ") ? String(countdown.dropFirst(3)) : countdown)]
            } ?? []
            return CodexResetCreditsPresentation(text: "\(credits.availableCount) available", items: items)
        }
        var planText = plan
        for prefix in ["ChatGPT ", "Claude "] {
            if planText?.hasPrefix(prefix) == true { planText = String(planText!.dropFirst(prefix.count)) }
        }
        if planText?.hasSuffix(" Subscription") == true { planText = String(planText!.dropLast(" Subscription".count)) }
        if planText == "Subscription" || planText == "" { planText = nil }
        let age = limits.flatMap { parseDate($0.checkedAt) }.map { max(0, Int(now.timeIntervalSince($0))) }
        let updated: String
        if let age {
            if age < 60 { updated = "Updated just now" }
            else if age < 3600 { updated = "Updated \(age / 60)m ago" }
            else { updated = "Updated \(age / 3600)h ago" }
        } else { updated = "Not updated yet" }
        let stale = self.stale || !connected
        return .init(providerName: name, email: email ?? source,
                     subtitleText: stale ? "Stale · \(updated.lowercased())" : updated,
                     isStale: stale, planText: planText, metrics: metrics, codexResetCredits: credits,
                     placeholder: metrics.isEmpty ? "Quota unavailable" : nil,
                     progressColor: driver == "codex" ? Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255) : Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255))
    }
}

@main struct T3QuotaBar {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    var items: [String: NSStatusItem] = [:]
    var menus: [String: NSMenu] = [:]
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        for driver in ["claudeAgent", "codex"] {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            menu.appearance = NSApp.effectiveAppearance
            menus[driver] = menu
            item.menu = menu
            menuNeedsUpdate(menu)
            item.button?.identifier = NSUserInterfaceItemIdentifier(driver)
            let iconName = driver == "codex" ? "codex" : "claude"
            let packagedResources = Bundle.main.resourceURL?.appendingPathComponent("T3QuotaBar_T3QuotaBar.bundle")
            let resourceBundle = packagedResources.flatMap { Bundle(url: $0) } ?? Bundle.module
            if let url = resourceBundle.url(forResource: "ProviderIcon-\(iconName)", withExtension: "svg", subdirectory: "Resources"), let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                item.button?.image = image
                item.button?.imagePosition = .imageLeading
            }
            items[driver] = item
        }
        store.onChange = { [weak self] in self?.updateTitles() }
        updateTitles()
        store.start(pair: CommandLine.arguments.contains("--pair"))
        Task { await store.refreshStatus() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateTitles()
                await self?.store.refreshStatus()
            }
        }
    }

    func updateTitles() {
        for (driver, item) in items {
            let accounts = store.quotas.accounts.filter { $0.driver == driver }
            let stale = !store.connected || accounts.contains(where: \.stale)
            item.button?.title = " " + (accounts.isEmpty ? "T3 ?" : accounts.map(\.compact).joined(separator: " / ")) + (stale ? " ·" : "")
            item.button?.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            item.button?.toolTip = stale ? "T3QuotaBar · stale or disconnected" : "T3QuotaBar · percentages remaining"
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.appearance = NSApp.effectiveAppearance
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.appearance = NSApp.effectiveAppearance
        if let driver = menu.supermenu?.items.first(where: { $0.submenu === menu })?.representedObject as? String {
            populateStatusMenu(menu, driver: driver)
            return
        }
        guard let driver = menus.first(where: { $0.value === menu })?.key else { return }
        menu.removeAllItems()
        let accounts = store.quotas.accounts.filter { $0.driver == driver }
        for account in accounts {
            let model = account.menuCard(now: Date(), connected: store.connected)
            let hosting = MenuHostingView(rootView: UsageMenuCardView(model: model, width: 310)
                .foregroundStyle(MenuHighlightStyle.primary(false)))
            let height = max(1, ceil(hosting.measuredFittingHeight(width: 310) + 6 + 1))
            hosting.applyMeasuredHeight(width: 310, height: height)
            let item = MenuCardMenuItem()
            item.title = ""
            item.view = hosting
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }
        if accounts.isEmpty {
            menu.addItem(withTitle: store.message, action: nil, keyEquivalent: "")
            menu.addItem(.separator())
        }
        let statusItem = NSMenuItem(title: "Status Page", action: nil, keyEquivalent: "")
        statusItem.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
        let statusMenu = NSMenu()
        statusMenu.appearance = NSApp.effectiveAppearance
        statusMenu.delegate = self
        populateStatusMenu(statusMenu, driver: driver)
        statusItem.representedObject = driver
        statusItem.submenu = statusMenu
        menu.addItem(statusItem)
        if var summaryText = store.status[driver], summaryText != "Status unavailable" {
            if let updated = store.statusUpdatedAt[driver] {
                let minutes = max(0, Int(Date().timeIntervalSince(updated) / 60))
                let age: String
                if minutes >= 1440 { age = updated.formatted(.dateTime.hour().minute().locale(Locale(identifier: "en_US_POSIX"))) }
                else { age = minutes < 1 ? "just now" : (minutes < 60 ? "\(minutes)m ago" : "\(minutes / 60)h ago") }
                summaryText += " — Updated \(age)"
            }
            menu.addItem(makeWrappedSecondaryTextItem(text: summaryText, width: 310))
        }
        menu.addItem(.separator())
        let reconnect = menu.addItem(withTitle: store.connected ? "Reconnect to T3 Code" : "Connect to T3 Code…", action: #selector(reconnect), keyEquivalent: "")
        reconnect.target = self
        reconnect.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        let quit = menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "xmark.rectangle", accessibilityDescription: nil)
        for item in [statusItem, reconnect, quit] {
            item.image?.isTemplate = true
            item.image?.size = NSSize(width: 16, height: 16)
        }
    }

    func populateStatusMenu(_ menu: NSMenu, driver: String) {
        let components = store.statusComponents[driver] ?? []
        if let hosting = menu.items.first?.view as? MenuHostingView<StatusComponentsMenuView>,
           hosting.rootView.components == components { return }
        menu.removeAllItems()
        if !components.isEmpty {
            final class HostingRelay {
                weak var hosting: MenuHostingView<StatusComponentsMenuView>?
            }
            let relay = HostingRelay()
            let width: CGFloat = 310
            let listView = StatusComponentsMenuView(components: components, width: width, onToggle: {
                DispatchQueue.main.async {
                    guard let hosting = relay.hosting else { return }
                    hosting.applyMeasuredHeight(width: width, height: hosting.measuredFittingHeight(width: width))
                }
            })
            let hosting = MenuHostingView(rootView: listView)
            relay.hosting = hosting
            hosting.applyMeasuredHeight(width: width, height: hosting.measuredFittingHeight(width: width))
            let listItem = NSMenuItem()
            listItem.view = hosting
            listItem.isEnabled = false
            menu.addItem(listItem)
            menu.addItem(.separator())
        }
        let openStatus = menu.addItem(withTitle: "Open Status Page", action: #selector(openStatusPage(_:)), keyEquivalent: "")
        openStatus.target = self
        openStatus.representedObject = driver
        openStatus.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
        openStatus.image?.isTemplate = true
        openStatus.image?.size = NSSize(width: 16, height: 16)
    }

    @objc func reconnect() { store.start(pair: !store.connected) }

    @objc func openStatusPage(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: sender.representedObject as? String == "codex" ? "https://status.openai.com" : "https://status.claude.com")!)
    }
}
