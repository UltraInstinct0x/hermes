import HermesActivityKit
import SwiftUI

/// The app's own icon, small, as the brand mark of every Live Activity. A widget extension cannot read the app's
/// AppIcon set, so the artwork is a plain image set in this extension's asset catalog (`HermesMark`, made from
/// `AppIcon-1024.png`); the rounded corners are drawn here. Decorative: the text next to it says "Hermes Bot".
struct NeoActivityMark: View {
    var size: CGFloat = 20

    var body: some View {
        Image(ActivityBrand.markImageName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The mark, then a title: the header of a lock screen bubble.
struct NeoBrandedTitle: View {
    let title: String
    var markSize: CGFloat = 20

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            NeoActivityMark(size: markSize)
            Text(title)
        }
    }
}
