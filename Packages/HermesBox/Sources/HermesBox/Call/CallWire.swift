import Foundation

// The S19 call hub wire protocol as the phone speaks it (`box/call-hub/protocol.mjs`, `specs/S19-call-hub.md`
// sections 5.2 and 11). Pure: encoding and decoding only, no socket, no clock.

/// What the hub knows. `auto` is never sent: the client resolves it before `call.start` (S19 R35).
public enum CallEngine: String, Sendable, Equatable, CaseIterable {
    case free
    case live
}

/// A hub call state. `unknown` keeps a future state from breaking the screen.
public enum HubCallState: String, Sendable, Equatable {
    case starting, active, handover, ended, failed, unknown

    init(wire: String?) { self = wire.flatMap(HubCallState.init(rawValue:)) ?? .unknown }

    public var isFinal: Bool { self == .ended || self == .failed }
}

public enum CallRole: String, Sendable, Equatable {
    case owner
    case listener
}

/// The hub's closed error set (S19 R19). The hub's message is one fixed sentence per code; the phone shows its own
/// copy of it so the words never depend on a server string.
public enum HubErrorCode: String, Sendable, Equatable, CaseIterable {
    case badRequest = "bad_request"
    case unauthorized
    case notFound = "not_found"
    case notOwner = "not_owner"
    case staleEpoch = "stale_epoch"
    case callExists = "call_exists"
    case limitReached = "limit_reached"
    case unavailable
    case notReady = "not_ready"
    case tooLarge = "too_large"
    case rateLimited = "rate_limited"
    case `internal`

    /// Anything outside the closed set is read as `internal`.
    init(wire: String?) { self = wire.flatMap(HubErrorCode.init(rawValue:)) ?? .internal }

    /// The calm sentence, no em-dashes, the same as the hub's own.
    public var sentence: String {
        switch self {
        case .badRequest: "That request could not be understood."
        case .unauthorized: "You are not allowed to do that."
        case .notFound: "That call was not found."
        case .notOwner: "This device is not the one driving the call."
        case .staleEpoch: "Another device took over the call."
        case .callExists: "There is already a call for this bot."
        case .limitReached: "The call service is busy. Try again in a moment."
        case .unavailable: "The call could not be started right now."
        case .notReady: "The call is not ready yet."
        case .tooLarge: "That is too large."
        case .rateLimited: "Too many messages. Slow down."
        case .internal: "Something went wrong on the server."
        }
    }
}

public struct CallParticipant: Sendable, Equatable {
    public var clientId: String
    public var kind: String
    public var label: String
    public var role: CallRole?
    public var connected: Bool
}

/// What every connected client may see about a call: no text of what was said (S19 R16).
public struct CallSummary: Sendable, Equatable {
    public var callId: String
    public var botKey: String
    public var engine: CallEngine
    public var state: HubCallState
    public var ownerClientId: String?
    public var ownerEpoch: UInt32
    public var participants: [CallParticipant]
    public var startedAt: Int
    public var endedReason: String?
    public var seq: Int

    /// The device that drives the call, as a person would name it. Nil when the call has no owner.
    public var ownerName: String? {
        guard let ownerClientId, let owner = participants.first(where: { $0.clientId == ownerClientId }) else { return nil }
        return CallPresentation.deviceName(kind: owner.kind, label: owner.label)
    }
}

/// `hello.ok.yours` row: a call this client is already in.
public struct CallMembership: Sendable, Equatable {
    public var callId: String
    public var role: CallRole?
    public var ownerEpoch: UInt32
}

public struct HelloOk: Sendable, Equatable {
    public var clientId: String
    public var calls: [CallSummary]
    public var yours: [CallMembership]
}

/// `you` of `call.state` and `call.joined`: the recipient's own role and the epoch it must carry.
public struct CallYou: Sendable, Equatable {
    public var role: CallRole?
    public var ownerEpoch: UInt32
}

public enum CallSpeaker: String, Sendable, Equatable {
    /// The person on the phone.
    case person
    /// The call's voice agent.
    case voice
}

public struct CallTranscriptRow: Sendable, Equatable {
    public var callId: String
    public var seq: Int?
    /// `"partial"` while the person speaks (replaced by the final row, never stored).
    public var rowId: String
    public var speaker: CallSpeaker
    public var text: String
    public var final: Bool

    public var isPartial: Bool { rowId == "partial" }
}

