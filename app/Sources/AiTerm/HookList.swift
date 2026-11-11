import Foundation

/// What hears of a change an owner announces: hooks run in the order they were added, and each is added with a token
/// that an owner which goes first takes it out again with. An owner with room for one listener names it a single slot
/// instead (`RowFocus.setRestoreOwedRow`), and a new one replaces it.
///
/// A reference, so running the hooks holds no access to the owner's property: a hook may add or take out hooks
/// meanwhile, which counts from the next run — this one runs the hooks as they were when it began.
@MainActor
final class HookList<Value> {
    /// A hook added, for taking it out again.
    struct Token: Hashable {
        fileprivate let serial: Int
    }

    private var hooks: [(token: Token, run: @MainActor (Value) -> Void)] = []
    private var added = 0

    init() {}

    /// Adds `hook`, to run after the ones added before it.
    @discardableResult
    func add(_ hook: @escaping @MainActor (Value) -> Void) -> Token {
        added += 1
        let token = Token(serial: added)
        hooks.append((token, hook))
        return token
    }

    /// Takes out the hook `token` added; nothing if it is already out.
    func remove(_ token: Token) {
        hooks.removeAll { $0.token == token }
    }

    /// Runs every hook with `value`, in the order they were added.
    func callAsFunction(_ value: Value) {
        for hook in hooks { hook.run(value) }
    }
}

extension HookList where Value == Void {
    @discardableResult
    func add(_ hook: @escaping @MainActor () -> Void) -> Token { add { (_: Void) in hook() } }

    func callAsFunction() { self(()) }
}
