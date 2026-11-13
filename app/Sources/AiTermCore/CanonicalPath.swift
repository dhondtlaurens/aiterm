import Foundation
import Darwin

/// A path as the kernel names it, which is how two names for one file are compared: every symlink
/// resolved, `/var/…` as `/private/var/…` (where Foundation's `resolvingSymlinksInPath` deliberately
/// keeps `/var/…`), no `.` or `..` and no trailing slash. A path that does not exist is resolved as far
/// as it does, with the rest kept as given: a checkout deleted outside AiTerm still compares equal to
/// git's record of it.
public enum CanonicalPath {
    public static func of(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let standardized = (path as NSString).standardizingPath
        let parent = (standardized as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != standardized else { return standardized }
        return (of(parent) as NSString).appendingPathComponent((standardized as NSString).lastPathComponent)
    }
}
