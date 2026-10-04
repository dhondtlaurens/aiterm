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

    @Test func aToastCarriesItsSymbolAndDefaultsToTheCheckmark() {
        var state = ToastState()
        state.show("Saved.")
        #expect(state.toast?.symbol == "checkmark.circle.fill")
        state.show("Backpack Mode on · joined Phone", symbol: "backpack.fill")
        #expect(state.toast?.symbol == "backpack.fill")
    }
}
