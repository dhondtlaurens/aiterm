import Foundation

/// An obsolete check is retried under the current setting, rather than counted as agreement.
struct SignalOracleSettingsChanged: LocalizedError {
    var errorDescription: String? { "The Oracle settings changed while it was reading." }
}
