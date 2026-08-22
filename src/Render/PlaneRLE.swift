import Foundation

enum ImageEncoding: Sendable, Equatable {
    case raw
    case rle
}

struct PlannedImageChunk: Sendable, Equatable {
    var packet: Data
    var withResponse: Bool
    var isRefresh: Bool
}

enum PlaneRLE {
    static let maxLiteralLength = 128
    static let minRepeatLength = 3
    static let maxRepeatLength = 130

    static func encodeChunkConstrained(_ plane: Data, chunkCapacity: Int) -> [Data] {
        guard chunkCapacity >= 2 else {
            return []
        }
        var chunks: [Data] = []
        var current = Data()
        current.reserveCapacity(chunkCapacity)
        let bytes = [UInt8](plane)
        var index = 0

        func remaining() -> Int {
            chunkCapacity - current.count
        }

        func flush() {
            guard !current.isEmpty else {
                return
            }
            chunks.append(current)
            current = Data()
            current.reserveCapacity(chunkCapacity)
        }

        func ensure(_ needed: Int) {
            if remaining() < needed {
                flush()
            }
        }

        while index < bytes.count {
            let value = bytes[index]
            var run = 1
            while index + run < bytes.count,
                  bytes[index + run] == value,
                  run < maxRepeatLength {
                run += 1
            }

            if run >= minRepeatLength {
                ensure(2)
                current.append(0x80 | UInt8(run - minRepeatLength))
                current.append(value)
                index += run
                continue
            }

            ensure(2)
            let maxTake = min(maxLiteralLength, remaining() - 1)
            var take = 0
            while take < maxTake && index + take < bytes.count {
                let literalValue = bytes[index + take]
                var literalRun = 1
                while index + take + literalRun < bytes.count,
                      bytes[index + take + literalRun] == literalValue,
                      literalRun < maxRepeatLength {
                    literalRun += 1
                }
                if literalRun >= minRepeatLength {
                    break
                }
                take += 1
            }
            if take == 0 {
                take = 1
            }
            current.append(UInt8(take - 1))
            current.append(contentsOf: bytes[index..<(index + take)])
            index += take
        }
        flush()
        return chunks
    }

    static func decode(_ payload: Data) -> Data? {
        var output = Data()
        output.reserveCapacity(payload.count)
        var index = payload.startIndex
        while index < payload.endIndex {
            let header = payload[index]
            index = payload.index(after: index)
            if header & 0x80 != 0 {
                guard index < payload.endIndex else {
                    return nil
                }
                let length = Int(header & 0x7F) + minRepeatLength
                let value = payload[index]
                index = payload.index(after: index)
                output.append(contentsOf: repeatElement(value, count: length))
            } else {
                let length = Int(header) + 1
                guard payload.distance(from: index, to: payload.endIndex) >= length else {
                    return nil
                }
                let end = payload.index(index, offsetBy: length)
                output.append(payload[index..<end])
                index = end
            }
        }
        return output
    }
}

enum ImageTransferPlanner {
    static func negotiatedCapacity(
        firmwareMTU: Int,
        withoutResponseLimit: Int,
        withResponseLimit: Int
    ) -> Int {
        min(firmwareMTU - 2, withoutResponseLimit - 2, withResponseLimit - 2)
    }

    static func plan(
        black: Data,
        red: Data,
        rleAdvertised: Bool,
        chunkCapacity: Int
    ) -> (encoding: ImageEncoding, chunks: [PlannedImageChunk])? {
        guard black.count == PlaneEncoder.planeByteCount,
              red.count == PlaneEncoder.planeByteCount,
              chunkCapacity >= 1 else {
            return nil
        }

        let rawBlack = splitRaw(black, chunkCapacity: chunkCapacity)
        let rawRed = splitRaw(red, chunkCapacity: chunkCapacity)
        if rleAdvertised, chunkCapacity >= 2 {
            let rleBlack = PlaneRLE.encodeChunkConstrained(black, chunkCapacity: chunkCapacity)
            let rleRed = PlaneRLE.encodeChunkConstrained(red, chunkCapacity: chunkCapacity)
            let rleBytes = payloadLength(rleBlack) + payloadLength(rleRed)
            let rawBytes = payloadLength(rawBlack) + payloadLength(rawRed)
            if rleBytes < rawBytes, !rleBlack.isEmpty, !rleRed.isEmpty {
                return (.rle, packets(blackChunks: rleBlack, redChunks: rleRed, rle: true))
            }
        }
        return (.raw, packets(blackChunks: rawBlack, redChunks: rawRed, rle: false))
    }

    private static func payloadLength(_ chunks: [Data]) -> Int {
        chunks.reduce(0) { $0 + $1.count }
    }

    private static func splitRaw(_ plane: Data, chunkCapacity: Int) -> [Data] {
        var chunks: [Data] = []
        var start = 0
        while start < plane.count {
            let end = min(start + chunkCapacity, plane.count)
            chunks.append(plane.subdata(in: start..<end))
            start = end
        }
        return chunks
    }

    private static func packets(
        blackChunks: [Data],
        redChunks: [Data],
        rle: Bool
    ) -> [PlannedImageChunk] {
        var result: [PlannedImageChunk] = []
        result.append(contentsOf: planePackets(blackChunks, red: false, rle: rle))
        result.append(contentsOf: planePackets(redChunks, red: true, rle: rle))
        result.append(
            PlannedImageChunk(
                packet: Data([DisplayLinkUUIDs.refreshOpcode]),
                withResponse: true,
                isRefresh: true
            )
        )
        return result
    }

    private static func planePackets(
        _ chunks: [Data],
        red: Bool,
        rle: Bool
    ) -> [PlannedImageChunk] {
        chunks.enumerated().map { index, payload in
            var flags: UInt8 = 0
            if red {
                flags |= DisplayLinkUUIDs.writeImageFlagRed
            }
            if index == 0 {
                flags |= DisplayLinkUUIDs.writeImageFlagFirst
            }
            if rle {
                flags |= DisplayLinkUUIDs.writeImageFlagRLE
            }
            var packet = Data([DisplayLinkUUIDs.writeImageOpcode, flags])
            packet.append(payload)
            return PlannedImageChunk(
                packet: packet,
                withResponse: index == chunks.count - 1,
                isRefresh: false
            )
        }
    }
}
