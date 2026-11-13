import Foundation
import AiTermCore

/// Whether a folder is there, asked on a thread of its own (`ThreadWork`): a `stat` on a mount that has stopped
/// answering stalls that thread, never the main actor or the shared pool. Opening a review in a task's worktree, a
/// window's restore and Auto-close's look at a worktree ask through it.
enum FolderCheck {
    static func exists(_ path: String) async -> Bool {
        await ThreadWork.run { FileManager.default.fileExists(atPath: path) }
    }
}
