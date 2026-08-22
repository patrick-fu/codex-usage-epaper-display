import Foundation

enum ProductStateCodecError: Error, Equatable, Sendable {
    case corrupt
    case unsupportedSchema
}

enum ProductStateDecodeResult: Equatable, Sendable {
    case state(ProductState)
    case unsupportedSchema
}

enum ProductStateCodec {
    static let rootKeys: Set<String> = [
        "schemaVersion", "setupDone", "boundDisplay", "preferences", "sources", "refreshRecord",
    ]
    static let preferenceKeys: Set<String> = [
        "displayStyle", "modules", "quotaOrder", "title", "tpsWindowMinutes",
        "dateFormat", "redAccent", "redThreshold", "language", "customCodexPath",
    ]
    static let moduleKeys: Set<String> = [
        "title", "plan", "quota", "today", "weekTokens", "cache", "tps", "updated", "status",
    ]
    static let sourceKeys: Set<String> = ["account", "localActivity"]
    static let accountKeys: Set<String> = [
        "lastSuccessfulObservationAt", "availability", "failure", "planType", "windows",
    ]
    static let localKeys: Set<String> = [
        "lastSuccessfulObservationAt", "availability", "failure",
    ]
    static let refreshKeys: Set<String> = [
        "lastSucceededFingerprint", "lastSuccessfulRefreshAt",
    ]
    static let boundKeys: Set<String> = ["identifier", "displayName"]
    static let windowKeys: Set<String> = ["slot", "usedPercent", "windowDurationMins", "resetsAt"]
    static let accountFailures: Set<String> = [
        "binaryMissing", "versionTooOld", "transportStart", "transportExit", "invalidJSON",
        "protocolIncompatible", "authRequired", "backendUnauthorized", "backendForbidden",
        "rateLimitUnavailable", "overloaded", "timeout", "schemaInvalid", "unknown",
    ]
    static let localFailures: Set<String> = [
        "sourceUnavailable", "sourceUnreadable", "sourcePermissionDenied", "sourceMalformed",
        "sourcePartialTail", "sourceRollbackRebuild", "sourceScanTimeout", "unknown",
    ]

    static func encode(_ state: ProductState) throws -> Data {
        let prepared = try state.preparedForWrite()
        let object = encodeRoot(prepared)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode(_ data: Data) throws -> ProductStateDecodeResult {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ProductStateCodecError.corrupt
        }
        guard let root = json as? [String: Any] else {
            throw ProductStateCodecError.corrupt
        }
        guard let schemaVersion = JSONValue.int(root["schemaVersion"]) else {
            throw ProductStateCodecError.corrupt
        }
        if schemaVersion > ProductState.currentSchemaVersion {
            return .unsupportedSchema
        }
        guard schemaVersion == ProductState.currentSchemaVersion else {
            throw ProductStateCodecError.corrupt
        }
        try JSONValue.requireExactKeys(root, rootKeys)
        let preferences = try decodePreferences(root["preferences"])
        let sources = try JSONValue.object(root["sources"], keys: sourceKeys)
        let account = try decodeAccount(sources["account"])
        let local = try decodeLocal(sources["localActivity"])
        let refresh = try decodeRefresh(root["refreshRecord"])
        let bound = try decodeBoundDisplay(root["boundDisplay"])
        guard let setupDone = JSONValue.bool(root["setupDone"]) else {
            throw ProductStateCodecError.corrupt
        }
        var state = ProductState(
            schemaVersion: schemaVersion,
            setupDone: setupDone,
            boundDisplay: bound,
            preferences: preferences,
            account: account,
            localActivity: local,
            refreshRecord: refresh
        )
        do {
            state = try state.preparedForWrite()
        } catch {
            throw ProductStateCodecError.corrupt
        }
        return .state(state)
    }

    private static func encodeRoot(_ state: ProductState) -> [String: Any] {
        [
            "schemaVersion": state.schemaVersion,
            "setupDone": state.setupDone,
            "boundDisplay": encodeBound(state.boundDisplay),
            "preferences": encodePreferences(state.preferences),
            "sources": [
                "account": encodeAccount(state.account),
                "localActivity": encodeLocal(state.localActivity),
            ],
            "refreshRecord": [
                "lastSucceededFingerprint": encodeOptional(state.refreshRecord.lastSucceededFingerprint),
                "lastSuccessfulRefreshAt": encodeOptional(state.refreshRecord.lastSuccessfulRefreshAt),
            ],
        ]
    }

