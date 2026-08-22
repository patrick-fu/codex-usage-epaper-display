import XCTest
@testable import UsageInk

final class PlaneRLETests: XCTestCase {
    func testRepeatAndLiteralRoundTripAndCodeBoundaries() throws {
        var plane = Data(repeating: 0x00, count: 130)
        plane.append(contentsOf: (0..<128).map { UInt8($0) })
        plane.append(Data(repeating: 0xAA, count: 3))
        plane.append(0x01)
        plane.append(0x02)
        XCTAssertEqual(plane.count, 263)

        let capacity = 8
        let chunks = PlaneRLE.encodeChunkConstrained(plane, chunkCapacity: capacity)
        XCTAssertFalse(chunks.isEmpty)
        var decoded = Data()
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, capacity)
            XCTAssertFalse(chunk.isEmpty)
            let part = try XCTUnwrap(PlaneRLE.decode(chunk))
            decoded.append(part)
        }
        XCTAssertEqual(decoded, plane)
        XCTAssertLessThan(chunks.reduce(0) { $0 + $1.count }, plane.count)
    }

    func testOneHundredThirtyByteRepeatStaysInsideOneChunk() throws {
        let plane = Data(repeating: 0x7F, count: 130) + Data(repeating: 0x00, count: 15_000 - 130)
        let chunks = PlaneRLE.encodeChunkConstrained(plane, chunkCapacity: 6)
        XCTAssertTrue(chunks.contains(where: { chunk in
            var index = chunk.startIndex
            while index < chunk.endIndex {
                let header = chunk[index]
                index = chunk.index(after: index)
                guard index < chunk.endIndex else { return false }
                let value = chunk[index]
                index = chunk.index(after: index)
                if header == (0x80 | UInt8(130 - 3)), value == 0x7F {
                    return true
                }
            }
            return false
        }))
        let decoded = try XCTUnwrap(PlaneRLE.decode(chunks.reduce(into: Data()) { $0.append($1) }))
        XCTAssertEqual(decoded, plane)
    }

    func testLiteralOneHundredTwentyEightFitsExactly() throws {
        let unique = Data((0..<128).map { UInt8($0) })
        let chunks = PlaneRLE.encodeChunkConstrained(unique, chunkCapacity: 129)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].first, 127)
        XCTAssertEqual(chunks[0].count, 129)
        XCTAssertEqual(PlaneRLE.decode(chunks[0]), unique)
    }

    func testRawSelectedWhenRLEIsNotAdvertisedOrNotShorter() throws {
        let noisy = Data((0..<PlaneEncoder.planeByteCount).map { UInt8($0 & 0x7F == 0 ? 0x01 : UInt8($0 & 0x7F)) })
        let black = noisy
        let red = Data(noisy.reversed())
        let advertised = try XCTUnwrap(
            ImageTransferPlanner.plan(black: black, red: red, rleAdvertised: false, chunkCapacity: 20)
        )
        XCTAssertEqual(advertised.encoding, .raw)

        let incompressible = try XCTUnwrap(
            ImageTransferPlanner.plan(black: black, red: red, rleAdvertised: true, chunkCapacity: 20)
        )
        XCTAssertEqual(incompressible.encoding, .raw)
    }

    func testAdvertisedRLEIsUsedOnlyWhenChunkConstrainedStreamIsShorter() throws {
        let black = Data(repeating: 0x00, count: PlaneEncoder.planeByteCount)
        let red = Data(repeating: 0xFF, count: PlaneEncoder.planeByteCount)
        let planned = try XCTUnwrap(
            ImageTransferPlanner.plan(black: black, red: red, rleAdvertised: true, chunkCapacity: 18)
        )
        XCTAssertEqual(planned.encoding, .rle)
        let raw = try XCTUnwrap(
            ImageTransferPlanner.plan(black: black, red: red, rleAdvertised: false, chunkCapacity: 18)
        )
        XCTAssertLessThan(ImageTransferPlanner.wireLength(planned.chunks), ImageTransferPlanner.wireLength(raw.chunks))
    }
}
