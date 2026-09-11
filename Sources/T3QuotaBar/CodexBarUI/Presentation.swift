// Derived from CodexBar, MIT license. See PROVENANCE.md.
// Source revision: 7ba403f26df6965b118f157c8b9883f5d5836a57
import Foundation

// English-only adapter for the copied CodexBar views.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let text: String
    switch key {
    case "usage_percent_suffix_left": text = "left"
    case "usage_percent_suffix_used": text = "used"
    case "quota_warnings_title": text = "Quota warnings"
    case "weekly_progress_work_days_title": text = "Work days"
    case "status_operational": text = "Operational"
    case "status_degraded": text = "Degraded performance"
    case "status_partial_outage": text = "Partial outage"
    case "status_major_outage": text = "Major outage"
    case "status_critical_issue": text = "Critical issue"
    case "status_maintenance": text = "Maintenance"
    case "status_unknown": text = "Status unknown"
    default: text = key
    }
    return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}

enum WorkdayTickAppearance { case hidden, subtle, highContrast }

enum UsageFormatter {
    private static func localized(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: key, arguments: arguments)
    }
    public static func percentText(_ percent: Double, suffix: String) -> String {
        let clamped = min(100, max(0, percent))
        if clamped > 0, clamped < 1 {
            return self.localized("<1%% %@", suffix)
        }
        return self.localized("%.0f%% %@", clamped, suffix)
    }

    public static func resetCountdownDescription(from date: Date, now: Date = .init()) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 1 { return "now" }

        let totalMinutes = max(1, Int(ceil(seconds / 60.0)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            if hours > 0 { return "in \(days)d \(hours)h" }
            if minutes > 0 { return "in \(days)d \(minutes)m" }
            return "in \(days)d"
        }
        if hours > 0 {
            if minutes > 0 { return "in \(hours)h \(minutes)m" }
            return "in \(hours)h"
        }
        return "in \(totalMinutes)m"
    }

}

struct CodexResetCreditPresentationItem: Equatable {
    let expiryText: String
    let compactExpiryText: String
}

struct CodexResetCreditsPresentation: Equatable {
    let text: String
    let items: [CodexResetCreditPresentationItem]

    var expirySummaryText: String {
        let visibleItems = self.items.prefix(4).map(\.compactExpiryText)
        let hiddenCount = self.items.count - visibleItems.count
        let suffix = hiddenCount > 0 ? ["+\(hiddenCount)"] : []
        return (visibleItems + suffix).joined(separator: " · ")
    }

    var helpText: String {
        self.items.enumerated().map { index, item in
            "\(index + 1). \(item.expiryText)"
        }.joined(separator: "\n")
    }

    var accessibilityLabel: String {
        [L("Limit Reset Credits"), self.text, self.helpText]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

}
