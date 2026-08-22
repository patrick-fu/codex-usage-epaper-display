import Foundation

struct DisplayFrame: Sendable, Equatable {
    var fingerprint: String
    var blackPlane: Data
    var redPlane: Data
}

enum DisplayFrameComposer {
    static func compose(_ input: DisplayFrameInput) throws -> DisplayFrame {
        switch input.preferences.displayStyle {
        case .quotaFocus:
            let model = QuotaFocusModelBuilder.build(input)
            let planes = FrameRasterizer.rasterize(model)
            return DisplayFrame(
                fingerprint: FrameFingerprint.hexSHA256(of: model),
                blackPlane: planes.blackPlane,
                redPlane: planes.redPlane
            )
        case .balanced:
            let model = BalancedModelBuilder.build(input)
            let planes = FrameRasterizer.rasterize(model)
            return DisplayFrame(
                fingerprint: FrameFingerprint.hexSHA256(of: model),
                blackPlane: planes.blackPlane,
                redPlane: planes.redPlane
            )
        case .activityFocus:
            let model = ActivityFocusModelBuilder.build(input)
            let planes = FrameRasterizer.rasterize(model)
            return DisplayFrame(
                fingerprint: FrameFingerprint.hexSHA256(of: model),
                blackPlane: planes.blackPlane,
                redPlane: planes.redPlane
            )
        }
    }
}
