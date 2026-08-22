import Foundation

enum BLELinkState: String, Sendable, Equatable {
    case unavailable
    case unbound
    case scanning
    case connecting
    case discovering
    case subscribing
    case awaitingConfig
    case initializing
    case ready
    case disconnected
    case unreachable

    func menuText(language: ResolvedInterfaceLanguage) -> String? {
        let english: String?
        let chinese: String?
        switch self {
        case .scanning:
            english = "Scanning for display"
            chinese = "正在扫描显示器"
        case .connecting:
            english = "Connecting to display"
            chinese = "正在连接显示器"
        case .discovering:
            english = "Discovering display"
            chinese = "正在发现显示器服务"
        case .subscribing:
            english = "Subscribing to display"
            chinese = "正在订阅显示器"
        case .awaitingConfig:
            english = "Waiting for display config"
            chinese = "等待显示器配置"
        case .initializing:
            english = "Initializing display"
            chinese = "正在初始化显示器"
        case .unavailable, .unreachable:
            english = "Display unavailable"
            chinese = "显示器不可用"
        case .unbound, .ready, .disconnected:
            return nil
        }
        return language == .english ? english : chinese
    }
}

enum BLEClassification: String, Sendable, Equatable {
    case bluetoothUnavailable
    case bluetoothUnauthorized
    case boundDisplayNotFound
    case connectFailed
    case serviceMissing
    case characteristicMissing
    case subscribeFailed
    case configTimeout
    case initTimeout
    case mtuInvalid
    case planeTimeout
    case refreshTimeout
    case disconnected
    case callbackAmbiguous
    case retryExhausted
    case firmwareIncompatible
    case unknown

    var showsDisplayUnavailable: Bool {
        switch self {
        case .firmwareIncompatible:
            return false
        case .bluetoothUnavailable, .bluetoothUnauthorized, .boundDisplayNotFound,
             .connectFailed, .serviceMissing, .characteristicMissing, .subscribeFailed,
             .configTimeout, .initTimeout, .mtuInvalid, .disconnected, .callbackAmbiguous,
             .retryExhausted, .unknown, .planeTimeout, .refreshTimeout:
            return true
        }
    }

    func menuText(language: ResolvedInterfaceLanguage) -> String {
        let english: String
        let chinese: String
        switch self {
        case .firmwareIncompatible:
            english = "Display firmware incompatible"
            chinese = "显示器固件不兼容"
        case .bluetoothUnauthorized:
            english = "Bluetooth unauthorized"
            chinese = "蓝牙未授权"
        case .bluetoothUnavailable:
            english = "Bluetooth unavailable"
            chinese = "蓝牙不可用"
        case .boundDisplayNotFound:
            english = "Bound Display not found"
            chinese = "未找到绑定显示器"
        case .connectFailed:
            english = "Display connection failed"
            chinese = "显示器连接失败"
        case .serviceMissing:
            english = "Display service missing"
            chinese = "显示器服务缺失"
        case .characteristicMissing:
            english = "Display characteristic missing"
            chinese = "显示器特征缺失"
        case .subscribeFailed:
            english = "Display subscribe failed"
            chinese = "显示器订阅失败"
        case .configTimeout:
            english = "Display config timeout"
            chinese = "显示器配置超时"
        case .initTimeout:
            english = "Display init timeout"
            chinese = "显示器初始化超时"
        case .mtuInvalid:
            english = "Display MTU invalid"
            chinese = "显示器 MTU 无效"
        case .planeTimeout:
            english = "Display transfer timeout"
            chinese = "显示器传输超时"
        case .refreshTimeout:
            english = "Display refresh timeout"
            chinese = "显示器刷新超时"
        case .disconnected:
            english = "Display disconnected"
            chinese = "显示器已断开"
        case .callbackAmbiguous:
            english = "Display session ambiguous"
            chinese = "显示器会话不明确"
        case .retryExhausted, .unknown:
            english = "Display unavailable"
            chinese = "显示器不可用"
        }
        return language == .english ? english : chinese
    }
}

enum DisplayLinkUUIDs {
    static let service = UUID(uuidString: "62750001-d828-918d-fb46-b6c11c675aec")!
    static let data = UUID(uuidString: "62750002-d828-918d-fb46-b6c11c675aec")!
    static let version = UUID(uuidString: "62750003-d828-918d-fb46-b6c11c675aec")!

    static let compatibleFirmware: UInt8 = 0x16
    static let missingFirmware: UInt8 = 0x15
    static let appleDefaultMTU = 20
    static let initOpcode: UInt8 = 0x01
    static let setConfigOpcode: UInt8 = 0x90
    static let forbiddenOpcodes: Set<UInt8> = [0x00, 0x02, 0x03, 0x04, 0x06, 0x91, 0x92, 0x99]
}

