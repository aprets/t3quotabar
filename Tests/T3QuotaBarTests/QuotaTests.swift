import Testing
import Foundation
@testable import T3QuotaBar

struct QuotaTests {
    @Test func staleQuotaRefreshWaitsTenMinutesAndDoesNotOverlapOrRetryEarly() throws {
        let now = Date()
        let limits = try JSONDecoder().decode(Limits.self, from: Data("""
        {"checkedAt":"\(ISO8601DateFormatter().string(from: now))","windows":[]}
        """.utf8))
        let account = Account(id: "a", driver: "claudeAgent", name: "Claude", email: nil, plan: nil, source: "CPA", limits: limits, failed: false)
        var schedule = QuotaRefreshSchedule()
        let empty = schedule.beginIfDue(accounts: [], now: now.addingTimeInterval(601))
        #expect(!empty)
        let fresh = schedule.beginIfDue(accounts: [account], now: now.addingTimeInterval(599))
        #expect(!fresh)
        let stale = schedule.beginIfDue(accounts: [account], now: now.addingTimeInterval(601))
        #expect(stale)
        let overlap = schedule.beginIfDue(accounts: [account], now: now.addingTimeInterval(1202))
        #expect(!overlap)
        schedule.pending = false
        let earlyRetry = schedule.beginIfDue(accounts: [account], now: now.addingTimeInterval(1199))
        #expect(!earlyRetry)
        let retry = schedule.beginIfDue(accounts: [account], now: now.addingTimeInterval(1202))
        #expect(retry)
        schedule.pending = false
        var refreshed = account
        refreshed.limits = try JSONDecoder().decode(Limits.self, from: Data("""
        {"checkedAt":"\(ISO8601DateFormatter().string(from: now.addingTimeInterval(1790)))","windows":[]}
        """.utf8))
        let updated = schedule.beginIfDue(accounts: [refreshed], now: now.addingTimeInterval(1810))
        #expect(!updated)
    }

