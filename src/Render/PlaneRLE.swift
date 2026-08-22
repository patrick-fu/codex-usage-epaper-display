import Foundation

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
