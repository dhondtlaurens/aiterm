import Foundation

// When a task is done, in its several senses, in one place.

public extension OperatedState {
    /// Not yet ended: what Stop can still stop. `inReview` waits on a review of its request.
    var isOpen: Bool { [.planned, .queued, .working, .inReview, .blocked, .failed].contains(self) }
}

public extension OperatedTask {
    /// The ends a task reaches by being done: no change needed, published, stopped, or accepted with
    /// nothing left to publish (a commit end, or a publication left for you).
    var isFinished: Bool {
        state == .noChange || state == .published || state == .stopped
            || (state == .accepted && (end == .commit || publication?.leftForYou == true))
    }

    /// Whether Stop Task… is offered for it: while it is open, and while it is accepted with its publication not left for
    /// you (it still awaits its `finish_task`). The one rule for its sidebar row's menu and its row's on the board.
    public var isStoppable: Bool { state.isOpen || (state == .accepted && publication?.leftForYou != true) }

    /// Finished by reaching its end: published, accepted on a commit end, or ended with no change; not failed, stopped
    /// or with its publication left for you. The one rule for it: the broadcast's closing closes these tasks, and the
    /// board says which of them it kept.
    var reachedItsEnd: Bool {
        state == .published || state == .noChange || (state == .accepted && end == .commit && publication?.leftForYou != true)
    }
}