    private static func encodePreferences(_ preferences: DisplayPreferences) -> [String: Any] {
        [
            "displayStyle": preferences.displayStyle.rawValue,
            "modules": [
                "title": preferences.modules.title,
                "plan": preferences.modules.plan,
                "quota": preferences.modules.quota,
                "today": preferences.modules.today,
                "weekTokens": preferences.modules.weekTokens,
                "cache": preferences.modules.cache,
                "tps": preferences.modules.tps,
                "updated": preferences.modules.updated,
                "status": preferences.modules.status,
            ],
            "quotaOrder": preferences.quotaOrder.rawValue,
            "title": preferences.title,
            "tpsWindowMinutes": preferences.tpsWindowMinutes,
            "dateFormat": preferences.dateFormat.rawValue,
            "redAccent": preferences.redAccent.rawValue,
            "redThreshold": preferences.redThreshold,
            "language": preferences.language.rawValue,
            "customCodexPath": encodeOptional(preferences.customCodexPath),
        ]
    }

    private static func encodeAccount(_ account: AccountSourceRecord) -> [String: Any] {
        [
            "lastSuccessfulObservationAt": encodeOptional(account.lastSuccessfulObservationAt),
            "availability": account.availability.rawValue,
            "failure": encodeOptional(account.failure),
            "planType": encodeOptional(account.planType),
            "windows": account.windows.map { window in
                [
                    "slot": window.slot,
                    "usedPercent": window.usedPercent,
                    "windowDurationMins": window.windowDurationMins,
                    "resetsAt": window.resetsAt,
                ] as [String: Any]
            },
        ]
    }

    private static func encodeLocal(_ local: LocalActivitySourceRecord) -> [String: Any] {
        [
            "lastSuccessfulObservationAt": encodeOptional(local.lastSuccessfulObservationAt),
            "availability": local.availability.rawValue,
            "failure": encodeOptional(local.failure),
        ]
    }

    private static func encodeBound(_ bound: BoundDisplayRecord?) -> Any {
        guard let bound else {
            return NSNull()
        }
        return [
            "identifier": bound.identifier,
            "displayName": encodeOptional(bound.displayName),
        ]
    }

    private static func encodeOptional(_ value: String?) -> Any {
        value ?? NSNull()
    }

    private static func encodeOptional(_ value: Int?) -> Any {
        value ?? NSNull()
    }

    private static func decodePreferences(_ raw: Any?) throws -> DisplayPreferences {
        let object = try JSONValue.object(raw, keys: preferenceKeys)
        guard let displayStyle = DisplayStyle(rawValue: try JSONValue.string(object["displayStyle"])),
              let quotaOrder = QuotaOrder(rawValue: try JSONValue.string(object["quotaOrder"])),
              let dateFormat = DateFormatPreference(rawValue: try JSONValue.string(object["dateFormat"])),
              let redAccent = RedAccent(rawValue: try JSONValue.string(object["redAccent"])),
              let language = InterfaceLanguagePreference(rawValue: try JSONValue.string(object["language"]))
        else {
            throw ProductStateCodecError.corrupt
        }
        let modulesObject = try JSONValue.object(object["modules"], keys: moduleKeys)
        let modules = DisplayModules(
            title: try JSONValue.requireBool(modulesObject["title"]),
            plan: try JSONValue.requireBool(modulesObject["plan"]),
            quota: try JSONValue.requireBool(modulesObject["quota"]),
            today: try JSONValue.requireBool(modulesObject["today"]),
            weekTokens: try JSONValue.requireBool(modulesObject["weekTokens"]),
            cache: try JSONValue.requireBool(modulesObject["cache"]),
            tps: try JSONValue.requireBool(modulesObject["tps"]),
            updated: try JSONValue.requireBool(modulesObject["updated"]),
            status: try JSONValue.requireBool(modulesObject["status"])
        )
        let customPath: String?
        if JSONValue.isNull(object["customCodexPath"]) {
            customPath = nil
        } else {
            customPath = try JSONValue.string(object["customCodexPath"])
        }
        return DisplayPreferences(
            displayStyle: displayStyle,
            modules: modules,
            quotaOrder: quotaOrder,
            title: try JSONValue.string(object["title"]),
            tpsWindowMinutes: try JSONValue.requireInt(object["tpsWindowMinutes"]),
            dateFormat: dateFormat,
            redAccent: redAccent,
            redThreshold: try JSONValue.requireInt(object["redThreshold"]),
            language: language,
            customCodexPath: customPath
        )
    }

    private static func decodeAccount(_ raw: Any?) throws -> AccountSourceRecord {
        let object = try JSONValue.object(raw, keys: accountKeys)
        let failure: String?
        if JSONValue.isNull(object["failure"]) {
            failure = nil
        } else {
            failure = try JSONValue.string(object["failure"])
            guard accountFailures.contains(failure ?? "") else {
                throw ProductStateCodecError.corrupt
            }
        }
        let planType: String?
        if JSONValue.isNull(object["planType"]) {
            planType = nil
        } else {
            planType = try JSONValue.string(object["planType"])
        }
        guard let availability = PersistedAvailability(rawValue: try JSONValue.string(object["availability"])) else {
            throw ProductStateCodecError.corrupt
        }
        let windowsRaw = try JSONValue.array(object["windows"])
        let windows = try windowsRaw.map(decodeWindow)
        return AccountSourceRecord(
            lastSuccessfulObservationAt: try JSONValue.optionalInt(object["lastSuccessfulObservationAt"]),
            availability: availability,
            failure: failure,
            planType: planType,
            windows: windows
        )
    }

