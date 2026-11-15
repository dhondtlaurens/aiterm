import Foundation

public enum StallWatch {
    public static func isQuietWhileWorking(transcriptGrewAt: Date?, sessionWorkingSince: Date?, callOpenSince: Date? = nil,
                                           now: Date) -> Bool {
        guard let grew = transcriptGrewAt, !isCallRunning(since: callOpenSince, now: now) else { return false }
        let since = max(grew, sessionWorkingSince ?? grew)
        return now.timeIntervalSince(since) >= TimeInterval(OperatorTiming.liveQuietMinutes) * 60
    }

    public static func isCallRunning(since: Date?, now: Date) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) < TimeInterval(OperatorTiming.openCallMinutes) * 60
    }
}
