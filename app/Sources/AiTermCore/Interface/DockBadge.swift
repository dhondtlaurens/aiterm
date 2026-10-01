import Foundation

/// The Dock tile's number: the rows Focus View steps through — needing input, or done and not yet
/// seen, terminals included. It counts `SidebarModel.needingAttention`, the list Focus View goes to
/// the first of, so the two can't drift.
public enum DockBadge {
    public static func label(for sections: [ProjectSection], skippingTasks: Set<UUID> = []) -> String? {
        let count = SidebarModel.needingAttention(sections, skippingTasks: skippingTasks).count
        return count == 0 ? nil : String(count)
    }
}
