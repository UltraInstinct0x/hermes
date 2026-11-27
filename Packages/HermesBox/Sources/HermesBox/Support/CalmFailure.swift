import Foundation

/// A failure as the screen shows it: ONE calm sentence, a Retry that says what it retries, and the raw
/// cause behind Copy details only. Nothing here is built from a pairing code, a token or a header.
///
/// Ported from Hermes Bot (`HermesKit/Chat/CalmFailure.swift`), trimmed to what pairing and calls use.
public struct CalmFailure: Equatable, Sendable {
    /// What Retry does. It is only ever run by a tap, never automatically.
    public enum Retry: Equatable, Sendable {
        case reconnect
        case pair
    }

    public let sentence: String
    public let details: String
    public let retry: Retry

    public init(sentence: String, details: String, retry: Retry) {
        self.sentence = sentence
        // Copy details can carry a URL that a failed socket dialled; a one-time ticket in it is never shown or copied.
        self.details = ScreenRedaction.redactTickets(details)
        self.retry = retry
    }

    /// The calm failure for any error this package can see.
    public static func from(_ error: any Error, retry: Retry) -> CalmFailure {
        switch error {
        case let error as BFFError:
            return CalmFailure(sentence: error.calmSentence, details: error.detail, retry: retry)
        case is CancellationError:
            return CalmFailure(sentence: "That was cancelled. Retry.", details: "cancelled", retry: retry)
        default:
            return CalmFailure(sentence: "Something went wrong. Retry.", details: String(describing: error), retry: retry)
        }
    }
}
