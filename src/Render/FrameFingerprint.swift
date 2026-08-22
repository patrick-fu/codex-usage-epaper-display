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
        let json = CanonicalJSON.stringify(document(model))
        let digest = SHA256.hash(data: Data(json.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func document(_ model: QuotaFocusFrameModel) -> CanonicalJSON.Value {
        var visible: [CanonicalJSON.Value] = [
            .object([
                "id": .string("title"),
                "value": .string(model.title)
            ])
        ]
        if model.showPlan {
            visible.append(.object([
                "id": .string("plan"),
                "value": model.plan.map(CanonicalJSON.Value.string) ?? .null
            ]))
        }
        if let hero = model.hero {
            visible.append(visibleObject(hero, role: "hero"))
        }
        for field in model.ticker {
            visible.append(visibleObject(field, role: "ticker"))
        }

        let modules = model.preferences.modules
        return .object([
            "v": .int(1),
            "language": .string(model.languageCode),
            "style": .string(model.preferences.displayStyle.rawValue),
            "title": .string(model.preferences.title),
            "quotaOrder": .string(model.preferences.quotaOrder.rawValue),
            "dateFormat": .string(model.preferences.dateFormat.rawValue),
            "redAccent": .string(model.preferences.redAccent.rawValue),
            "redThreshold": .string(String(model.preferences.redThreshold)),
            "tpsWindowMinutes": .string(String(model.preferences.tpsWindowMinutes)),
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
            "accountAvailability": .string(model.accountAvailability),
            "accountFailure": model.accountFailure.map(CanonicalJSON.Value.string) ?? .null,
            "localAvailability": .string(model.localAvailability),
            "localFailure": model.localFailure.map(CanonicalJSON.Value.string) ?? .null,
            "localCoverageComplete": .bool(model.localCoverageComplete),
            "visible": .array(visible)
        ])
    }

    private static func visibleObject(
        _ field: QuotaFocusFrameModel.Field,
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
