import Foundation

public enum StallWatch {
    public static func isCallRunning(since: Date?, now: Date) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) < TimeInterval(OperatorTiming.openCallMinutes) * 60
    }
}
