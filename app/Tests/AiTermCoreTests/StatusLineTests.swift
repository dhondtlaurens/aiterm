import Foundation
import Testing
@testable import AiTermCore

/// Where the Operator's status line runs and how each stretch is inked (decision 7, O7, the folded stop).
struct StatusLineTests {
    private let op = OperatorSession.rowID
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private let shop = UUID(), docs = UUID(), rule = UUID()

    private func piece(_ above: StatusLineInk?, _ below: StatusLineInk?, _ node: StatusLinePiece.Node = .mark) -> StatusLinePiece {
        StatusLinePiece(above: above, below: below, node: node)
    }

    @Test func oneTaskJoinsTheOperatorsMarkToItsMark() {
        let rows: [StatusLine.Row] = [.operatorRow, .heading(shop, folded: false, tasks: [a]), .task(a)]
        #expect(StatusLine.pieces(rows: rows, workload: [a]) == [
            op: piece(nil, .rest), shop: piece(.rest, .rest, .none), a: piece(.rest, nil)
        ])
    }

    @Test func noWorkloadOrNoOperatorRowDrawsNoLine() {
        let rows: [StatusLine.Row] = [.operatorRow, .heading(shop, folded: false, tasks: [a]), .task(a)]
        #expect(StatusLine.pieces(rows: rows, workload: []).isEmpty)
        #expect(StatusLine.pieces(rows: Array(rows.dropFirst()), workload: [a]).isEmpty)
    }

    /// Two projects under a divider: the line runs through the first project's tasks, the divider and the second
    /// heading, to the last task.
    @Test func severalProjectsAndADivider() {
        let rows: [StatusLine.Row] = [.operatorRow, .heading(shop, folded: false, tasks: [a, b]), .task(a), .task(b),
                                      .divider(rule), .heading(docs, folded: false, tasks: [c]), .task(c)]
        #expect(StatusLine.pieces(rows: rows, workload: [a, b, c]) == [
            op: piece(nil, .rest), shop: piece(.rest, .rest, .none), a: piece(.rest, .rest), b: piece(.rest, .rest),
            rule: piece(.rest, .rest, .none), docs: piece(.rest, .rest, .none), c: piece(.rest, nil)
        ])
    }

    /// A finished task between two it runs is passed around its mark; a finished task last is off the line.
    @Test func finishedTasksInBetweenAndLast() {
        let rows: [StatusLine.Row] = [.operatorRow, .heading(shop, folded: false, tasks: [a, b, c]), .task(a), .task(b), .task(c)]
        #expect(StatusLine.pieces(rows: rows, workload: [a, c])[b] == piece(.rest, .rest))
        let last = StatusLine.pieces(rows: rows, workload: [a, b])
        #expect(last[b] == piece(.rest, nil))
        #expect(last[c] == nil)
    }

    /// Acting marches the stretch from the Operator's mark to the task's, and only it; a wake does the same up.
    @Test func anExchangeInksItsStretchOnly() {
        let rows: [StatusLine.Row] = [.operatorRow, .heading(shop, folded: false, tasks: [a, b, c]), .task(a), .task(b), .task(c)]
        for ink in [StatusLineInk.acting, .waking, .asking] {
            let pieces = StatusLine.pieces(rows: rows, workload: [a, b, c], acting: ink == .acting ? [b] : [],
                                           waking: ink == .waking ? [b] : [], asking: ink == .asking ? [b] : [])
            #expect(pieces == [op: piece(nil, ink), shop: piece(ink, ink, .none), a: piece(ink, ink), b: piece(ink, .rest),
                               c: piece(.rest, nil)], "\(ink)")
        }
    }

    /// O7: where an act and a question share a stretch the act shows, the question's own stretch stays amber beyond
    /// it; a wake shows over an act; on one task the moving exchange wins.
    @Test func overlapsFollowO7() {
        let rows: [StatusLine.Row] = [.operatorRow, .task(a), .task(b), .task(c)]
        let shared = StatusLine.pieces(rows: rows, workload: [a, b, c], acting: [a], asking: [c])
        #expect(shared == [op: piece(nil, .acting), a: piece(.acting, .asking), b: piece(.asking, .asking), c: piece(.asking, nil)])
        let after = StatusLine.pieces(rows: rows, workload: [a, b, c], asking: [c])
        #expect(after[op] == piece(nil, .asking), "once the act ends, the question's stretch is amber again")
        let wake = StatusLine.pieces(rows: rows, workload: [a, b, c], acting: [c], waking: [a])
        #expect(wake[op] == piece(nil, .waking) && wake[a] == piece(.waking, .acting))
        let one = StatusLine.pieces(rows: rows, workload: [a, b, c], acting: [b], asking: [b])
        #expect(one[b] == piece(.acting, .rest))
    }

    /// An exchange with a finished task past the last one it runs reaches that task too.
    @Test func anExchangeReachesAFinishedTaskPastTheEnd() {
        let rows: [StatusLine.Row] = [.operatorRow, .task(a), .task(b)]
        #expect(StatusLine.pieces(rows: rows, workload: [a], acting: [b])[b] == piece(.acting, nil))
    }

    /// A folded project holding a task the Operator runs takes a stop, which takes the ink of an exchange with any
    /// task inside; with only finished tasks it is passed through; unfolded, its tasks' marks stand instead.
    @Test func aFoldedProjectTakesAStop() {
        func rows(folded: Bool) -> [StatusLine.Row] {
            [.operatorRow, .heading(shop, folded: folded, tasks: [a, b])] + (folded ? [] : [.task(a), .task(b)])
                + [.heading(docs, folded: false, tasks: [c]), .task(c)]
        }
        let rest = StatusLine.pieces(rows: rows(folded: true), workload: [a, c])
        #expect(rest[shop] == piece(.rest, .rest, .stop(.rest)))
        let acting = StatusLine.pieces(rows: rows(folded: true), workload: [a, c], acting: [b])
        #expect(acting[op] == piece(nil, .acting) && acting[shop] == piece(.acting, .rest, .stop(.acting)))
        let asking = StatusLine.pieces(rows: rows(folded: true), workload: [a, c], asking: [a])
        #expect(asking[shop] == piece(.asking, .rest, .stop(.asking)))
        let finished = StatusLine.pieces(rows: rows(folded: true), workload: [c])
        #expect(finished[shop] == piece(.rest, .rest, .none), "only finished tasks inside: passed through, no stop")
        let open = StatusLine.pieces(rows: rows(folded: false), workload: [a, c])
        #expect(open[shop] == piece(.rest, .rest, .none) && open[a] == piece(.rest, .rest))
    }

    /// A folded project last in the section ends the line at its stop.
    @Test func aFoldedProjectLastEndsTheLineAtItsStop() {
        let rows: [StatusLine.Row] = [.operatorRow, .heading(docs, folded: false, tasks: [c]), .task(c), .divider(rule),
                                      .heading(shop, folded: true, tasks: [a, d])]
        let pieces = StatusLine.pieces(rows: rows, workload: [c, d], acting: [d])
        #expect(pieces[shop] == piece(.acting, nil, .stop(.acting)))
        #expect(pieces[rule] == piece(.acting, .acting, .none) && pieces[c] == piece(.acting, .acting))
        #expect(StatusLine.pieces(rows: rows, workload: [c])[shop] == nil, "nothing of the Operator's in it: off the line")
    }
}
