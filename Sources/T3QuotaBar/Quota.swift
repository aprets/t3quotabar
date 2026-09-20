import Foundation

struct Window: Decodable, Identifiable {
    let id: String
    let kind: String
    let label: String
    let usedPercent: Double
    let resetsAt: String?
    let windowDurationMins: Double?
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    var isFable: Bool { id.lowercased().contains("fable") || label.lowercased().contains("fable") }
    var reset: Date? { resetsAt.flatMap(parseDate) }

    struct Pace {
        let expectedUsed: Double
        let usedPercent: Double
        let elapsed: TimeInterval
        let remainingTime: TimeInterval
        /// Percentage points ahead of linear pace; negative is a deficit.
        var reserve: Double { expectedUsed - usedPercent }
    }

    /// Linear pace through the window. Nil when the window has no clock: no length, no reset, or a reset outside the window.
    /// `creditReset` is the soonest banked reset credit's expiry: the CPA balancer redeems it just before then, wiping the
    /// meters, so when it lands before the natural reset it is the reset that matters and the window ends there instead.
    func pace(now: Date, creditReset: Date? = nil) -> Pace? {
        guard let minutes = windowDurationMins, minutes > 0, let reset else { return nil }
        let duration = minutes * 60
        let naturalRemaining = reset.timeIntervalSince(now)
        let elapsed = duration - naturalRemaining
        guard naturalRemaining > 0, naturalRemaining <= duration, elapsed > 0 else { return nil }
        let remainingTime = min(naturalRemaining, creditReset.map { max(0, $0.timeIntervalSince(now)) } ?? naturalRemaining)
        return Pace(expectedUsed: elapsed / (elapsed + remainingTime) * 100, usedPercent: usedPercent, elapsed: elapsed, remainingTime: remainingTime)
    }
}

func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

struct Limits: Decodable {
    struct Credits: Decodable { let availableCount: Int; let nextExpiresAt: String? }
    struct Unavailable: Decodable { let reason: String; let message: String? }
    let checkedAt: String
    let windows: [Window]
    let resetCredits: Credits?
    let unavailable: Unavailable?
    var creditReset: Date? { resetCredits?.nextExpiresAt.flatMap(parseDate) }
}

struct Account: Identifiable {
    let id: String
    let driver: String
    let name: String
    let email: String?
    let plan: String?
    let source: String
    var limits: Limits?
    var failed: Bool
    var stale: Bool {
        failed || limits.flatMap { parseDate($0.checkedAt) }.map { Date().timeIntervalSince($0) > 20 * 60 } ?? true
    }
    var weekly: Window? { limits?.windows.first { driver == "codex" ? $0.kind == "weekly" : $0.id == "seven_day" } }
    var compact: String {
        if driver == "codex" { return weekly.map { "\(Int($0.remaining.rounded()))%" } ?? "?" }
        let windows = limits?.windows ?? []
        let session = windows.first { $0.kind == "session" }
        let fable = windows.first { $0.isFable }
        return [("5h", session), ("F", fable)].map { label, window in
            "\(label) \(window.map { "\(Int($0.remaining.rounded()))%" } ?? "?")"
        }.joined(separator: " ")
    }
}

struct QuotaRefreshSchedule {
    var lastAttempt: Date?
    var pending = false
    private let startedAt = Date()

    mutating func beginIfDue(accounts: [Account], now: Date) -> Bool {
        guard !pending, !accounts.isEmpty,
              lastAttempt.map({ now.timeIntervalSince($0) >= 600 }) ?? true,
              accounts.contains(where: { account in
                  let checkedAt = account.limits.flatMap { parseDate($0.checkedAt) } ?? startedAt
                  return now.timeIntervalSince(checkedAt) >= 600
              }) else { return false }
        lastAttempt = now
        pending = true
        return true
    }
}

struct ConfigEvent: Decodable {
    struct Provider: Decodable {
        struct Auth: Decodable { let email: String?; let label: String? }
        let instanceId: String; let driver: String; let displayName: String?
        let enabled: Bool; let auth: Auth; let usageLimits: Limits?
    }
    struct Source: Decodable {
        struct Entry: Decodable {
            let id: String; let driver: String; let email: String?; let plan: String?; let usageLimits: Limits
        }
        let id: String; let label: String; let accounts: [Entry]; let error: String?
    }
    struct Config: Decodable { let providers: [Provider] }
    struct Payload: Decodable { let providers: [Provider]?; let sources: [Source]? }
    let type: String
    let config: Config?
    let payload: Payload?
}

struct Quotas {
    var native: [Account] = []
    var external: [Account] = []
    var accounts: [Account] {
        let nativeOnly = native.filter { account in
            guard account.limits?.unavailable?.reason != "unsupported" else { return false }
            return !external.contains { other in
                other.driver == account.driver && account.email != nil && other.email?.lowercased() == account.email?.lowercased()
            }
        }
        return (nativeOnly + external).sorted { ($0.email ?? $0.id).localizedStandardCompare($1.email ?? $1.id) == .orderedAscending }
    }

    mutating func apply(_ event: ConfigEvent) {
        if let providers = event.config?.providers ?? event.payload?.providers {
            native = providers.filter { $0.enabled && ["codex", "claudeAgent"].contains($0.driver) }.map { p in
                Account(id: "native:\(p.instanceId)", driver: p.driver, name: p.displayName ?? (p.driver == "codex" ? "Codex" : "Claude"), email: p.auth.email, plan: p.auth.label, source: "T3 Code", limits: p.usageLimits, failed: p.usageLimits?.unavailable != nil)
            }.map { preserve($0, previous: native) }
        }
        if let sources = event.payload?.sources {
            external = sources.flatMap { source -> [Account] in
                if source.error != nil && source.accounts.isEmpty {
                    return external.filter { $0.id.hasPrefix("source:\(source.id):") }.map { var old = $0; old.failed = true; return old }
                }
                return source.accounts.filter { ["codex", "claude", "claudeAgent"].contains($0.driver) }.map { a in
                    preserve(Account(id: "source:\(source.id):\(a.id)", driver: a.driver == "codex" ? "codex" : "claudeAgent", name: a.driver == "codex" ? "Codex" : "Claude", email: a.email, plan: a.plan, source: source.label, limits: a.usageLimits, failed: source.error != nil || a.usageLimits.unavailable != nil), previous: external)
                }
            }
        }
    }

    private func preserve(_ account: Account, previous: [Account]) -> Account {
        var account = account
        if account.failed, account.limits?.unavailable?.reason != "unsupported", let old = previous.first(where: { $0.id == account.id }), !(old.limits?.windows.isEmpty ?? true) {
            account.limits = old.limits
        }
        return account
    }
}