struct BindCandidate: Sendable, Equatable {
    var identifier: UUID
    var advertisedName: String?
    var rssi: Int

    var shortIdentifier: String {
        let hex = identifier.uuidString.replacingOccurrences(of: "-", with: "")
        return String(hex.suffix(4))
    }
}

enum WakeupPin {
    static let disabled: UInt8 = 0xFF

    static func isAllowed(_ value: UInt8) -> Bool {
        value <= 31 || value == disabled
    }

    static func parse(_ raw: String) -> UInt8? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.isEmpty || lowered == "disabled" || lowered == "0xff" || lowered == "ff" || lowered == "禁用" {
            return disabled
        }
        guard let value = UInt8(trimmed), isAllowed(value) else {
            return nil
        }
        return value
    }
}

enum WakeupPinCopy {
    static let confirmationMessage = "Configure Wakeup Pin / 配置唤醒引脚"
    static let requestMessage = "Wakeup Pin / 唤醒引脚"
    static let requestInformation = """
Enter a pin from 0 to 31, or disabled.

请输入 0 到 31 的引脚，或填写 disabled。
"""

    static func label(_ pin: UInt8, language: ResolvedInterfaceLanguage) -> String {
        if pin == WakeupPin.disabled {
            return language == .english ? "Disabled" : "已禁用"
        }
        return "\(pin)"
    }

    static func confirmationInformation(from old: UInt8, to new: UInt8) -> String {
        let english = "Change wakeup pin from \(label(old, language: .english)) to \(label(new, language: .english))?"
        let chinese = "将唤醒引脚从 \(label(old, language: .simplifiedChinese)) 改为 \(label(new, language: .simplifiedChinese))？"
        return "\(english)\n\n\(chinese)"
    }
}

struct ReadyWakeupConfiguration: Sendable, Equatable {
    var pin: UInt8
    var sessionGeneration: UInt64
    var configDigest: Data
}

struct WakeupPinWriteRequest: Sendable, Equatable {
    var pin: UInt8
    var sessionGeneration: UInt64
    var configDigest: Data
}

struct EPDConfig: Sendable, Equatable {
    var bytes: [UInt8]

    init?(data: Data) {
        guard data.count == 13 else {
            return nil
        }
        bytes = Array(data)
    }

    var wakeupPin: UInt8 {
        bytes[8]
    }

    var digest: Data {
        Data(bytes)
    }

    func replacingWakeupPin(_ pin: UInt8) -> EPDConfig? {
        guard WakeupPin.isAllowed(pin) else {
            return nil
        }
        var next = bytes
        next[8] = pin
        return EPDConfig(data: Data(next))
    }

    func differsOnlyByWakeupPin(from other: EPDConfig) -> Bool {
        guard bytes.count == other.bytes.count else {
            return false
        }
        return zip(bytes.indices, bytes).allSatisfy { index, value in
            index == 8 || value == other.bytes[index]
        }
    }
}

struct ReadyBLESession: Sendable, Equatable {
    var identifier: UUID
    var advertisedName: String?
    var config: EPDConfig
    var mtu: Int
    var rleEnabled: Bool
    var timeUnixSeconds: Int?
    var generation: UInt64
}

struct BLEWriteRecord: Sendable, Equatable {
    var identifier: UUID
    var characteristic: UUID
    var data: Data
    var withResponse: Bool

    var opcode: UInt8? {
        data.first
    }
}

enum RadioAvailability: Sendable, Equatable {
    case unknown
    case poweredOn
    case unauthorized
    case unavailable
}

enum RadioWriteType: Sendable, Equatable {
    case withResponse
    case withoutResponse
}

struct RadioCharacteristic: Sendable, Equatable {
    var uuid: UUID
    var canRead: Bool
    var canWriteWithResponse: Bool
    var canWriteWithoutResponse: Bool
    var canNotify: Bool

    static let dataDefault = RadioCharacteristic(
        uuid: DisplayLinkUUIDs.data,
        canRead: true,
        canWriteWithResponse: true,
        canWriteWithoutResponse: true,
        canNotify: true
    )

    static let versionDefault = RadioCharacteristic(
        uuid: DisplayLinkUUIDs.version,
        canRead: true,
        canWriteWithResponse: false,
        canWriteWithoutResponse: false,
        canNotify: false
    )

    var isValidDataCharacteristic: Bool {
        uuid == DisplayLinkUUIDs.data
            && canRead
            && canWriteWithResponse
            && canWriteWithoutResponse
            && canNotify
    }
}
