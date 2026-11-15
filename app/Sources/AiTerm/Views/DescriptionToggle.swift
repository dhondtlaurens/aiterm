import SwiftUI
import AiTermUI

struct DescriptionToggle: View {
    let label: String
    @Binding var isOn: Bool
    let help: String
    init(_ label: String, isOn: Binding<Bool>, help: String) { self.label = label; self._isOn = isOn; self.help = help }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            Toggle(label, isOn: $isOn).toggleStyle(.checkbox).font(Typography.body)
            HelpText(help).padding(.leading, Space.section)
        }
    }
}
