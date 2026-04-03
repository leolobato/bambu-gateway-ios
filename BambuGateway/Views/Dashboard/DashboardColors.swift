import SwiftUI

extension Color {
    static let dashboardBackground = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1) // #0F0F1A
                : .systemGroupedBackground
        }
    )

    static let cardBackground = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1) // #1A1A2E
                : .systemBackground
        }
    )

    static let cardBackgroundInner = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.075, green: 0.075, blue: 0.165, alpha: 1) // #13132A
                : .secondarySystemBackground
        }
    )

    static let accentBlue = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.333, green: 0.6, blue: 1.0, alpha: 1) // #5599FF
                : .tintColor
        }
    )

    static let tempOrange = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 1.0, green: 0.533, blue: 0.267, alpha: 1) // #FF8844
                : UIColor(red: 0.867, green: 0.4, blue: 0.133, alpha: 1) // #DD6622
        }
    )

}
