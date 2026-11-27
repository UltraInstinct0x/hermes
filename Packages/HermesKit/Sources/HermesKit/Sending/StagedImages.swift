import Foundation

/// Photos staged on the gateway for the next prompt (`image.attach_bytes`, a PDF's pages through
/// `pdf.attach`). Hermes keeps them for whichever prompt comes next on the chat, so photos staged
/// for a prompt it refused, or one that never went, ride on the next message: the app sends them
/// again with this one later, so they went twice, or with a message they weren't for. They're
/// taken back (`image.detach`, by path) unless the prompt may have them (`docs/chat.md` §4c).
public struct StagedImages: Sendable, Equatable {
    public private(set) var paths: [String] = []
    public private(set) var references: [JSONValue] = []

    public init() {}

    public var isEmpty: Bool { paths.isEmpty }

    /// Notes what an attach staged: `{path}` for a photo, `{pages: [{path}]}` for a PDF's pages.
    public mutating func staged(_ result: JSONValue) {
        record(result)
        if case .array(let pages)? = result["pages"] {
            for page in pages { record(page) }
        }
    }

    private mutating func record(_ result: JSONValue) {
        guard let path = result["path"]?.stringValue, !path.isEmpty else { return }
        paths.append(path)
        if let mime = result["mime"]?.stringValue {
            references.append(.object(["path": .string(path), "mime": .string(mime)]))
        }
    }

    /// Whether a send that failed with `error` leaves them staged for nothing: the prompt never
    /// went, or Hermes answered it with a refusal (which leaves them staged; the gateway's busy
    /// refusal removes them itself, and taking back what's gone does nothing). Not when the
    /// answer was lost: the prompt may have them.
    public static func takeBack(after error: any Error, promptSent: Bool) -> Bool {
        guard promptSent else { return true }
        return error is GatewayRPCError
    }
}
