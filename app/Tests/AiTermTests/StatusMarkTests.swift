import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
struct StatusMarkTests {
    private let size: CGFloat = 40

    @Test func spinnerRotationUsesAContinuousSharedClock() {
        let start = Date(timeIntervalSinceReferenceDate: 220)
        let quarterTurn = start.addingTimeInterval(0.275)
        let nextCycle = start.addingTimeInterval(1.1)
        let startRotation = StatusMark.spinnerRotation(at: start)
        let quarterRotation = StatusMark.spinnerRotation(at: quarterTurn)
        let nextCycleRotation = StatusMark.spinnerRotation(at: nextCycle)
        let quarterAdvance = (quarterRotation - startRotation + 360)
            .truncatingRemainder(dividingBy: 360)

        #expect(abs(quarterAdvance - 90) < 0.0001)
        let cycleDifference = abs(nextCycleRotation - startRotation)
        #expect(min(cycleDifference, 360 - cycleDifference) < 0.0001)
    }

    private func solidFillRatio(for status: TaskStatus, color: Color) throws -> Double {
        let view = StatusMark(status: status, size: size)
            .background(Color.black)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let expected = try #require(NSColor(color).usingColorSpace(.sRGB))
        let scale = CGFloat(bitmap.pixelsWide) / size
        let center = CGFloat(bitmap.pixelsWide - 1) / 2
        let sampleRadius = size * scale * 0.3
        var matching = 0
        var sampled = 0

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard hypot(CGFloat(x) - center, CGFloat(y) - center) <= sampleRadius,
                      let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                sampled += 1
                let difference = abs(pixel.redComponent - expected.redComponent)
                    + abs(pixel.greenComponent - expected.greenComponent)
                    + abs(pixel.blueComponent - expected.blueComponent)
                if difference < 0.08 { matching += 1 }
            }
        }

        return Double(matching) / Double(sampled)
    }

    @Test func doneIsASolidBlueDot() throws {
        #expect(try solidFillRatio(for: .done, color: Palette.done) > 0.98)
    }

    @Test func needsInputIsASolidAmberDot() throws {
        #expect(try solidFillRatio(for: .needsInput, color: Palette.amber) > 0.98)
    }
}