public enum HandoverMode: String, Sendable, Equatable { case `switch`, restart }

/// Everything the hub sends as text. Events the phone does not draw (`call.delegation`, `call.clarify`) are `.other`.
public enum CallInbound: Sendable, Equatable {
    case helloOk(HelloOk)
    case callList([CallSummary])
    case started(id: String?, callId: String, ownerEpoch: UInt32, call: CallSummary)
    case joined(id: String?, callId: String, you: CallYou, resumed: Bool, events: [CallTranscriptRow])
    case taken(callId: String, ownerEpoch: UInt32, changed: Bool)
    case left(callId: String)
    case said(callId: String)
    case state(call: CallSummary, you: CallYou)
    case transcript(CallTranscriptRow)
    case handover(callId: String, mode: HandoverMode, ownerEpoch: UInt32, toClientId: String?)
    case ended(callId: String, reason: String)
    case ttsStart(callId: String, replyId: UInt32, sampleRate: Int, text: String)
    case ttsEnd(callId: String, replyId: UInt32, failed: Bool)
    case ttsStop(callId: String)
    case pong
    /// A bot put this item on the call screen.
    case display(callId: String, item: CallDisplayItem)
    case displayClear(callId: String)
    /// The bot went to standby (it listens only for a wake word) or came back.
    case standby(callId: String, on: Bool)
    case error(code: HubErrorCode, id: String?, callId: String?, ownerEpoch: UInt32?)
    case other(type: String)
}

// MARK: - Decoding

extension CallInbound {
    /// Parse one text frame. Nil when it is not a JSON object with a `type`.
    public static func parse(_ text: String) -> CallInbound? {
        guard let data = text.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = object["type"] as? String
        else { return nil }
        let id = WireValue.string(object["id"])
        switch type {
        case "hello.ok":
            return .helloOk(
                HelloOk(
                    clientId: WireValue.string(object["client_id"]) ?? "",
                    calls: WireValue.list(object["calls"]).compactMap(CallSummary.init(wire:)),
                    yours: WireValue.list(object["yours"]).compactMap(CallMembership.init(wire:))))
        case "call.list.ok":
            return .callList(WireValue.list(object["calls"]).compactMap(CallSummary.init(wire:)))
        case "call.started":
            guard let callId = WireValue.string(object["call_id"]), let summary = CallSummary(wire: object["call"]) else { return nil }
            return .started(id: id, callId: callId, ownerEpoch: WireValue.epoch(object["owner_epoch"]) ?? summary.ownerEpoch, call: summary)
        case "call.joined":
            guard let callId = WireValue.string(object["call_id"]), let you = CallYou(wire: object["you"]) else { return nil }
            let events = WireValue.list(object["events"]).compactMap { CallTranscriptRow(wire: $0, fallbackCallId: callId) }
            return .joined(id: id, callId: callId, you: you, resumed: object["resumed"] as? Bool ?? false, events: events)
        case "call.taken":
            guard let callId = WireValue.string(object["call_id"]), let epoch = WireValue.epoch(object["owner_epoch"]) else { return nil }
            return .taken(callId: callId, ownerEpoch: epoch, changed: object["changed"] as? Bool ?? true)
        case "call.left":
            return WireValue.string(object["call_id"]).map { .left(callId: $0) }
        case "call.said":
            return WireValue.string(object["call_id"]).map { .said(callId: $0) }
        case "call.state":
            guard let summary = CallSummary(wire: object["call"]), let you = CallYou(wire: object["you"]) else { return nil }
            return .state(call: summary, you: you)
        case "call.transcript":
            return CallTranscriptRow(wire: object, fallbackCallId: nil).map { .transcript($0) }
        case "call.handover":
            guard let callId = WireValue.string(object["call_id"]) else { return nil }
            let mode = (object["mode"] as? String).flatMap(HandoverMode.init(rawValue:)) ?? .switch
            return .handover(
                callId: callId, mode: mode, ownerEpoch: WireValue.epoch(object["owner_epoch"]) ?? 0,
                toClientId: WireValue.string(object["to_client_id"]))
        case "call.ended":
            guard let callId = WireValue.string(object["call_id"]) else { return nil }
            return .ended(callId: callId, reason: WireValue.string(object["reason"]) ?? "")
        case "tts.start":
            guard let callId = WireValue.string(object["call_id"]), let reply = WireValue.epoch(object["reply_id"]),
                let rate = WireValue.int(object["sample_rate"]), rate > 0
            else { return nil }
            return .ttsStart(callId: callId, replyId: reply, sampleRate: rate, text: WireValue.string(object["text"]) ?? "")
        case "tts.end":
            guard let callId = WireValue.string(object["call_id"]), let reply = WireValue.epoch(object["reply_id"]) else { return nil }
            return .ttsEnd(callId: callId, replyId: reply, failed: object["failed"] as? Bool ?? false)
        case "tts.stop":
            return WireValue.string(object["call_id"]).map { .ttsStop(callId: $0) }
        case "pong":
            return .pong
        case "call.display":
            guard let callId = WireValue.string(object["call_id"]) else { return nil }
            // An item this phone cannot read (a future kind) is dropped, never a broken card.
            guard let item = CallDisplayItem(wire: object["item"]) else { return .other(type: type) }
            return .display(callId: callId, item: item)
        case "call.display.clear":
            return WireValue.string(object["call_id"]).map { .displayClear(callId: $0) }
        case "call.standby":
            guard let callId = WireValue.string(object["call_id"]), let on = object["on"] as? Bool else { return nil }
            return .standby(callId: callId, on: on)
        case "error":
            return .error(
                code: HubErrorCode(wire: object["code"] as? String), id: id, callId: WireValue.string(object["call_id"]),
                ownerEpoch: WireValue.epoch(object["owner_epoch"]))
        default:
            return .other(type: type)
        }
    }
}

