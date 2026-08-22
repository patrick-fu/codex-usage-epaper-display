import XCTest
@testable import UsageInk

final class InfoPlistContractTests: XCTestCase {
    private var info: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    func testAccessoryAppIdentity() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.patrickfu.UsageInk")
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
        XCTAssertNil(info["NSMainStoryboardFile"])
        XCTAssertNil(info["NSMainNibFile"])
    }

    func testBluetoothUsageStringsExistInEnglishAndSimplifiedChinese() throws {
        let english = try XCTUnwrap(info["NSBluetoothAlwaysUsageDescription"] as? String)
        XCTAssertTrue(english.localizedCaseInsensitiveContains("Bluetooth"))
        XCTAssertTrue(english.contains("Bound Display"))

        let zhPath = try XCTUnwrap(
            Bundle.main.path(
                forResource: "InfoPlist",
                ofType: "strings",
                inDirectory: nil,
                forLocalization: "zh-Hans"
            )
        )
        let zh = try XCTUnwrap(NSDictionary(contentsOfFile: zhPath) as? [String: String])
        let chinese = try XCTUnwrap(zh["NSBluetoothAlwaysUsageDescription"])
        XCTAssertTrue(chinese.contains("蓝牙"))
        XCTAssertTrue(chinese.contains("显示器"))
        XCTAssertNotEqual(english, chinese)
    }

    func testInfoPlistMakesNoNonBluetoothTCCClaim() {
        let tccKeys = [
            "NSBluetoothPeripheralUsageDescription",
            "NSBluetoothWhileInUseUsageDescription",
            "NSCameraUsageDescription",
            "NSMicrophoneUsageDescription",
            "NSContactsUsageDescription",
            "NSCalendarsUsageDescription",
            "NSRemindersUsageDescription",
            "NSPhotoLibraryUsageDescription",
            "NSPhotoLibraryAddUsageDescription",
            "NSLocationAlwaysUsageDescription",
            "NSLocationWhenInUseUsageDescription",
            "NSLocationAlwaysAndWhenInUseUsageDescription",
            "NSAppleEventsUsageDescription",
            "NSDesktopFolderUsageDescription",
            "NSDocumentsFolderUsageDescription",
            "NSDownloadsFolderUsageDescription",
            "NSNetworkVolumesUsageDescription",
            "NSRemovableVolumesUsageDescription",
            "NSSystemAdministrationUsageDescription",
            "NSMotionUsageDescription",
            "NSSpeechRecognitionUsageDescription",
            "NSAppleMusicUsageDescription",
            "NSHomeKitUsageDescription",
            "NSSiriUsageDescription",
            "NSFaceIDUsageDescription",
            "NSUserTrackingUsageDescription",
            "NSLocalNetworkUsageDescription",
            "NSNearbyInteractionUsageDescription",
            "NSCalendarsFullAccessUsageDescription",
            "NSRemindersFullAccessUsageDescription",
        ]
        let present = tccKeys.filter { info[$0] != nil }
        XCTAssertEqual(present, [], "shell Info.plist may claim only Bluetooth usage")
        XCTAssertNotNil(info["NSBluetoothAlwaysUsageDescription"])
    }
}
