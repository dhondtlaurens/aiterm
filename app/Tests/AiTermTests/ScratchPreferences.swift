import Foundation
@testable import AiTerm

extension InterfacePreferences {
    /// Preferences over a domain of their own (``ScratchDefaults``), so a test starts from the
    /// defaults and never reads or writes the developer's.
    static func scratch() -> InterfacePreferences {
        InterfacePreferences(defaults: ScratchDefaults.make())
    }
}
