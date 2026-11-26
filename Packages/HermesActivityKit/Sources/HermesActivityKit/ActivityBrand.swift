import Foundation

/// The app's name and mark as the Live Activities show them. The bubbles carry the app's icon (an image set in the
/// widget extension's own asset catalog, since an extension cannot read the app's AppIcon) and the name
/// "Hermes Bot", the app's display name. A bot's own name (a running row, a call, a request) is never replaced by it.
public enum ActivityBrand {
    /// The app's name, equal to `INFOPLIST_KEY_CFBundleDisplayName` of the app target in ios/project.yml.
    public static let name = "Hermes Bot"
    /// The image set in ios/HermesBotActivities/Assets.xcassets.
    public static let markImageName = "HermesMark"
}