enum WireValue {
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    static func epoch(_ value: Any?) -> UInt32? {
        guard let number = int(value), number >= 0, number <= Int(UInt32.max) else { return nil }
        return UInt32(number)
    }

    static func list(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
}

extension CallSummary {
    init?(wire: Any?) {
        guard let object = wire as? [String: Any], let callId = WireValue.string(object["call_id"]),
            let botKey = WireValue.string(object["bot_key"])
        else { return nil }
        self.init(
            callId: callId, botKey: botKey, engine: (object["engine"] as? String).flatMap(CallEngine.init(rawValue:)) ?? .free,
            state: HubCallState(wire: object["state"] as? String), ownerClientId: WireValue.string(object["owner_client_id"]),
            ownerEpoch: WireValue.epoch(object["owner_epoch"]) ?? 0,
            participants: WireValue.list(object["participants"]).compactMap(CallParticipant.init(wire:)),
            startedAt: WireValue.int(object["started_at"]) ?? 0, endedReason: WireValue.string(object["ended_reason"]),
            seq: WireValue.int(object["seq"]) ?? 0)
    }
}

extension CallParticipant {
    init?(wire: Any?) {
        guard let object = wire as? [String: Any], let clientId = WireValue.string(object["client_id"]) else { return nil }
        self.init(
            clientId: clientId, kind: WireValue.string(object["kind"]) ?? "other", label: WireValue.string(object["label"]) ?? "",
            role: (object["role"] as? String).flatMap(CallRole.init(rawValue:)), connected: object["connected"] as? Bool ?? true)
    }
}

extension CallMembership {
    init?(wire: Any?) {
        guard let object = wire as? [String: Any], let callId = WireValue.string(object["call_id"]) else { return nil }
        self.init(
            callId: callId, role: (object["role"] as? String).flatMap(CallRole.init(rawValue:)),
            ownerEpoch: WireValue.epoch(object["owner_epoch"]) ?? 0)
    }
}

extension CallYou {
    init?(wire: Any?) {
        guard let object = wire as? [String: Any], let epoch = WireValue.epoch(object["owner_epoch"]) else { return nil }
        self.init(role: (object["role"] as? String).flatMap(CallRole.init(rawValue:)), ownerEpoch: epoch)
    }
}

extension CallDisplayItem {
    init?(wire: Any?) {
        guard let object = wire as? [String: Any], let id = WireValue.string(object["id"]), !id.isEmpty,
            let kind = (object["kind"] as? String).flatMap(CallDisplayKind.init(rawValue:)),
            let title = object["title"] as? String
        else { return nil }
        let body = object["body"] as? String
        let url = object["url"] as? String
        switch kind {
        case .markdown: guard body?.isEmpty == false else { return nil }
        case .url, .image: guard url?.isEmpty == false else { return nil }
        }
        self.init(id: id, kind: kind, title: title, body: kind == .markdown ? body : nil, url: kind == .markdown ? nil : url)
    }
}

extension CallTranscriptRow {
    /// A `call.transcript` frame, or a replayed event of `call.joined.events` (other event types are skipped).
    init?(wire: Any?, fallbackCallId: String?) {
        guard let object = wire as? [String: Any], (object["type"] as? String) == "call.transcript",
            let callId = WireValue.string(object["call_id"]) ?? fallbackCallId, let rowId = WireValue.string(object["row_id"]),
            let speaker = (object["speaker"] as? String).flatMap(CallSpeaker.init(rawValue:))
        else { return nil }
        self.init(
            callId: callId, seq: WireValue.int(object["seq"]), rowId: rowId, speaker: speaker,
            text: WireValue.string(object["text"]) ?? "", final: object["final"] as? Bool ?? true)
    }
}

// MARK: - Encoding

/// What the phone sends as text. Encoded with sorted keys so the bytes are the same every time (golden tests).
public enum CallOutbound: Sendable, Equatable {
    case hello
    case list(id: String)
    case start(id: String, botKey: String, engine: CallEngine)
    case join(id: String, callId: String, since: Int?)
    case leave(id: String, callId: String)
    case take(id: String, callId: String)
    case end(id: String, callId: String)
    case say(id: String, callId: String, text: String)
    case eos(callId: String, epoch: UInt32)
    case bargeIn(callId: String, epoch: UInt32)
    /// S27: the owner declined a ring the box started (before anyone answered it). The hub ends it `declined`.
    case ringDecline(id: String, callId: String)
    case ping

