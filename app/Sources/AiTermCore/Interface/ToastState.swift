import Foundation

/// A short-lived in-app message. The id keeps a delayed dismissal for an older toast from
/// accidentally hiding a newer one.
public struct ToastMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let message: String

    public init(id: UUID = UUID(), message: String) {
        self.id = id
        self.message = message
    }
}

public struct ToastState: Equatable {
    public private(set) var toast: ToastMessage?

    public init(toast: ToastMessage? = nil) {
        self.toast = toast
    }

    @discardableResult
    public mutating func show(_ message: String) -> UUID {
        let toast = ToastMessage(message: message)
        self.toast = toast
        return toast.id
    }

    public mutating func dismiss(id: UUID) {
        guard toast?.id == id else { return }
        toast = nil
    }
}
