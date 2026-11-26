// swift-tools-version: 6.2
import PackageDescription

// Hermes Neo: the box half of the app, ported from the owner's Hermes Bot app (hermes-bot-app, ios/Packages/HermesKit).
// Pairing with the box BFF, the device bearer, "Calls from your bots" (PushKit VoIP registration, the ring decision
// and coordinator for CallKit) and the call client of the box's call hub. Its own package so it never collides with
// upstream's HermesKit (both have a `PairingLink`, a `HermesKit` module and more); the app glue lives in App/Calls.
let package = Package(
    name: "HermesBox",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "HermesBox", targets: ["HermesBox"]),
    ],
    targets: [
        .target(name: "HermesBox"),
        .testTarget(
            name: "HermesBoxTests",
            dependencies: ["HermesBox"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
