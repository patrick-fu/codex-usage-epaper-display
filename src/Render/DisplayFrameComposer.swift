import Foundation

struct DisplayFrame: Sendable, Equatable {
    var fingerprint: String
    var blackPlane: Data
    var redPlane: Data
}

enum DisplayFrameComposer {
    static func compose(_ input: DisplayFrameInput) -> DisplayFrame {
        let model = QuotaFocusModelBuilder.build(input)
        let planes = FrameRasterizer.rasterize(model)
        return DisplayFrame(
            fingerprint: FrameFingerprint.hexSHA256(of: model),
            blackPlane: planes.blackPlane,
            redPlane: planes.redPlane
        )
    }
}
