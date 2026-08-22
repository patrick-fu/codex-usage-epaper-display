import Foundation

enum InkColor: Sendable, Equatable {
    case paper
    case black
    case red
}

struct DisplayPlanes: Sendable, Equatable {
    let blackPlane: Data
    let redPlane: Data
}

enum PlaneEncoder {
    static let width = 400
    static let height = 300
    static let bytesPerRow = width / 8
    static let planeByteCount = bytesPerRow * height

    static func encode(pixelAt: (_ x: Int, _ y: Int) -> InkColor) -> DisplayPlanes {
        var blackBytes = [UInt8](repeating: 0, count: planeByteCount)
        var redBytes = [UInt8](repeating: 0, count: planeByteCount)
        for y in 0..<height {
            for byteIndex in 0..<bytesPerRow {
                var blackByte: UInt8 = 0
                var redByte: UInt8 = 0
                let xBase = byteIndex * 8
                for bit in 0..<8 {
                    let mask: UInt8 = 1 << (7 - bit)
                    switch pixelAt(xBase + bit, y) {
                    case .paper:
                        blackByte |= mask
                        redByte |= mask
                    case .black:
                        redByte |= mask
                    case .red:
                        blackByte |= mask
                    }
                }
                let offset = y * bytesPerRow + byteIndex
                blackBytes[offset] = blackByte
                redBytes[offset] = redByte
            }
        }
        return DisplayPlanes(
            blackPlane: Data(blackBytes),
            redPlane: Data(redBytes)
        )
    }
}
