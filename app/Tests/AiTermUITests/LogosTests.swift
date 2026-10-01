import AppKit
import Testing
@testable import AiTermUI

@MainActor
struct LogosTests {
    /// Two marks are two images, however their path data starts. The cache used to key on the
    /// fill and the path's first 24 characters, so a second mark sharing that prefix was drawn as
    /// the first.
    @Test func marksThatStartAlikeAreCachedApart() {
        let prefix = "M0 0h24v24H0zM0 0h24v24H0z"
        let first = Logos.image(path: prefix + "M2 2h4v4H2z", fill: "#FFFFFF")
        let second = Logos.image(path: prefix + "M2 2h8v8H2z", fill: "#FFFFFF")
        #expect(first != nil && second != nil)
        #expect(first !== second)
    }

    @Test func aMarkIsRasterisedOncePerFill() {
        let path = Logos.jiraPath
        #expect(Logos.image(path: path, fill: "#2684FF") === Logos.image(path: path, fill: "#2684FF"))
        #expect(Logos.image(path: path, fill: "#2684FF") !== Logos.image(path: path, fill: "#FFFFFF"))
    }
}
