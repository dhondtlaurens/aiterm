/// One headless CLI request, including its answer file when the CLI writes one.
public struct HeadlessInvocation: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var answerFile: String?
}
