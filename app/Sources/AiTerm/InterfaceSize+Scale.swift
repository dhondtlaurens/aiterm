import AiTermCore
import AiTermUI

extension InterfaceSize {
    /// The design system's factor for this step. Core owns the preference and UI owns the
    /// numbers; neither module may import the other, so the app joins them.
    var scale: InterfaceScale {
        switch self {
        case .standard: .standard
        case .large: .large
        case .extraLarge: .extraLarge
        }
    }
}
