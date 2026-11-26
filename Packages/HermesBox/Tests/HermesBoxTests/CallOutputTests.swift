import Foundation
import Testing

@testable import HermesBox

struct CallOutputStateTests {
    @Test func theSpeakerIsTheDefaultAndTheCircleSwapsItWithTheReceiver() {
        var state = CallOutputState()
        #expect(state.requested == .speaker && state.speakerIsOn)
        state.toggle()
        #expect(state.requested == .receiver && !state.speakerIsOn)
        state.toggle()
        #expect(state.requested == .speaker)
    }

    @Test func atTheEarTheReceiverIsUsedWhateverWasChosenAndTheChoiceReturnsWhenItIsTakenAway() {
        var state = CallOutputState(preference: .speaker)
        state.nearEar = true
        #expect(state.requested == .receiver)
        state.nearEar = false
        #expect(state.requested == .speaker)
    }

    @Test func aConnectedDeviceWinsAndTheCircleIsNotOffered() {
        var state = CallOutputState(preference: .speaker, externalDevice: true, nearEar: true)
        #expect(state.requested == nil, "the system keeps the sound on the device")
        #expect(!state.offersChoice && !state.watchesProximity)
        state.toggle()
        #expect(state.preference == .speaker, "a tap does nothing while a device has the sound")
    }

    @Test func theProximitySensorIsWatchedOnlyWhileThePhoneItselfMakesTheSound() {
        #expect(CallOutputState().watchesProximity)
        #expect(!CallOutputState(externalDevice: true).watchesProximity)
    }

    @Test func theRouteButtonIsFilledWhileTheSpeakerOrADeviceHasTheSoundAndQuietAtTheEar() {
        #expect(CallOutputState(routeKind: .speaker).routeIsFilled)
        #expect(CallOutputState(externalDevice: true, routeKind: .external).routeIsFilled)
        #expect(!CallOutputState(routeKind: .receiver).routeIsFilled)
    }

    @Test func theWordsFollowTheRealRoute() {
        #expect(CallOutputPresentation.routeValue(CallOutputState(routeKind: .speaker)) == "The speaker is on")
        #expect(CallOutputPresentation.routeValue(CallOutputState(routeKind: .receiver)).contains("receiver"))
        #expect(CallOutputPresentation.routeValue(CallOutputState(routeKind: .external)).contains("connected device"))
    }
}
