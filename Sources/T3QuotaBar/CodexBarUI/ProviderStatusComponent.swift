// Derived from CodexBar, MIT license. See PROVENANCE.md.
// Source revision: 7ba403f26df6965b118f157c8b9883f5d5836a57
import Foundation

enum ProviderStatusIndicator: String {
    case none
    case minor
    case major
    case critical
    case maintenance
    case unknown

    var hasIssue: Bool {
        switch self {
        case .none: false
        default: true
        }
    }

    var label: String {
        switch self {
        case .none: L("status_operational")
        case .minor: L("status_partial_outage")
        case .major: L("status_major_outage")
        case .critical: L("status_critical_issue")
        case .maintenance: L("status_maintenance")
        case .unknown: L("status_unknown")
        }
    }
}

struct ProviderStatus {
    let indicator: ProviderStatusIndicator
    let description: String?
    let updatedAt: Date?
}

/// A single component/service row on a statuspage.io-style status page
/// (e.g. "Codex API", "CLI", "FedRAMP") with its current state. A row with non-empty
/// `children` is a component group and renders as an expandable dropdown.
struct ProviderStatusComponent: Identifiable, Equatable {
    let id: String
    let name: String
    let indicator: ProviderStatusIndicator
    /// Raw provider status. The display label is localized when the row renders so changing
    /// the app language does not require another network refresh.
    let status: String
    /// Child rows for a component group; empty for leaf components.
    var children: [ProviderStatusComponent] = []

    var isGroup: Bool {
        !self.children.isEmpty
    }

    var statusLabel: String {
        Self.label(forStatuspageStatus: self.status)
    }

    /// Maps a statuspage.io component `status` string to our indicator + display label.
    static func indicator(forStatuspageStatus status: String) -> ProviderStatusIndicator {
        switch status {
        case "operational": .none
        case "degraded_performance": .minor
        case "partial_outage": .major
        case "major_outage", "full_outage": .critical
        case "under_maintenance": .maintenance
        default: .unknown
        }
    }

    static func label(forStatuspageStatus status: String) -> String {
        switch status {
        case "operational": L("status_operational")
        case "degraded_performance": L("status_degraded")
        case "partial_outage": L("status_partial_outage")
        case "major_outage", "full_outage": L("status_major_outage")
        case "under_maintenance": L("status_maintenance")
        default: L("status_unknown")
        }
    }
}


