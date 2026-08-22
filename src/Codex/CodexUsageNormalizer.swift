import Foundation

struct CodexNormalizedAccount: Sendable, Equatable {
    var isLoggedIn: Bool
    var authRequired: Bool
    var failure: CodexFailure?
    var planType: String?
}

enum CodexUsageNormalizer {
    static func account(from result: Any) -> Result<CodexNormalizedAccount, CodexFailure> {
        guard let object = jsonObject(result) else {
            return .failure(.schemaInvalid)
        }

        if object.keys.contains("requiresOpenaiAuth") {
            guard isJSONBool(object["requiresOpenaiAuth"]) else {
                return .failure(.schemaInvalid)
            }
        }

        guard object.keys.contains("account") else {
            return .failure(.authRequired)
        }
        let accountRaw = object["account"]
        if isNull(accountRaw) {
            return .failure(.authRequired)
        }
        guard let account = jsonObject(accountRaw) else {
            return .failure(.schemaInvalid)
        }

        let planType: String?
        if let rawPlan = account["planType"], !isNull(rawPlan) {
            planType = rawPlan as? String
        } else {
            planType = nil
        }

        return .success(
            CodexNormalizedAccount(
                isLoggedIn: true,
                authRequired: false,
                failure: nil,
                planType: planType
            )
        )
    }

    static func windows(from result: Any) -> Result<[UsageWindowObservation], CodexFailure> {
        guard let object = jsonObject(result) else {
            return .failure(.schemaInvalid)
        }

        switch selectSnapshot(object) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let snapshot):
            return .success(parseWindows(snapshot))
        }
    }

    private static func selectSnapshot(
        _ object: [String: Any]
    ) -> Result<[String: Any], CodexFailure> {
        if object.keys.contains("rateLimitsByLimitId") {
            let mapRaw = object["rateLimitsByLimitId"]
            if !isNull(mapRaw) {
                guard let map = jsonObject(mapRaw) else {
                    return .failure(.schemaInvalid)
                }
                if map.keys.contains("codex") {
                    let value = map["codex"]
                    if isNull(value) {
                        return .failure(.schemaInvalid)
                    }
                    guard let snapshot = jsonObject(value) else {
                        return .failure(.schemaInvalid)
                    }
                    return validateLimitId(snapshot)
                }
            }
        }

        guard object.keys.contains("rateLimits") else {
            return .failure(.schemaInvalid)
        }
        let topRaw = object["rateLimits"]
        if isNull(topRaw) {
            return .failure(.schemaInvalid)
        }
        guard let snapshot = jsonObject(topRaw) else {
            return .failure(.schemaInvalid)
        }
        return validateLimitId(snapshot)
    }

    private static func validateLimitId(
        _ snapshot: [String: Any]
    ) -> Result<[String: Any], CodexFailure> {
        guard snapshot.keys.contains("limitId"), !isNull(snapshot["limitId"]) else {
            return .success(snapshot)
        }
        guard let limitId = snapshot["limitId"] as? String, limitId == "codex" else {
            return .failure(.schemaInvalid)
        }
        return .success(snapshot)
    }

    private static func parseWindows(_ snapshot: [String: Any]) -> [UsageWindowObservation] {
        var windows: [UsageWindowObservation] = []
        if let primary = window(snapshot["primary"], slot: .primary) {
            windows.append(primary)
        }
        if let secondary = window(snapshot["secondary"], slot: .secondary) {
            windows.append(secondary)
        }
        return windows
    }

    private static func window(_ raw: Any?, slot: UsageWindowSlot) -> UsageWindowObservation? {
        if isNull(raw) {
            return nil
        }
        guard let object = jsonObject(raw) else {
            return nil
        }
        guard let usedPercent = jsonDouble(object["usedPercent"]),
              usedPercent.isFinite,
              usedPercent >= 0,
              usedPercent <= 100 else {
            return nil
        }
        guard let duration = jsonInt(object["windowDurationMins"]), duration > 0 else {
            return nil
        }
        guard let resetsAt = jsonInt(object["resetsAt"]), isValidUnixSeconds(resetsAt) else {
            return nil
        }
        return UsageWindowObservation(
            slot: slot,
            usedPercent: usedPercent,
            windowDurationMins: duration,
            resetsAt: resetsAt
        )
    }

    private static func isValidUnixSeconds(_ seconds: Int) -> Bool {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return year >= 1 && year <= 9999
    }

    private static func jsonObject(_ raw: Any?) -> [String: Any]? {
        raw as? [String: Any]
    }

    private static func isNull(_ raw: Any?) -> Bool {
        raw == nil || raw is NSNull
    }

    private static func isJSONBool(_ raw: Any?) -> Bool {
        if raw is Bool {
            return true
        }
        guard let number = raw as? NSNumber else {
            return false
        }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func jsonInt(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite, value.rounded(.towardZero) == value else {
            return nil
        }
        return number.intValue
    }

    private static func jsonDouble(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.doubleValue
    }
}
