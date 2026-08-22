import Foundation

enum CodexFailure: String, Sendable, Equatable, Error {
    case binaryMissing
    case versionTooOld
    case transportStart
    case transportExit
    case invalidJSON
    case protocolIncompatible
    case authRequired
    case backendUnauthorized
    case backendForbidden
    case rateLimitUnavailable
    case overloaded
    case timeout
    case schemaInvalid
    case unknown
}
