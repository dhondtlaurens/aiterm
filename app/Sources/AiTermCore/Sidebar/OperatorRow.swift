import Foundation

public enum OperatorRow {
    public static func id(of run: UUID) -> UUID {
        var bytes = run.uuid
        bytes.0 ^= 0xFF; bytes.7 ^= 0xFF; bytes.15 ^= 0xFF
        return UUID(uuid: bytes)
    }
}
