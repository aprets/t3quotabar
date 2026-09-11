import Testing
import Foundation
@testable import T3QuotaBar

struct QuotaTests {
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
        #expect(account.compact == "5h ? W 94% F ?")
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
        #expect(account.compact == "5h ? W ? F ?")
    }
}
