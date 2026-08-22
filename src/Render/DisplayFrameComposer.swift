import Foundation

struct DisplayFrame: Sendable, Equatable {
    var fingerprint: String
    var blackPlane: Data
    var redPlane: Data
}

enum DisplayFrameCompositionError: Error, Equatable, Sendable {
    case unsupportedDisplayStyle(DisplayStyle)
}

enum DisplayFrameComposer {
    static func compose(_ input: DisplayFrameInput) throws -> DisplayFrame {
        guard input.preferences.displayStyle == .quotaFocus else {
            throw DisplayFrameCompositionError.unsupportedDisplayStyle(input.preferences.displayStyle)
        }
        let model = QuotaFocusModelBuilder.build(input)
        let planes = FrameRasterizer.rasterize(model)
        return DisplayFrame(
            fingerprint: FrameFingerprint.hexSHA256(of: model),
            blackPlane: planes.blackPlane,
            redPlane: planes.redPlane
        )
    }
}