    private static func decodeLocal(_ raw: Any?) throws -> LocalActivitySourceRecord {
        let object = try JSONValue.object(raw, keys: localKeys)
        let failure: String?
        if JSONValue.isNull(object["failure"]) {
            failure = nil
        } else {
            failure = try JSONValue.string(object["failure"])
            guard localFailures.contains(failure ?? "") else {
                throw ProductStateCodecError.corrupt
            }
        }
        guard let availability = PersistedAvailability(rawValue: try JSONValue.string(object["availability"])) else {
            throw ProductStateCodecError.corrupt
        }
        return LocalActivitySourceRecord(
            lastSuccessfulObservationAt: try JSONValue.optionalInt(object["lastSuccessfulObservationAt"]),
            availability: availability,
            failure: failure
        )
    }

    private static func decodeRefresh(_ raw: Any?) throws -> RefreshRecord {
        let object = try JSONValue.object(raw, keys: refreshKeys)
        let fingerprint: String?
        if JSONValue.isNull(object["lastSucceededFingerprint"]) {
            fingerprint = nil
        } else {
            fingerprint = try JSONValue.string(object["lastSucceededFingerprint"])
        }
        return RefreshRecord(
            lastSucceededFingerprint: fingerprint,
            lastSuccessfulRefreshAt: try JSONValue.optionalInt(object["lastSuccessfulRefreshAt"])
        )
    }

    private static func decodeBoundDisplay(_ raw: Any?) throws -> BoundDisplayRecord? {
        if JSONValue.isNull(raw) {
            return nil
        }
        let object = try JSONValue.object(raw, keys: boundKeys)
        let name: String?
        if JSONValue.isNull(object["displayName"]) {
            name = nil
        } else {
            name = try JSONValue.string(object["displayName"])
        }
        let identifier = try JSONValue.string(object["identifier"])
        guard !identifier.isEmpty else {
            throw ProductStateCodecError.corrupt
        }
        return BoundDisplayRecord(identifier: identifier, displayName: name)
    }

    private static func decodeWindow(_ raw: Any) throws -> UsageWindowRecord {
        let object = try JSONValue.object(raw, keys: windowKeys)
        let slot = try JSONValue.string(object["slot"])
        guard slot == "primary" || slot == "secondary" else {
            throw ProductStateCodecError.corrupt
        }
        let used = try JSONValue.requireDouble(object["usedPercent"])
        guard used.isFinite, used >= 0, used <= 100 else {
            throw ProductStateCodecError.corrupt
        }
        let duration = try JSONValue.requireInt(object["windowDurationMins"])
        guard duration > 0 else {
            throw ProductStateCodecError.corrupt
        }
        return UsageWindowRecord(
            slot: slot,
            usedPercent: used,
            windowDurationMins: duration,
            resetsAt: try JSONValue.requireInt(object["resetsAt"])
        )
    }
}

private enum JSONValue {
    static func requireExactKeys(_ object: [String: Any], _ expected: Set<String>) throws {
        guard Set(object.keys) == expected else {
            throw ProductStateCodecError.corrupt
        }
    }

    static func object(_ raw: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let object = raw as? [String: Any] else {
            throw ProductStateCodecError.corrupt
        }
        try requireExactKeys(object, keys)
        return object
    }

    static func array(_ raw: Any?) throws -> [Any] {
        guard let array = raw as? [Any] else {
            throw ProductStateCodecError.corrupt
        }
        return array
    }

    static func isNull(_ raw: Any?) -> Bool {
        raw == nil || raw is NSNull
    }

    static func string(_ raw: Any?) throws -> String {
        guard let value = raw as? String else {
            throw ProductStateCodecError.corrupt
        }
        return value
    }

    static func bool(_ raw: Any?) -> Bool? {
        guard let raw else {
            return nil
        }
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        return nil
    }

    static func requireBool(_ raw: Any?) throws -> Bool {
        guard let value = bool(raw) else {
            throw ProductStateCodecError.corrupt
        }
        return value
    }

    static func int(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite, doubleValue.rounded(.towardZero) == doubleValue else {
            return nil
        }
        return number.intValue
    }

    static func requireInt(_ raw: Any?) throws -> Int {
        guard let value = int(raw) else {
            throw ProductStateCodecError.corrupt
        }
        return value
    }

    static func optionalInt(_ raw: Any?) throws -> Int? {
        if isNull(raw) {
            return nil
        }
        return try requireInt(raw)
    }

    static func requireDouble(_ raw: Any?) throws -> Double {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ProductStateCodecError.corrupt
        }
        let value = number.doubleValue
        guard value.isFinite else {
            throw ProductStateCodecError.corrupt
        }
        return value
    }
}
