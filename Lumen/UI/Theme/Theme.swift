import SwiftUI
import UIKit

/// Design tokens. Dark-first neutral palette with subtle elevated surfaces and hairline borders.
/// Every color adapts to light mode and to Increase Contrast.
enum Theme {
    static let background = Color(dynamic: .init(white: 0.04, alpha: 1), light: .init(red: 0.96, green: 0.96, blue: 0.97, alpha: 1),
                                  darkHighContrast: .black, lightHighContrast: .white)
    static let surface = Color(dynamic: .init(white: 1, alpha: 0.06), light: .init(white: 0, alpha: 0.04),
                               darkHighContrast: .init(white: 1, alpha: 0.12), lightHighContrast: .init(white: 0, alpha: 0.08))
    static let surfaceElevated = Color(dynamic: .init(white: 0.11, alpha: 1), light: .white,
                                       darkHighContrast: .init(white: 0.16, alpha: 1), lightHighContrast: .white)
    static let border = Color(dynamic: .init(white: 1, alpha: 0.08), light: .init(white: 0, alpha: 0.08),
                              darkHighContrast: .init(white: 1, alpha: 0.3), lightHighContrast: .init(white: 0, alpha: 0.35))
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let live = Color(red: 0.95, green: 0.27, blue: 0.27)

    static let cornerRadius: CGFloat = 14
    static let smallCornerRadius: CGFloat = 10
    static let horizontalPadding: CGFloat = 16

    static func greeting(for date: Date = .now) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Good night"
        }
    }
}

extension Color {
    init(dynamic dark: UIColor, light: UIColor, darkHighContrast: UIColor, lightHighContrast: UIColor) {
        self.init(uiColor: UIColor { traits in
            let highContrast = traits.accessibilityContrast == .high
            if traits.userInterfaceStyle == .light {
                return highContrast ? lightHighContrast : light
            }
            return highContrast ? darkHighContrast : dark
        })
    }
}

/// Short, subtle transitions; disabled when Reduce Motion is on.
struct LumenAnimation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: AnyHashable

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
    }
}

extension View {
    func lumenAnimation<V: Hashable>(value: V) -> some View {
        modifier(LumenAnimation(value: AnyHashable(value)))
    }

    /// Rounded card surface with a hairline border.
    func cardStyle(cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}
