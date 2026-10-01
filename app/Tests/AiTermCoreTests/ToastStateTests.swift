import Testing
@testable import AiTermCore

@Suite struct ToastStateTests {
    @Test func dismissingAnOlderToastDoesNotHideTheNewerToast() {
        var state = ToastState()
        let first = state.show("First")
        let second = state.show("Second")

        state.dismiss(id: first)

        #expect(state.toast?.id == second)
        #expect(state.toast?.message == "Second")
    }

    @Test func dismissingTheActiveToastClearsIt() {
        var state = ToastState()
        let id = state.show("Removed task")

        state.dismiss(id: id)

        #expect(state.toast == nil)
    }
}
