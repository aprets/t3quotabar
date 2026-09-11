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
                struct Summary: Decodable { struct Status: Decodable { let description: String }; let status: Status }
                let data = try await request(URL(string: "https://\(host)/api/v2/status.json")!)
                status[driver] = try JSONDecoder().decode(Summary.self, from: data).status.description
            } catch {
                status[driver] = "Status unavailable"
                NSLog("T3QuotaBar status fetch failed for %@: %@", driver, error.localizedDescription)
            }
        }
    }
}

struct QuotaCards: View {
    @ObservedObject var store: Store
    let driver: String
    var color: Color { driver == "codex" ? Color(red: 0.27, green: 0.65, blue: 0.7) : Color(red: 0.8, green: 0.46, blue: 0.34) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !store.connected { Label(store.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                        let accounts = store.quotas.accounts.filter { $0.driver == driver }
                        if accounts.isEmpty { Text("No \(driver == "codex" ? "Codex" : "Claude") quota snapshots yet.").foregroundStyle(.secondary) }
                        ForEach(accounts) { account in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(account.name).font(.system(size: 14, weight: .bold))
                                    Spacer()
                                    Text(account.email ?? account.source).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                HStack {
                                    if let checked = account.limits.flatMap({ parseDate($0.checkedAt) }) {
                                        Text("Updated \(checked, style: .relative) ago")
                                    } else { Text("Not updated yet") }
                                    Spacer()
                                    Text(account.plan ?? account.source).lineLimit(1)
                                }.font(.footnote).foregroundStyle(.secondary)
                                if account.stale || !store.connected { Text("Stale · showing last known values").font(.caption).foregroundStyle(.orange) }
                                Divider()
                                ForEach(account.limits?.windows ?? []) { window in
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack {
                                            Text("\(window.label) \(Int(window.remaining.rounded()))% left").font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                                            Spacer()
                                            if let reset = window.reset {
                                                if reset > context.date { Text("Resets \(reset, style: .relative)") }
                                                else { Text("Awaiting refresh") }
                                            }
                                        }
                                        .font(.caption).foregroundStyle(.secondary)
                                        GeometryReader { geometry in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(.quaternary)
                                                Capsule().fill(color).frame(width: geometry.size.width * window.remaining / 100)
                                            }
                                        }.frame(height: 6)
                                        if let minutes = window.windowDurationMins, minutes > 0, let reset = window.reset, reset > context.date {
                                            let timeRemaining = min(1, reset.timeIntervalSince(context.date) / (minutes * 60))
                                            let reserve = window.remaining - timeRemaining * 100
                                            Text("\(Int(abs(reserve).rounded()))% \(reserve >= 0 ? "ahead of" : "behind") even pace · estimate").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.padding(.vertical, 3)
                                }
                                if driver != "codex", !(account.limits?.windows.contains(where: \.isFable) ?? false) {
                                    Text("Fable limit unavailable").font(.caption).foregroundStyle(.secondary)
                                }
                                if let credits = account.limits?.resetCredits {
                                    Divider()
                                    HStack {
                                        Text("\(credits.availableCount) reset credits available").font(.system(size: 12, weight: .semibold))
                                        Spacer()
                                        if let expiry = credits.nextExpiresAt.flatMap(parseDate) { Text("Next expires \(expiry, style: .relative)").font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            Divider()
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 10)
            }.frame(width: 340).fixedSize(horizontal: false, vertical: true)
        }
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

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var items: [String: NSStatusItem] = [:]
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        for driver in ["claudeAgent", "codex"] {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(toggle(_:))
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

    @objc func toggle(_ sender: NSStatusBarButton) {
        guard let driver = sender.identifier?.rawValue else { return }
        let menu = NSMenu()
        let cards = NSHostingView(rootView: QuotaCards(store: store, driver: driver))
        cards.frame = NSRect(origin: .zero, size: cards.fittingSize)
        let cardItem = NSMenuItem()
        cardItem.view = cards
        menu.addItem(cardItem)
        let statusItem = NSMenuItem(title: "Status Page", action: nil, keyEquivalent: "")
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: store.status[driver] ?? "Status unavailable", action: nil, keyEquivalent: "")
        let openStatus = statusMenu.addItem(withTitle: "Open status page…", action: #selector(openStatusPage(_:)), keyEquivalent: "")
        openStatus.target = self
        openStatus.representedObject = driver
        statusItem.submenu = statusMenu
        menu.addItem(statusItem)
        menu.addItem(.separator())
        let reconnect = menu.addItem(withTitle: store.connected ? "Reconnect to T3 Code" : "Connect to T3 Code…", action: #selector(reconnect), keyEquivalent: "")
        reconnect.target = self
        menu.addItem(withTitle: "Quit T3QuotaBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    @objc func reconnect() { store.start(pair: !store.connected) }

    @objc func openStatusPage(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: sender.representedObject as? String == "codex" ? "https://status.openai.com" : "https://status.claude.com")!)
    }
}
