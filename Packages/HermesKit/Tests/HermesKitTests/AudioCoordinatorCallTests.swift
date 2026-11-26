import Foundation
import Testing

@testable import HermesKit

/// Hermes Neo: the `.call` role, a Bot's call that CallKit runs (`App/Calls`). CallKit activates and
/// deactivates its session; the app never does, and the engine waits for `didActivate`.
@Suite("Audio coordinator: a call from a Bot through CallKit")
struct AudioCoordinatorCallTests {
    private static let pending = AudioRoleOptions(prefersSpeaker: false, systemActivation: .pending)
    private static let active = AudioRoleOptions(prefersSpeaker: false, systemActivation: .active)

    @Test func aCallKitCallSetsTheCategoryButNeverActivatesOrDeactivatesTheSession() async throws {
        let platform = FakeAudioPlatform()
        let coordinator = AudioCoordinator(platform: platform)
        let call = try await coordinator.acquire(.call, owner: "call", options: Self.pending)
        // CallKit said didActivate: the same role, now live, so the engine may be prepared.
        try await coordinator.update(call, options: Self.active)
        #expect(platform.applied.map(\.systemActivation) == [.pending, .active])
        await coordinator.release(call)
        #expect(platform.deactivations == 0, "CallKit releases its own session when its call ends")
        #expect(await coordinator.activeRole == nil)
    }

    @Test func theCallProfileIsAVoiceChatWithEchoCancellationAndTheReceiverUnlessAskedForTheSpeaker() {
        let receiver = AudioSessionProfile.for(.call, options: Self.pending)
        #expect(receiver.category == .playAndRecord && receiver.mode == .voiceChat && receiver.voiceProcessing)
        #expect(receiver.options == [.allowBluetoothHFP])
        #expect(receiver.systemActivation == .pending)
        let speaker = AudioSessionProfile.for(.call, options: AudioRoleOptions(prefersSpeaker: true, systemActivation: .active))
        #expect(speaker.options == [.allowBluetoothHFP, .defaultToSpeaker] && speaker.systemActivation == .active)
        // Every other role keeps activating the session itself.
        for role in AudioRole.allCases where role != .call {
            #expect(AudioSessionProfile.for(role).systemActivation == nil, "\(role)")
        }
        #expect(AudioRole.call > .talk && AudioRole.call.usesMicrophone)
    }

    @Test func nothingElseRecordsOrPlaysDuringACall() async throws {
        let coordinator = AudioCoordinator(platform: FakeAudioPlatform())
        _ = try await coordinator.acquire(.call, owner: "call", options: Self.pending)
        for role in [AudioRole.talk, .dictation, .recording, .listen, .playback, .wake] {
            await #expect(throws: AudioCoordinatorError.busy(.call)) {
                _ = try await coordinator.acquire(role, owner: "\(role)")
            }
        }
        #expect(await coordinator.activeRole == .call)
    }

    @Test func aCallStopsAVoiceMessage() async throws {
        let coordinator = AudioCoordinator(platform: FakeAudioPlatform())
        let playback = try await coordinator.acquire(.playback, owner: "message")
        let events = LeaseEvents(playback)
        _ = try await coordinator.acquire(.call, owner: "call", options: Self.pending)
        #expect(await events.waitFor(1) == [.ended(.role(.call))])
    }

    @Test func aPhoneCallHoldsTheBotsCallAndItCarriesOnAfter() async throws {
        let platform = FakeAudioPlatform()
        let coordinator = AudioCoordinator(platform: platform)
        let call = try await coordinator.acquire(.call, owner: "call", options: Self.active)
        let events = LeaseEvents(call)
        platform.send(.interruptionBegan)
        #expect(await events.waitFor(1) == [.paused(.interruption)])
        platform.send(.interruptionEnded(shouldResume: false))
        #expect(await events.waitFor(2) == [.paused(.interruption), .resumed])
        #expect(platform.applied.allSatisfy { $0.systemActivation == .active })
    }

    @Test func callKitLettingGoOfItsSessionAfterTheCallDoesNotPauseWhatComesNext() async throws {
        let platform = FakeAudioPlatform()
        let coordinator = AudioCoordinator(platform: platform)
        let call = try await coordinator.acquire(.call, owner: "call", options: Self.active)
        await coordinator.release(call)
        // CallKit deactivates the session after the call ended here: seen as the system taking it away.
        platform.send(.interruptionBegan)
        for _ in 0..<200 {
            let seen = await coordinator.log.contains { $0.change == .interruption(began: true) }
            if seen { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let listen = try await coordinator.acquire(.listen, owner: "listen")
        let events = LeaseEvents(listen)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(events.events.isEmpty, "no interruption is left over for the next role")
    }
}
