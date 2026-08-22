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

        let raw = packets(
            blackChunks: splitRaw(black, chunkCapacity: chunkCapacity),
            redChunks: splitRaw(red, chunkCapacity: chunkCapacity),
            rle: false
        )
        if rleAdvertised, chunkCapacity >= 2 {
            let rleBlack = PlaneRLE.encodeChunkConstrained(black, chunkCapacity: chunkCapacity)
            let rleRed = PlaneRLE.encodeChunkConstrained(red, chunkCapacity: chunkCapacity)
            if !rleBlack.isEmpty, !rleRed.isEmpty {
                let rle = packets(blackChunks: rleBlack, redChunks: rleRed, rle: true)
                if wireLength(rle) < wireLength(raw) {
                    return (.rle, rle)
                }
            }
        }
        return (.raw, raw)
    }

    static func wireLength(_ chunks: [PlannedImageChunk]) -> Int {
        chunks.reduce(0) { $0 + $1.packet.count }
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
