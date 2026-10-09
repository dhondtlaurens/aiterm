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
        let start: CFTimeInterval = 220
        let startRotation = StatusMark.spinnerRotation(atMediaTime: start)
        let quarterRotation = StatusMark.spinnerRotation(atMediaTime: start + 0.275)
        let nextCycleRotation = StatusMark.spinnerRotation(atMediaTime: start + 1.1)
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

    /// A window the mark is really in, so its arc joins a layer tree Core Animation draws.
    private func hostInWindow(_ view: some View) -> (NSWindow, NSHostingView<some View>) {
        let host = NSHostingView(rootView: view.background(Color.black))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        return (window, host)
    }

    @Observable fileprivate final class StatusModel {
        var status = TaskStatus.working
        var surface = Surface.sidebar
    }

    fileprivate struct Mark: View {
        let model: StatusModel
        let size: CGFloat
        var body: some View { StatusMark(status: model.status, size: size).surface(model.surface) }
    }

    /// The arc view inside a hosted mark, which draws the turn.
    private func arc(in view: NSView) throws -> SpinningArcView {
        func find(_ view: NSView) -> SpinningArcView? {
            if let arc = view as? SpinningArcView { return arc }
            return view.subviews.lazy.compactMap(find).first
        }
        return try #require(find(view), "no spinning arc in the mark")
    }

    /// The angle Core Animation draws the arc at now, in degrees clockwise from three o'clock.
    private func angle(_ host: NSView) throws -> Double {
        let layer = try arc(in: host).arc
        let turned = try #require(layer.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double)
        return -turned * 180 / .pi
    }

    /// How far the arc is from where the shared clock puts it, in degrees.
    private func offsetFromClock(_ host: NSView) throws -> Double {
        circularDistance(try angle(host), StatusMark.spinnerRotation(atMediaTime: CACurrentMediaTime()))
    }

    private func circularDistance(_ a: Double, _ b: Double) -> Double {
        abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The direction of the bright pixels in a view's drawing, in degrees clockwise from three
    /// o'clock. A drawing shows the layers' model values, not an animation's.
    private func drawnDirection(_ host: NSView) throws -> Double {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let centre = CGFloat(bitmap.pixelsWide - 1) / 2
        var sumX = 0.0, sumY = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                // The track is a dim grey on black; the arc is `muted`, well above it.
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      pixel.redComponent > 0.35 else { continue }
                let direction = atan2(CGFloat(y) - centre, CGFloat(x) - centre)
                sumX += Double(cos(direction)); sumY += Double(sin(direction))
            }
        }
        return atan2(sumY, sumX) * 180 / .pi
    }

    /// Unturned, the arc lies where SwiftUI's `Circle().trim(from: 0, to: 0.15)` lies, and a turn
    /// of a quarter on the layer moves it a quarter clockwise: the angle the clock gives is the
    /// angle on screen, in the direction the arc always turned.
    @Test func theArcTurnsClockwiseFromWhereTheShapeLies() throws {
        let shape = Circle().trim(from: 0, to: 0.15)
            .stroke(Palette.spinner, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
            .frame(width: size, height: size)
        let (shapeWindow, shapeHost) = hostInWindow(shape)
        defer { shapeWindow.orderOut(nil) }
        let (window, host) = hostInWindow(StatusMark(status: .working, size: size))
        defer { window.orderOut(nil) }
        pump(0.1)
        let layer = try arc(in: host).arc
        let unturned = try drawnDirection(host)
        #expect(circularDistance(unturned, try drawnDirection(shapeHost)) < 2)

        layer.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        #expect(circularDistance(try drawnDirection(host), unturned + 90) < 2)
    }

    /// Every working mark shows the same angle, however far apart they started: the one the
    /// shared clock gives.
    @Test func marksStartedApartTurnInStep() throws {
        let (first, a) = hostInWindow(StatusMark(status: .working, size: size))
        defer { first.orderOut(nil) }
        pump(0.43)
        let (second, b) = hostInWindow(StatusMark(status: .working, size: size))
        defer { second.orderOut(nil) }
        pump(0.27)

        #expect(circularDistance(try angle(a), try angle(b)) < 0.5)
        #expect(try offsetFromClock(a) < 3)
    }

    /// The arc turns on Core Animation's clock, not on an update per frame: over half a second
    /// (some thirty frames) its view is not updated at all, and the arc has still moved.
    @Test func aWorkingMarkTurnsWithoutAnUpdatePerFrame() throws {
        let (window, host) = hostInWindow(StatusMark(status: .working, size: size))
        defer { window.orderOut(nil) }
        pump(0.1)
        let before = StatusMark.arcUpdates
        let first = try angle(host)
        pump(0.37)
        let second = try angle(host)

        #expect(StatusMark.arcUpdates - before == 0, "the arc was updated \(StatusMark.arcUpdates - before) times in 0.37 s")
        #expect(circularDistance(first, second) > 30, "the arc did not turn")
    }

    /// Many working marks cost no more updates than one does: none per frame.
    @Test func manyWorkingMarksUpdateNothingPerFrame() {
        let marks = HStack(spacing: 0) {
            ForEach(0..<20, id: \.self) { _ in StatusMark(status: .working, size: size) }
            ForEach(0..<20, id: \.self) { _ in StatusMark(status: .idle, size: size) }
        }
        let (window, _) = hostInWindow(marks)
        defer { window.orderOut(nil) }
        pump(0.1)
        let before = StatusMark.arcUpdates
        pump(0.55)

        #expect(StatusMark.arcUpdates - before == 0, "twenty arcs were updated \(StatusMark.arcUpdates - before) times in 0.55 s")
    }

    /// The spell after a pause turns too, on the clock. An animation flag that outlived the
    /// working branch once latched on, and every later spell drew a still arc
    /// (docs/status-model.md, "The frozen spinner").
    @Test func aMarkThatWorksAgainTurnsAgain() throws {
        let model = StatusModel()
        let (window, host) = hostInWindow(Mark(model: model, size: size))
        defer { window.orderOut(nil) }
        pump(0.2)
        model.status = .done
        pump(0.2)
        model.status = .working
        pump(0.1)
        let first = try angle(host)
        pump(0.3)

        #expect(circularDistance(first, try angle(host)) > 30, "the second spell's arc did not turn")
        #expect(try offsetFromClock(host) < 3)
    }

    /// A row's hover or selection changes the surface, which re-runs `StatusMark`'s body and
    /// recolours the arc. The arc stays on the clock through every change.
    @Test func aSurfaceChangeLeavesTheArcInPhase() throws {
        let model = StatusModel()
        let (window, host) = hostInWindow(Mark(model: model, size: size))
        defer { window.orderOut(nil) }
        pump(0.35)
        for surface in [Surface.hover, .accent, .sidebar] {
            model.surface = surface
            pump(0.17)
            #expect(try offsetFromClock(host) < 3, "on \(surface) the arc left the clock")
        }
    }

    /// A list recycles a row's cell: the view leaves its window and comes back. The arc must be
    /// turning again, on the clock.
    @Test func aRecycledMarkTurnsAgainOnTheClock() throws {
        let model = StatusModel()
        let (window, host) = hostInWindow(Mark(model: model, size: size))
        defer { window.orderOut(nil) }
        pump(0.3)
        window.contentView = NSView()
        pump(0.3)
        window.contentView = host
        pump(0.2)
        let first = try angle(host)
        pump(0.3)

        #expect(circularDistance(first, try angle(host)) > 30, "the recycled arc did not turn")
        #expect(try offsetFromClock(host) < 3)
    }
}
