import Foundation

public enum Backoff {
    public static func delay(attempt: Int) -> TimeInterval { let steps: [TimeInterval] = [1, 2, 5, 10]; return steps[min(max(attempt, 0), steps.count - 1)] }
}
