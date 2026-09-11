// Derived from CodexBar, MIT license. See PROVENANCE.md.
// Source revision: 7ba403f26df6965b118f157c8b9883f5d5836a57
import SwiftUI

struct UsageMenuCardView: View {
    struct Model {
        enum PercentStyle: String {
            case left
            case used

            var labelSuffix: String {
                switch self {
                case .left: L("usage_percent_suffix_left")
                case .used: L("usage_percent_suffix_used")
                }
            }

            var accessibilityLabel: String {
                switch self {
                case .left: L("Usage remaining")
                case .used: L("Usage used")
                }
            }
        }

        struct Metric: Identifiable {
            struct LinePresentation: Equatable {
                let titleText: String
                let resetText: String?
                let metaText: String?
            }

            let id: String
            let title: String
            let percent: Double
            let percentStyle: PercentStyle
            let statusText: String?
            let resetText: String?
            let detailText: String?
            let detailLeftText: String?
            let detailRightText: String?
            let pacePercent: Double?
            /// True when detailLeftText/detailRightText came from a pace forecast.
            let detailIsPaceDerived: Bool
            let paceOnTop: Bool
            let warningMarkerPercents: [Double]
            let workdayMarkerPercents: [Double]
            let workdayTickAppearance: WorkdayTickAppearance
            let cardStyle: Bool

            init(
                id: String,
                title: String,
                percent: Double,
                percentStyle: PercentStyle,
                statusText: String? = nil,
                resetText: String?,
                detailText: String?,
                detailLeftText: String?,
                detailRightText: String?,
                pacePercent: Double?,
                detailIsPaceDerived: Bool = false,
                paceOnTop: Bool,
                warningMarkerPercents: [Double] = [],
                workdayMarkerPercents: [Double] = [],
                workdayTickAppearance: WorkdayTickAppearance = .subtle,
                cardStyle: Bool = false)
            {
                self.id = id
                self.title = title
                self.percent = percent
                self.percentStyle = percentStyle
                self.statusText = statusText
                self.resetText = resetText
                self.detailText = detailText
                self.detailLeftText = detailLeftText
                self.detailRightText = detailRightText
                self.pacePercent = pacePercent
                self.detailIsPaceDerived = detailIsPaceDerived
                self.paceOnTop = paceOnTop
                self.warningMarkerPercents = warningMarkerPercents
                self.workdayMarkerPercents = workdayMarkerPercents
                self.workdayTickAppearance = workdayTickAppearance
                self.cardStyle = cardStyle
            }

            var percentLabel: String {
                UsageFormatter.percentText(self.percent, suffix: self.percentStyle.labelSuffix)
            }

            func linePresentation(title: String) -> LinePresentation {
                // Keep the title aligned with the configured used/remaining label semantics.
                let metaParts = [
                    self.detailLeftText,
                    self.detailRightText,
                ].compactMap { text -> String? in
                    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                        return nil
                    }
                    return text
                }
                return LinePresentation(
                    titleText: "\(title) \(self.percentLabel)",
                    resetText: self.resetText,
                    metaText: metaParts.isEmpty ? nil : metaParts.joined(separator: " · "))
            }
        }

        let providerName: String
        let email: String
        let subtitleText: String
        let isStale: Bool
        let planText: String?
        let metrics: [Metric]
        let codexResetCredits: CodexResetCreditsPresentation?
        let placeholder: String?
        let progressColor: Color
    }

    let model: Model
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageMenuCardHeaderView(model: self.model)
            Divider()
                .padding(.top, UsageMenuCardLayout.headerContentSpacing)
                .padding(.bottom, UsageMenuCardLayout.postHeaderDividerContentSpacing)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(self.model.metrics) { metric in
                    MetricRow(metric: metric, title: metric.title, progressColor: self.model.progressColor)
                }
                if let resetCredits = self.model.codexResetCredits {
                    if !self.model.metrics.isEmpty { Divider() }
                    CodexResetCreditsContent(presentation: resetCredits)
                }
                if let placeholder = self.model.placeholder {
                    Text(placeholder)
                        .foregroundStyle(MenuHighlightStyle.secondary(false))
                        .font(.subheadline)
                }
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.top, UsageMenuCardLayout.sectionTopPadding)
        .padding(.bottom, UsageMenuCardLayout.sectionBottomPadding)
        .frame(width: self.width, alignment: .leading)
    }
}

private struct UsageMenuCardHeaderView: View {
    let model: UsageMenuCardView.Model
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: UsageMenuCardLayout.headerLineSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: UsageMenuCardLayout.headerColumnSpacing) {
                Text(self.model.providerName).font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Spacer()
                Text(self.model.email).font(.subheadline)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(alignment: .firstTextBaseline, spacing: UsageMenuCardLayout.headerColumnSpacing) {
                Text(self.model.subtitleText)
                    .font(.footnote)
                    .foregroundStyle(self.model.isStale ? MenuHighlightStyle.error(self.isHighlighted) : MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer()
                if let plan = self.model.planText {
                    Text(plan)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            }
        }
    }
}
