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
        switch self {
        case .firmwareIncompatible:
            return language == .english ? "Display firmware incompatible" : "显示器固件不兼容"
        case .bluetoothUnauthorized:
            return language == .english ? "Bluetooth unauthorized" : "蓝牙未授权"
        case .bluetoothUnavailable:
            return language == .english ? "Bluetooth unavailable" : "蓝牙不可用"
        default:
            return rawValue
        }
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

    static let sampleConfig = Data([8, 7, 6, 5, 4, 3, 2, 1, 0xFF, 0, 1, 0, 1])
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
}

struct ReadyBLESession: Sendable, Equatable {
    var identifier: UUID
    var advertisedName: String?
    var config: EPDConfig
    var mtu: Int
    var rleEnabled: Bool
    var timeUnixSeconds: Int?
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
