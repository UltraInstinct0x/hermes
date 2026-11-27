// swift-tools-version: 6.2
import PackageDescription

// HermesActivityKit: the Live Activity attributes, content states and their pure presentation (words,
// countdown maths, deep links). It has NO networking and NO dependency, so the app and the widget
// extension (HermesBotActivities) both link it. The ActivityKit conformances are iOS only.
//
// Deployment targets mirror ios/Config/Base.xcconfig (tests/ios-config.test.mjs keeps them in step).
// macOS is only here so `swift test` of HermesKit runs on the Mac without a simulator.
let package = Package(
    name: "HermesActivityKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "HermesActivityKit", targets: ["HermesActivityKit"]),
    ],
    targets: [
        .target(name: "HermesActivityKit"),
        .testTarget(name: "HermesActivityKitTests", dependencies: ["HermesActivityKit"]),
    ]
)
