import Foundation

/// The voice call as a Live Activity: who it is with, how long it has run, and what the phone is doing.
/// Static data only here; everything that changes is in `ContentState` (ActivityKit sends it whole).
public struct CallActivityAttributes: Codable, Hashable, Sendable {
    public var botKey: String
    public var botName: String

    public init(botKey: String, botName: String) {
        self.botKey = botKey
        self.botName = botName
    }

    public struct ContentState: Codable, Hashable, Sendable {
        /// "Listening", "Speaking", "Muted", "Connecting", "On hold"... from `CallPresentation.stateLine`.
        public var stateLine: String
        /// The elapsed time is `Text(timerInterval: startedAt...)`, so it needs no update to keep counting.
        public var startedAt: Date
        public var isMuted: Bool
        /// This phone is the one talking (mute is meaningful). A listener only gets End.
        public var canMute: Bool
        /// The device that runs the call when it is not this phone ("Gokhan's Mac").
        public var ownerName: String?
        /// Requests waiting for the owner during the call.
        public var waitingRequests: Int
        /// Set once the call is over: the activity shows this and no buttons.
        public var ended: Bool
        /// The loudspeaker or a connected device has the sound (the route circle is filled).
        public var outputOn: Bool
        /// The circle on the lock screen is offered: this phone talks and no other device holds the sound.
        public var canChooseOutput: Bool

        private enum CodingKeys: String, CodingKey {
            case stateLine, startedAt, isMuted, canMute, ownerName, waitingRequests, ended, outputOn, canChooseOutput
        }

        /// A state sent before the output circle existed has no such keys: it decodes as "no circle".
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stateLine = try c.decode(String.self, forKey: .stateLine)
            startedAt = try c.decode(Date.self, forKey: .startedAt)
            isMuted = try c.decode(Bool.self, forKey: .isMuted)
            canMute = try c.decode(Bool.self, forKey: .canMute)
            ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName)
            waitingRequests = try c.decode(Int.self, forKey: .waitingRequests)
            ended = try c.decode(Bool.self, forKey: .ended)
            outputOn = try c.decodeIfPresent(Bool.self, forKey: .outputOn) ?? false
            canChooseOutput = try c.decodeIfPresent(Bool.self, forKey: .canChooseOutput) ?? false
        }

        public init(
            stateLine: String, startedAt: Date, isMuted: Bool = false, canMute: Bool = true, ownerName: String? = nil,
            waitingRequests: Int = 0, ended: Bool = false, outputOn: Bool = false, canChooseOutput: Bool = false
        ) {
            self.outputOn = outputOn
            self.canChooseOutput = canChooseOutput
            self.stateLine = stateLine
            self.startedAt = startedAt
            self.isMuted = isMuted
            self.canMute = canMute
            self.ownerName = ownerName
            self.waitingRequests = waitingRequests
            self.ended = ended
        }
    }
}
