import Foundation

enum PanelTrust: Sendable, Equatable {
    case invalid
    case assumed
}

enum PersistedAvailability: String, Sendable, Equatable {
    case unknown
    case fresh
    case stale
    case authRequired
    case unavailable
}

enum StorageClassification: String, Sendable, Equatable {
    case stateVersionUnsupported
    case stateCorrupt
    case stateWriteFailed
    case migrationFailed
    case unknown
}

struct BoundDisplayRecord: Sendable, Equatable {
    var identifier: String
    var displayName: String?
}

struct UsageWindowRecord: Sendable, Equatable {
    var slot: String
    var usedPercent: Double
    var windowDurationMins: Int
    var resetsAt: Int
}

struct AccountSourceRecord: Sendable, Equatable {
    var lastSuccessfulObservationAt: Int?
    var availability: PersistedAvailability
    var failure: String?
    var planType: String?
    var windows: [UsageWindowRecord]

    static let `default` = AccountSourceRecord(
        lastSuccessfulObservationAt: nil,
        availability: .unknown,
        failure: nil,
        planType: nil,
        windows: []
    )
}

struct LocalActivitySourceRecord: Sendable, Equatable {
    var lastSuccessfulObservationAt: Int?
    var availability: PersistedAvailability
    var failure: String?

    static let `default` = LocalActivitySourceRecord(
        lastSuccessfulObservationAt: nil,
        availability: .unknown,
        failure: nil
    )
}

struct RefreshRecord: Sendable, Equatable {
    var lastSucceededFingerprint: String?
    var lastSuccessfulRefreshAt: Int?

    static let `default` = RefreshRecord(
        lastSucceededFingerprint: nil,
        lastSuccessfulRefreshAt: nil
    )
}

struct ProductState: Sendable, Equatable {
    static let currentSchemaVersion = 1
    static let displayNameGraphemeLimit = 64

    var schemaVersion: Int
    var setupDone: Bool
    var boundDisplay: BoundDisplayRecord?
    var preferences: DisplayPreferences
    var account: AccountSourceRecord
    var localActivity: LocalActivitySourceRecord
    var refreshRecord: RefreshRecord

    static let `default` = ProductState(
        schemaVersion: currentSchemaVersion,
        setupDone: false,
        boundDisplay: nil,
        preferences: .default,
        account: .default,
        localActivity: .default,
        refreshRecord: .default
    )

    func preparedForWrite() throws -> ProductState {
        var state = self
        state.schemaVersion = Self.currentSchemaVersion
        state.preferences = try preferences.validated()
        if let bound = state.boundDisplay {
            state.boundDisplay = BoundDisplayRecord(
                identifier: bound.identifier,
                displayName: Self.sanitizedDisplayName(bound.displayName)
            )
        }
        if !state.preferences.modules.plan {
            state.account.planType = nil
        }
        return state
    }

    static func sanitizedDisplayName(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let withoutNewlines = raw
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        let trimmed = withoutNewlines.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return nil
        }
        if trimmed.count <= displayNameGraphemeLimit {
            return trimmed
        }
        return String(trimmed.prefix(displayNameGraphemeLimit))
    }
}

enum FirstRunDisclosure {
    static let bilingualText = """
    UsageInk keeps only two local stores for the current macOS user: versioned product state (state.json) and locally pseudonymous Codex activity facts (activity.sqlite). It reads only ${CODEX_HOME:-~/.codex}/sessions and ${CODEX_HOME:-~/.codex}/archived_sessions, and only token_count events. It does not read authentication material and does not send telemetry or upload data. The Bound Display is physically visible public output. Unbind, Rebuild Local Metrics, and Reset UsageInk Data require confirmation and do not change ~/.codex or device firmware. Backup exclusion is a request, not a Time Machine or backup guarantee. The local Codex app-server may contact OpenAI.

    UsageInk 仅为当前 macOS 用户保留两个本地存储：版本化产品状态（state.json）以及本机假名化的 Codex 活动事实（activity.sqlite）。它只读取 ${CODEX_HOME:-~/.codex}/sessions 与 ${CODEX_HOME:-~/.codex}/archived_sessions，且只接受 token_count 事件。它不读取认证材料，也不发送遥测或上传数据。绑定显示器是物理可见的公开输出。解除绑定、重建本机指标和重置 UsageInk 数据都需要确认，并且不会修改 ~/.codex 或设备固件。备份排除只是应用请求，不是对时间机器或其他备份产品的保证。本机 Codex app-server 可能自行联系 OpenAI。
    """
}
