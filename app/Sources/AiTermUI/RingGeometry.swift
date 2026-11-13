import SwiftUI

/// Round marks share a 15% stroke, kept inside their diameter. A trimmed circle's
/// centered stroke needs the same half-stroke inset that strokeBorder supplies.
public enum RingGeometry {
    public static func strokeWidth(_ diameter: CGFloat) -> CGFloat { diameter * 0.15 }
    public static func inset(_ diameter: CGFloat) -> CGFloat { strokeWidth(diameter) / 2 }
}
