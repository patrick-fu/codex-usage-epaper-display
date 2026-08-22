import Foundation

enum MenuIdentity: String, Sendable, Equatable {
    case statusSummary
    case refreshNow
    case findAndBindDisplay
    case unbindDisplay
    case displayStyle
    case displayStyleBalanced
    case displayStyleQuotaFocus
    case displayStyleActivityFocus
    case settings
    case configureWakeupPin
    case rebuildLocalMetrics
    case resetUsageInkData
    case about
    case quit
}

struct MenuItemSpec: Sendable, Equatable {
    var identity: MenuIdentity
    var title: String
    var isEnabled: Bool
    var isChecked: Bool
    var children: [MenuItemSpec]

    init(
        identity: MenuIdentity,
        title: String,
        isEnabled: Bool = true,
        isChecked: Bool = false,
        children: [MenuItemSpec] = []
    ) {
        self.identity = identity
        self.title = title
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.children = children
    }
}

enum MenuBuilder {
    static func items(from snapshot: RuntimeSnapshot) -> [MenuItemSpec] {
        var items: [MenuItemSpec] = [
            MenuItemSpec(
                identity: .statusSummary,
                title: snapshot.statusSummary,
                isEnabled: false
            ),
            MenuItemSpec(identity: .refreshNow, title: "Refresh Now"),
        ]

        switch snapshot.binding {
        case .unbound:
            items.append(
                MenuItemSpec(identity: .findAndBindDisplay, title: "Find and Bind Display…")
            )
        case .bound:
            items.append(
                MenuItemSpec(identity: .unbindDisplay, title: "Unbind Display…")
            )
        }

        items.append(displayStyleItem(current: snapshot.displayStyle))
        items.append(MenuItemSpec(identity: .settings, title: "Settings…"))

        if snapshot.hasReadyWakeupConfiguration {
            items.append(
                MenuItemSpec(identity: .configureWakeupPin, title: "Configure Wakeup Pin…")
            )
        }

        items.append(contentsOf: [
            MenuItemSpec(identity: .rebuildLocalMetrics, title: "Rebuild Local Metrics…"),
            MenuItemSpec(identity: .resetUsageInkData, title: "Reset UsageInk Data…"),
            MenuItemSpec(identity: .about, title: "About UsageInk"),
            MenuItemSpec(identity: .quit, title: "Quit UsageInk"),
        ])
        return items
    }

    private static func displayStyleItem(current: DisplayStyle) -> MenuItemSpec {
        MenuItemSpec(
            identity: .displayStyle,
            title: "Display Style",
            children: DisplayStyle.allCases.map { style in
                MenuItemSpec(
                    identity: identity(for: style),
                    title: style.menuTitle,
                    isChecked: style == current
                )
            }
        )
    }

    private static func identity(for style: DisplayStyle) -> MenuIdentity {
        switch style {
        case .balanced:
            return .displayStyleBalanced
        case .quotaFocus:
            return .displayStyleQuotaFocus
        case .activityFocus:
            return .displayStyleActivityFocus
        }
    }
}
