import Foundation
import Darwin

/// A reading of the monotonic clock, carried in a `Date` so the git caches keep one injectable `now`:
/// the time since an arbitrary start, which a change to the wall clock (a manual change, a network time
/// correction, a time zone trip) never moves and sleep does not stop. Only ever compared with or
/// subtracted from another such reading — an expiry, a backoff — and never shown.
public enum MonotonicDate {
    @Sendable public static func now() -> Date {
        Date(timeIntervalSinceReferenceDate: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9)
    }
}