    public var json: String {
        var body: [String: Any]
        switch self {
        case .hello: body = ["type": "hello", "proto": 1]
        case .list(let id): body = ["type": "call.list", "id": id]
        case .start(let id, let botKey, let engine): body = ["type": "call.start", "id": id, "bot_key": botKey, "engine": engine.rawValue]
        case .join(let id, let callId, let since):
            body = ["type": "call.join", "id": id, "call_id": callId]
            if let since { body["since"] = since }
        case .leave(let id, let callId): body = ["type": "call.leave", "id": id, "call_id": callId]
        case .take(let id, let callId): body = ["type": "call.take", "id": id, "call_id": callId]
        case .end(let id, let callId): body = ["type": "call.end", "id": id, "call_id": callId]
        case .say(let id, let callId, let text): body = ["type": "call.say_text", "id": id, "call_id": callId, "text": text]
        case .eos(let callId, let epoch): body = ["type": "audio.eos", "call_id": callId, "epoch": Int(epoch)]
        case .bargeIn(let callId, let epoch): body = ["type": "audio.barge_in", "call_id": callId, "epoch": Int(epoch)]
        case .ringDecline(let id, let callId): body = ["type": "ring.decline", "id": id, "call_id": callId]
        case .ping: body = ["type": "ping"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Binary audio frames

/// The two binary layouts (S19 R12): up `[0x01][epoch uint32 BE][PCM16 16 kHz mono]`, down
/// `[0x02][reply_id uint32 BE][PCM16 at the rate `tts.start` announced]`.
public enum CallAudioFrame {
    public static let up: UInt8 = 0x01
    public static let down: UInt8 = 0x02
    /// Mic audio is always 16 kHz mono PCM16.
    public static let uplinkSampleRate = 16_000
    /// The hub refuses a frame above 64 KiB.
    public static let maxFrameBytes = 64 * 1024

    public static func encodeUp(epoch: UInt32, pcm: Data) -> Data {
        header(up, epoch) + pcm
    }

    public static func encodeDown(replyId: UInt32, pcm: Data) -> Data {
        header(down, replyId) + pcm
    }

    /// A downlink frame, or nil when it is not one (wrong tag, too short, odd PCM length).
    public static func decodeDown(_ data: Data) -> (replyId: UInt32, pcm: Data)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5, bytes[0] == down, (bytes.count - 5) % 2 == 0 else { return nil }
        let id = bytes[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (id, Data(bytes[5...]))
    }

    /// An uplink frame (used by tests and by anything that must read what the phone sent).
    public static func decodeUp(_ data: Data) -> (epoch: UInt32, pcm: Data)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 6, bytes[0] == up, (bytes.count - 5) % 2 == 0, bytes.count <= maxFrameBytes else { return nil }
        let epoch = bytes[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (epoch, Data(bytes[5...]))
    }

    private static func header(_ tag: UInt8, _ value: UInt32) -> Data {
        Data([tag, UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }
}
