import Foundation

/// The build's own push environment, as the box wants it with a token: `sandbox` or `production`.
/// Ported from Hermes Bot (`HermesKit/Push/LockScreenCopy.swift`), the same rule as its S22 push and S27 VoIP tokens.
public enum ApsEnvironment {
    /// `embedded.mobileprovision` is a signed blob around an XML plist: cut the plist out and read `Entitlements`.
    public static func parse(provisioningProfile data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)), start.lowerBound < end.upperBound else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        guard
            let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
            let entitlements = root["Entitlements"] as? [String: Any],
            let value = entitlements["aps-environment"] as? String
        else { return nil }
        return value == "development" ? "sandbox" : "production"
    }

    /// No profile in the app bundle means a TestFlight or App Store build: production.
    public static func current(profileURL: URL?, isSimulatorOrDebugFallback: Bool) -> String {
        if let url = profileURL, let data = try? Data(contentsOf: url), let found = parse(provisioningProfile: data) { return found }
        return isSimulatorOrDebugFallback ? "sandbox" : "production"
    }
}
