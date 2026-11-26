import Foundation
import Testing

@testable import HermesBox

// Ported from Hermes Bot (`LockScreenCopyTests.swift`): the environment a VoIP token is registered with.
@Suite("The build's push environment, read from its provisioning profile")
struct ApsEnvironmentTests {
    private func profile(_ environment: String?) -> Data {
        let entitlements = environment.map { "<key>Entitlements</key><dict><key>aps-environment</key><string>\($0)</string></dict>" } ?? ""
        let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>\#(entitlements)<key>Name</key><string>x</string></dict></plist>"#
        // a signed blob: binary noise around the plist
        return Data([0x30, 0x82, 0x01]) + Data(plist.utf8) + Data([0x00, 0xff])
    }

    @Test func aDevelopmentProfileIsSandboxAndADistributionProfileIsProduction() {
        #expect(ApsEnvironment.parse(provisioningProfile: profile("development")) == "sandbox")
        #expect(ApsEnvironment.parse(provisioningProfile: profile("production")) == "production")
        #expect(ApsEnvironment.parse(provisioningProfile: profile(nil)) == nil)
        #expect(ApsEnvironment.parse(provisioningProfile: Data([1, 2, 3])) == nil)
    }

    @Test func noProfileMeansAStoreBuildUnlessItIsADebugOrSimulatorRun() {
        #expect(ApsEnvironment.current(profileURL: nil, isSimulatorOrDebugFallback: false) == "production")
        #expect(ApsEnvironment.current(profileURL: nil, isSimulatorOrDebugFallback: true) == "sandbox")
    }
}
