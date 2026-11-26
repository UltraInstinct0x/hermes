#if os(iOS)
import SwiftUI
import UIKit

/// Hermes Bot's colours and sizes (`ios/HermesBot/Theme.swift`), the ones its call screen uses, so the ported call
/// screen looks exactly as it did there. System roles only: they adapt to light, dark and Increase Contrast.
enum NeoCallTheme {
    static let background = Color(uiColor: .systemBackground)
    static let botBubble = Color(uiColor: .secondarySystemBackground)
    /// Hermes Bot's accent: the system blue (it had no accent colour of its own).
    static let userBubble = Color(uiColor: .systemBlue)
    static let onUserBubble = Color(uiColor: .systemBackground)
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let problem = Color(uiColor: .systemOrange)
    /// Minimum tap target (Apple HIG: 44 pt).
    static let tapTarget: CGFloat = 44
}
#endif