    @Test func imminentResetCreditShortensThePaceWindow() throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Two of seven days elapsed with 40% used: well ahead of the natural clock.
        func limits(creditExpiry: TimeInterval?) throws -> Limits {
            let credits = creditExpiry.map { ",\"resetCredits\":{\"availableCount\":1,\"nextExpiresAt\":\"\(formatter.string(from: now.addingTimeInterval($0)))\"}" } ?? ""
            return try JSONDecoder().decode(Limits.self, from: Data("""
            {"checkedAt":"\(formatter.string(from: now))","windows":[{"id":"primary","kind":"weekly","label":"Weekly","usedPercent":40,"resetsAt":"\(formatter.string(from: now.addingTimeInterval(5 * 86_400)))","windowDurationMins":10080}]\(credits)}
            """.utf8))
        }
        let natural = try limits(creditExpiry: nil)
        let naturalPace = try #require(natural.windows[0].pace(now: now, creditReset: natural.creditReset))
        #expect(abs(naturalPace.expectedUsed - 200.0 / 7) < 0.01)
        #expect(naturalPace.reserve < -5)  // ahead of pace
        // The balancer redeems the credit in an hour, so the window effectively ends then: 2d of 2d 1h elapsed.
        let soon = try limits(creditExpiry: 3600)
        let soonPace = try #require(soon.windows[0].pace(now: now, creditReset: soon.creditReset))
        #expect(soonPace.expectedUsed > 97)
        #expect(soonPace.reserve > 5)  // under pace
        #expect(abs(soonPace.remainingTime - 3600) < 1)
        // A credit expiring after the natural reset changes nothing.
        let late = try limits(creditExpiry: 20 * 86_400)
        let latePace = try #require(late.windows[0].pace(now: now, creditReset: late.creditReset))
        #expect(abs(latePace.expectedUsed - naturalPace.expectedUsed) < 0.01)
        // The card promotes the banked reset to the header and demotes the natural one to the pace line.
        let account = Account(id: "codex", driver: "codex", name: "Codex", email: nil, plan: nil, source: "CPA", limits: soon, failed: false)
        let metric = account.menuCard(now: now, connected: true).metrics[0]
        #expect(metric.detailLeftText?.hasSuffix("in reserve") == true)
        #expect(metric.resetText?.hasPrefix("Banked reset in") == true)
        #expect(metric.detailRightText?.hasPrefix("Normal reset in 5d") == true)
        // A credit that expires after the natural reset leaves the header alone.
        let lateAccount = Account(id: "codex2", driver: "codex", name: "Codex", email: nil, plan: nil, source: "CPA", limits: late, failed: false)
        let lateMetric = lateAccount.menuCard(now: now, connected: true).metrics[0]
        #expect(lateMetric.resetText?.hasPrefix("Resets in 5d") == true)
        #expect(lateMetric.detailRightText?.hasPrefix("Runs out") == true)
    }

    @Test func bothCodexAccountsRemainDistinctAndShowRemainingNotUsed() throws {
        let json = """
        {"type":"usageLimitSourcesUpdated","payload":{"sources":[{"id":"cpa","label":"CPA","accounts":[
        {"id":"one","driver":"codex","usageLimits":{"checkedAt":"2026-09-11T12:00:00Z","windows":[{"id":"weekly","kind":"weekly","label":"Weekly","usedPercent":30}]}},
        {"id":"two","driver":"codex","usageLimits":{"checkedAt":"2026-09-11T12:00:00Z","windows":[{"id":"weekly","kind":"weekly","label":"Weekly","usedPercent":31}]}}
        ]}]}}
        """
        var quotas = Quotas()
        quotas.apply(try JSONDecoder().decode(ConfigEvent.self, from: Data(json.utf8)))
        #expect(quotas.accounts.map(\.compact) == ["70%", "69%"])
        #expect(Set(quotas.accounts.map(\.id)).count == 2)
        let failure = """
        {"type":"usageLimitSourcesUpdated","payload":{"sources":[{"id":"cpa","label":"CPA","accounts":[],"error":"offline"}]}}
        """
        quotas.apply(try JSONDecoder().decode(ConfigEvent.self, from: Data(failure.utf8)))
        #expect(quotas.accounts.map(\.compact) == ["70%", "69%"])
        #expect(quotas.accounts.allSatisfy { $0.failed })
    }

    @Test func missingFableDoesNotReuseWeekly() throws {
        let limits = try JSONDecoder().decode(Limits.self, from: Data("""
        {"checkedAt":"2026-09-11T12:00:00Z","windows":[{"id":"seven_day","kind":"weekly","label":"Weekly","usedPercent":6}]}
        """.utf8))
        let account = Account(id: "a", driver: "claudeAgent", name: "Claude", email: nil, plan: nil, source: "CPA", limits: limits, failed: false)
        #expect(account.compact == "5h ? F ?")
        #expect(account.weekly?.remaining == 94)
    }

    @Test func duplicateNativeAccountIsHiddenButOtherEmailsRemain() {
        let native = Account(id: "native:a", driver: "codex", name: "Codex", email: "ONE@example.com", plan: nil, source: "T3", limits: nil, failed: false)
        let first = Account(id: "source:a", driver: "codex", name: "Codex", email: "one@example.com", plan: nil, source: "CPA", limits: nil, failed: false)
        let second = Account(id: "source:b", driver: "codex", name: "Codex", email: "two@example.com", plan: nil, source: "CPA", limits: nil, failed: false)
        let quotas = Quotas(native: [native], external: [first, second])
        #expect(quotas.accounts.map(\.id) == ["source:a", "source:b"])
    }

    @Test func modelScopedWeeklyDoesNotMasqueradeAsGeneralClaudeWeekly() throws {
        let limits = try JSONDecoder().decode(Limits.self, from: Data("""
        {"checkedAt":"2026-09-11T12:00:00Z","windows":[{"id":"seven_day_sonnet","kind":"weekly","label":"Weekly · Sonnet","usedPercent":6}]}
        """.utf8))
        let account = Account(id: "a", driver: "claudeAgent", name: "Claude", email: nil, plan: nil, source: "CPA", limits: limits, failed: false)
        #expect(account.compact == "5h ? F ?")
        #expect(account.weekly == nil)
    }
}