enum StatusFeed {
    nonisolated static func parseIncidentIOSummary(
        data: Data)
        throws -> (status: ProviderStatus, components: [ProviderStatusComponent])
    {
        // The incident.io payload mirrors a deeply nested JSON shape; the response models follow it
        // 1:1 for clarity, which exceeds the default type-nesting depth.
        // swiftlint:disable nesting
        struct Response: Decodable {
            struct Summary: Decodable {
                struct AffectedComponent: Decodable {
                    let componentID: String
                    let status: String?
                    private enum CodingKeys: String, CodingKey {
                        case componentID = "component_id"
                        case status
                    }
                }

                struct Structure: Decodable {
                    struct Item: Decodable {
                        struct Group: Decodable {
                            struct Child: Decodable {
                                let componentID: String
                                let name: String?
                                let hidden: Bool?
                                private enum CodingKeys: String, CodingKey {
                                    case componentID = "component_id"
                                    case name, hidden
                                }
                            }

                            let id: String
                            let name: String?
                            let hidden: Bool?
                            let components: [Child]?
                        }

                        struct Component: Decodable {
                            let componentID: String
                            let name: String?
                            let hidden: Bool?
                            private enum CodingKeys: String, CodingKey {
                                case componentID = "component_id"
                                case name, hidden
                            }
                        }

                        let group: Group?
                        let component: Component?
                    }

                    let items: [Item]?
                }

                let affectedComponents: [AffectedComponent]?
                let structure: Structure?
                private enum CodingKeys: String, CodingKey {
                    case affectedComponents = "affected_components"
                    case structure
                }
            }

            let summary: Summary?
        }
        // swiftlint:enable nesting

        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let summary = response.summary,
              let items = summary.structure?.items,
              !items.isEmpty
        else {
            throw URLError(.cannotParseResponse)
        }

        var statusByID: [String: String] = [:]
        for affected in summary.affectedComponents ?? [] {
            statusByID[affected.componentID] = affected.status
        }

        func leaf(id: String, name: String) -> ProviderStatusComponent {
            let raw = statusByID[id] ?? "operational"
            return ProviderStatusComponent(
                id: id,
                name: name,
                indicator: ProviderStatusComponent.indicator(forStatuspageStatus: raw),
                status: raw)
        }

        var topLevel: [ProviderStatusComponent] = []
        for item in items {
            if let group = item.group, group.hidden != true {
                let children = (group.components ?? [])
                    .filter { $0.hidden != true }
                    .compactMap { child -> ProviderStatusComponent? in
                        guard let name = Self.normalizedStatusComponentName(child.name) else { return nil }
                        return leaf(id: child.componentID, name: name)
                    }
                guard let groupName = Self.normalizedStatusComponentName(group.name) else { continue }
                let worst = children.max { Self.indicatorRank($0.indicator) < Self.indicatorRank($1.indicator) }
                topLevel.append(ProviderStatusComponent(
                    id: group.id,
                    name: groupName,
                    indicator: worst?.indicator ?? .none,
                    status: worst?.status ?? "operational",
                    children: children))
            } else if let component = item.component,
                      component.hidden != true,
                      let name = Self.normalizedStatusComponentName(component.name)
            {
                topLevel.append(leaf(id: component.componentID, name: name))
            }
        }

        let leaves = topLevel.flatMap { $0.isGroup ? $0.children : [$0] }
        let overall = leaves.max { Self.indicatorRank($0.indicator) < Self.indicatorRank($1.indicator) }
        let status = ProviderStatus(
            indicator: overall?.indicator ?? .none,
            description: nil,
            updatedAt: nil)
        return (status, topLevel)
    }

    nonisolated static func parseStatuspageComponents(data: Data) throws -> [ProviderStatusComponent] {
        struct Response: Decodable {
            struct Component: Decodable {
                let id: String
                let name: String
                let status: String
                let group: Bool?
                let groupID: String?
                let position: Int?

                private enum CodingKeys: String, CodingKey {
                    case id, name, status, group, position
                    case groupID = "group_id"
                }
            }

            let components: [Component]?
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        let raw = (response.components ?? [])
            .filter { Self.normalizedStatusComponentName($0.name) != nil }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }

        func makeRow(
            _ component: Response.Component,
            children: [ProviderStatusComponent]) -> ProviderStatusComponent
        {
            ProviderStatusComponent(
                id: component.id,
                name: Self.normalizedStatusComponentName(component.name) ?? component.name,
                indicator: ProviderStatusComponent.indicator(forStatuspageStatus: component.status),
                status: component.status,
                children: children)
        }

        // Children keyed by their parent group id, preserving position order.
        var childrenByGroup: [String: [ProviderStatusComponent]] = [:]
        for component in raw where component.group != true {
            guard let groupID = component.groupID else { continue }
            childrenByGroup[groupID, default: []].append(makeRow(component, children: []))
        }

        // Top-level rows: groups (with their children) and ungrouped leaf components, in order.
        return raw.compactMap { component in
            if component.group == true {
                return makeRow(component, children: childrenByGroup[component.id] ?? [])
            }
            // Skip leaves that belong to a group; they are rendered inside the group's dropdown.
            if component.groupID != nil { return nil }
            return makeRow(component, children: [])
        }
    }

    private nonisolated static func normalizedStatusComponentName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    private nonisolated static func indicatorRank(_ indicator: ProviderStatusIndicator) -> Int {
        switch indicator {
        case .none: 0
        case .maintenance: 1
        case .minor: 2
        case .major: 3
        case .critical: 4
        case .unknown: 1
        }
    }

}
