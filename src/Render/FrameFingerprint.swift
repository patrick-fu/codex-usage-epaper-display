import CryptoKit
import Foundation

enum CanonicalJSON {
    indirect enum Value: Equatable {
        case int(Int)
        case string(String)
        case bool(Bool)
        case null
        case array([Value])
        case object([String: Value])
    }

    static func stringify(_ value: Value) -> String {
        switch value {
        case .int(let number):
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .null:
            return "null"
        case .string(let text):
            return "\"" + escape(text) + "\""
        case .array(let items):
            return "[" + items.map(stringify).joined(separator: ",") + "]"
        case .object(let object):
            let pairs = object.keys.sorted().map { key in
                stringify(.string(key)) + ":" + stringify(object[key] ?? .null)
            }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }

    private static func escape(_ text: String) -> String {
        var output = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output += String(scalar)
                }
            }
        }
        return output
    }
}

enum FrameFingerprint {
    static func hexSHA256(of model: QuotaFocusFrameModel) -> String {
        hexSHA256(document(model))
    }

    static func hexSHA256(of model: BalancedFrameModel) -> String {
        hexSHA256(document(model))
    }

    static func hexSHA256(of model: ActivityFocusFrameModel) -> String {
        hexSHA256(document(model))
    }

    static func document(_ model: QuotaFocusFrameModel) -> CanonicalJSON.Value {
        var fields: [(DisplayField, String)] = []
        if let hero = model.hero {
            fields.append((hero, "hero"))
        }
        for field in model.ticker {
            fields.append((field, "ticker"))
        }
        return document(
            languageCode: model.languageCode,
            preferences: model.preferences,
            title: model.title,
            showPlan: model.showPlan,
            plan: model.plan,
            accountAvailability: model.accountAvailability,
            accountFailure: model.accountFailure,
            localAvailability: model.localAvailability,
            localFailure: model.localFailure,
            localCoverageComplete: model.localCoverageComplete,
            visibleFields: fields
        )
    }

    static func document(_ model: BalancedFrameModel) -> CanonicalJSON.Value {
        document(
            languageCode: model.languageCode,
            preferences: model.preferences,
            title: model.title,
            showPlan: model.showPlan,
            plan: model.plan,
            accountAvailability: model.accountAvailability,
            accountFailure: model.accountFailure,
            localAvailability: model.localAvailability,
            localFailure: model.localFailure,
            localCoverageComplete: model.localCoverageComplete,
            visibleFields: model.entries.map { ($0, "body") }
        )
    }

    static func document(_ model: ActivityFocusFrameModel) -> CanonicalJSON.Value {
        var fields: [(DisplayField, String)] = []
        if let primary = model.primary {
            fields.append((primary, "primary"))
        }
        for field in model.secondary {
            fields.append((field, "secondary"))
        }
        for field in model.quotas {
            fields.append((field, "quota"))
        }
        return document(
            languageCode: model.languageCode,
            preferences: model.preferences,
            title: model.title,
            showPlan: model.showPlan,
            plan: model.plan,
            accountAvailability: model.accountAvailability,
            accountFailure: model.accountFailure,
            localAvailability: model.localAvailability,
            localFailure: model.localFailure,
            localCoverageComplete: model.localCoverageComplete,
            visibleFields: fields
        )
    }

    private static func hexSHA256(_ document: CanonicalJSON.Value) -> String {
        let json = CanonicalJSON.stringify(document)
        let digest = SHA256.hash(data: Data(json.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func document(
        languageCode: String,
        preferences: DisplayPreferences,
        title: String,
        showPlan: Bool,
        plan: String?,
        accountAvailability: String,
        accountFailure: String?,
        localAvailability: String,
        localFailure: String?,
        localCoverageComplete: Bool,
        visibleFields: [(DisplayField, String)]
    ) -> CanonicalJSON.Value {
        var visible: [CanonicalJSON.Value] = [
            .object([
                "id": .string("title"),
                "value": .string(title)
            ])
        ]
        if showPlan {
            visible.append(.object([
                "id": .string("plan"),
                "value": plan.map(CanonicalJSON.Value.string) ?? .null
            ]))
        }
        for (field, role) in visibleFields {
            visible.append(visibleObject(field, role: role))
        }

        let modules = preferences.modules
        return .object([
            "v": .int(1),
            "language": .string(languageCode),
            "style": .string(preferences.displayStyle.rawValue),
            "title": .string(preferences.title),
            "quotaOrder": .string(preferences.quotaOrder.rawValue),
            "dateFormat": .string(preferences.dateFormat.rawValue),
            "redAccent": .string(preferences.redAccent.rawValue),
            "redThreshold": .string(String(preferences.redThreshold)),
            "tpsWindowMinutes": .string(String(preferences.tpsWindowMinutes)),
            "modules": .object([
                "title": .bool(modules.title),
                "plan": .bool(modules.plan),
                "quota": .bool(modules.quota),
                "today": .bool(modules.today),
                "weekTokens": .bool(modules.weekTokens),
                "cache": .bool(modules.cache),
                "tps": .bool(modules.tps),
                "updated": .bool(modules.updated),
                "status": .bool(modules.status)
            ]),
            "accountAvailability": .string(accountAvailability),
            "accountFailure": accountFailure.map(CanonicalJSON.Value.string) ?? .null,
            "localAvailability": .string(localAvailability),
            "localFailure": localFailure.map(CanonicalJSON.Value.string) ?? .null,
            "localCoverageComplete": .bool(localCoverageComplete),
            "visible": .array(visible)
        ])
    }

    private static func visibleObject(
        _ field: DisplayField,
        role: String
    ) -> CanonicalJSON.Value {
        var object: [String: CanonicalJSON.Value] = [
            "id": .string(field.id),
            "role": .string(role),
            "availability": .string(field.availability),
            "value": field.semanticValue.map(CanonicalJSON.Value.string) ?? .null
        ]
        if let slot = field.slot {
            object["slot"] = .string(slot)
        }
        if let duration = field.windowDurationMins {
            object["windowDurationMins"] = .string(duration)
        }
        if let resetsAt = field.resetsAt {
            object["resetsAt"] = .string(resetsAt)
        } else if field.isQuota {
            object["resetsAt"] = .null
        }
        if let coverage = field.coverageComplete {
            object["coverageComplete"] = .bool(coverage)
        }
        return .object(object)
    }
}
