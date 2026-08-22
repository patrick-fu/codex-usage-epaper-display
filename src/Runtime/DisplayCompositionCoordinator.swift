import Foundation

struct DisplayCompositionSession: Equatable, Sendable {
    var inFlightFrame: DisplayFrame?
    var inFlightInput: DisplayFrameInput?
    var pendingAutomatic: DisplayFrameInput?
}

enum DisplayCompositionCoordinator {
    static func applyConfiguration(
        session: inout DisplayCompositionSession,
        preferences: DisplayPreferences,
        fallbackInput: DisplayFrameInput? = nil
    ) {
        guard var next = session.pendingAutomatic ?? session.inFlightInput ?? fallbackInput else {
            return
        }
        next.preferences = preferences
        session.pendingAutomatic = next
    }

    static func beginInFlight(
        session: inout DisplayCompositionSession,
        input: DisplayFrameInput
    ) throws -> DisplayFrame {
        let frame = try DisplayFrameComposer.compose(input)
        session.inFlightFrame = frame
        session.inFlightInput = input
        return frame
    }

    static func finishInFlight(
        session: inout DisplayCompositionSession
    ) -> DisplayFrameInput? {
        session.inFlightFrame = nil
        session.inFlightInput = nil
        let pending = session.pendingAutomatic
        session.pendingAutomatic = nil
        return pending
    }
}
