import Foundation

struct CodexJSONLFramer {
    static let maxLineBytes = 1_048_576

    enum Event: Equatable {
        case line(Data)
        case invalidJSON
        case schemaInvalid
    }

    private var buffer = Data()
    private var finished = false

    mutating func ingest(_ data: Data) -> [Event] {
        guard !finished else {
            return []
        }
        buffer.append(data)
        var events: [Event] = []
        let newline = Data([0x0a])
        while let range = buffer.range(of: newline) {
            let line = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            if line.count > Self.maxLineBytes {
                finished = true
                events.append(.schemaInvalid)
                return events
            }
            events.append(.line(line))
        }
        if buffer.count > Self.maxLineBytes {
            finished = true
            events.append(.invalidJSON)
        }
        return events
    }
}
