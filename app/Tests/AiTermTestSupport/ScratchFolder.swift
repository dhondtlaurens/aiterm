import Foundation

/// An empty, unique directory. The caller removes it when its fixture ends.
public enum ScratchFolder {
    public static func make(_ prefix: String = "aiterm-test-") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
