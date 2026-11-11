import Foundation

extension TaskWorkflow {
    /// A checked fix brought into the project, on its repository's lane, which creation, removal and
    /// pull use: it moves a branch, so nothing else of AiTerm's may interleave with it.
    /// `tip` is the commit AiTerm checked in the clone, and the only one that may land.
    public func landFix(from clone: FixClone, tip: String, in project: Project) async throws(FixRefusal) -> FixLanding {
        let git = git
        return try await BackgroundWork.run(on: Self.lane(of: project)) { () throws(FixRefusal) -> FixLanding in
            try Repository(project.path, git: git).landFix(from: clone, tip: tip)
        }
    }
}
