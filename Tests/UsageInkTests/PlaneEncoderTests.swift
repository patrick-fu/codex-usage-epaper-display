import XCTest
@testable import UsageInk

final class PlaneEncoderTests: XCTestCase {
    func testPlanesAreExactlyFifteenThousandBytes() {
        let planes = PlaneEncoder.encode { _, _ in .paper }
        XCTAssertEqual(planes.blackPlane.count, 15_000)
        XCTAssertEqual(planes.redPlane.count, 15_000)
        XCTAssertEqual(PlaneEncoder.bytesPerRow, 50)
        XCTAssertEqual(PlaneEncoder.width, 400)
        XCTAssertEqual(PlaneEncoder.height, 300)
    }

    func testAllWhiteGoldenIsFFOnBothPlanes() {
        let planes = PlaneEncoder.encode { _, _ in .paper }
        XCTAssertEqual(planes.blackPlane, Data(repeating: 0xFF, count: 15_000))
        XCTAssertEqual(planes.redPlane, Data(repeating: 0xFF, count: 15_000))
    }

    func testAllBlackGoldenIs00OnBlackAndFFOnRed() {
        let planes = PlaneEncoder.encode { _, _ in .black }
        XCTAssertEqual(planes.blackPlane, Data(repeating: 0x00, count: 15_000))
        XCTAssertEqual(planes.redPlane, Data(repeating: 0xFF, count: 15_000))
    }

    func testAllRedGoldenIsFFOnBlackAnd00OnRed() {
        let planes = PlaneEncoder.encode { _, _ in .red }
        XCTAssertEqual(planes.blackPlane, Data(repeating: 0xFF, count: 15_000))
        XCTAssertEqual(planes.redPlane, Data(repeating: 0x00, count: 15_000))
    }

    func testLeftmostEightWhitePixelsWalkMSBOnBlackBackground() {
        let planes = PlaneEncoder.encode { x, y in
            if x == y && x < 8 {
                return .paper
            }
            return .black
        }
        let expectedLeading: [UInt8] = [0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01]
        for row in 0..<8 {
            let start = row * 50
            XCTAssertEqual(
                planes.blackPlane[start],
                expectedLeading[row],
                "row \(row) column byte 0"
            )
            XCTAssertEqual(
                Array(planes.blackPlane[(start + 1)..<(start + 50)]),
                Array(repeating: UInt8(0x00), count: 49),
                "row \(row) remaining black bytes"
            )
        }
        XCTAssertEqual(planes.redPlane, Data(repeating: 0xFF, count: 15_000))
    }

    func testPixelEightOccupiesNextByteMSB() {
        let planes = PlaneEncoder.encode { x, y in
            if x == 8 && y == 0 {
                return .paper
            }
            return .black
        }
        XCTAssertEqual(planes.blackPlane[0], 0x00)
        XCTAssertEqual(planes.blackPlane[1], 0x80)
        XCTAssertEqual(planes.redPlane[0], 0xFF)
        XCTAssertEqual(planes.redPlane[1], 0xFF)
    }

    func testRedOnlyPixelSetsBlackBitOneAndRedBitZero() {
        let planes = PlaneEncoder.encode { x, y in
            if x == 0 && y == 0 {
                return .red
            }
            return .paper
        }
        XCTAssertEqual(planes.blackPlane[0], 0xFF)
        XCTAssertEqual(planes.redPlane[0], 0x7F)
        XCTAssertEqual(Array(planes.blackPlane[1...]), Array(repeating: UInt8(0xFF), count: 14_999))
        XCTAssertEqual(Array(planes.redPlane[1...]), Array(repeating: UInt8(0xFF), count: 14_999))
    }

    func testEncodeKeepsPlanesInMemoryAndDoesNotWriteArtifacts() {
        let tmp = FileManager.default.temporaryDirectory
        let before = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        let planes = PlaneEncoder.encode { x, y in
            if x == 0 && y == 0 { return .red }
            if x == y && x < 8 { return .paper }
            return .black
        }
        XCTAssertEqual(planes.blackPlane.count, 15_000)
        XCTAssertEqual(planes.redPlane.count, 15_000)
        let after = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        XCTAssertEqual(after, before)
    }
}
