import AppKit
import SwiftUI
import AiTermUI
import Testing
import AiTermTestSupport
@testable import AiTermCore
@testable import AiTerm

@MainActor
struct StatusMarkTests {
    private static func spinnerRotation(atMediaTime time: CFTimeInterval) -> Double {
        time.truncatingRemainder(dividingBy: StatusMark.spinDuration) / StatusMark.spinDuration * 360
    }

    private let size: CGFloat = 40

    /// A mark drawn offscreen on black, `Space.base` of black around it so a stroke that leaves
    /// its box shows.
    private func drawn(_ status: TaskStatus, on surface: Surface = .sidebar) throws -> NSBitmapImageRep {
        let view = StatusMark(status: status, size: size)
            .surface(surface)
            .environment(\.stillSpinners, true)
            .padding(Space.base)
            .background(Color.black)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: size + 2 * Space.base, height: size + 2 * Space.base)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// The pixel `radius` points from the mark's centre, `degrees` clockwise from three o'clock.
    private func pixel(_ bitmap: NSBitmapImageRep, radius: CGFloat, degrees: CGFloat) throws -> NSColor {
        let scale = CGFloat(bitmap.pixelsWide) / (size + 2 * Space.base)
        let centre = CGFloat(bitmap.pixelsWide) / 2
        let angle = degrees * .pi / 180
        let x = Int(centre + radius * scale * cos(angle)), y = Int(centre + radius * scale * sin(angle))
        return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    /// Whether `pixel` is `color` as the mark draws it: resolved in the dark appearance the host
    /// draws in, and laid over the black behind it. A translucent ink such as `Palette.spinner`
    /// (`muted`, the system's secondary label) is a grey there, not its opaque white.
    private func matches(_ pixel: NSColor, _ color: Color) throws -> Bool {
        var resolved: NSColor?
        try #require(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let expected = try #require(resolved), alpha = expected.alphaComponent
        return abs(pixel.redComponent - expected.redComponent * alpha) + abs(pixel.greenComponent - expected.greenComponent * alpha)
            + abs(pixel.blueComponent - expected.blueComponent * alpha) < 0.08
    }

    private func isBlack(_ pixel: NSColor) -> Bool {
        pixel.redComponent + pixel.greenComponent + pixel.blueComponent < 0.03
    }

    /// The middle of the stroke: half a stroke in from the box's edge.
    private var band: CGFloat { size / 2 - size * 0.15 / 2 }

    /// Needs input and done are rings like every other look (proposal 1A, 21 Oct 2026): their
    /// colour on the band all the way round, nothing inside it.
    @Test(arguments: [(TaskStatus.needsInput, Palette.amber), (.done, Palette.done)])
    func isARingNotADisc(status: TaskStatus, color: Color) throws {
        let bitmap = try drawn(status)
        for degrees in stride(from: CGFloat(0), to: 360, by: 45) {
            #expect(try matches(pixel(bitmap, radius: band, degrees: degrees), color), "\(status) at \(degrees)°")
        }
        #expect(isBlack(try pixel(bitmap, radius: 0, degrees: 0)), "\(status) is filled in")
        #expect(isBlack(try pixel(bitmap, radius: size * 0.25, degrees: 90)), "\(status) is filled in")
    }

    /// On the accent the done ring is white, as the arc is: the accent on the accent would vanish.
    /// Amber stays amber.
    @Test func onTheAccentDoneIsWhiteAndNeedsInputStaysAmber() throws {
        #expect(try matches(pixel(drawn(.done, on: .accent), radius: band, degrees: 90), Palette.onAccent))
        #expect(try matches(pixel(drawn(.needsInput, on: .accent), radius: band, degrees: 90), Palette.amber))
    }

    /// The track is whole. It used to leave out the slice the arc rests on, from three o'clock to
    /// about five past four, which showed as a gap once the arc turned away from it.
    @Test func theWorkingTrackIsWhole() throws {
        let bitmap = try drawn(.working)
        for degrees in stride(from: CGFloat(5), to: 300, by: 10) {
            #expect(!isBlack(try pixel(bitmap, radius: band, degrees: degrees)), "no track at \(degrees)°")
        }
    }

    /// Every look stays inside its `size` box (proposal 2A, 21 Oct 2026): the arc used to straddle
    /// the circle and reach half a stroke past the idle ring's edge.
    @Test(arguments: [TaskStatus.idle, .working, .needsInput, .background, .done])
    func staysInsideItsBox(status: TaskStatus) throws {
        let bitmap = try drawn(status)
        for degrees in stride(from: CGFloat(0), to: 360, by: 15) {
            #expect(isBlack(try pixel(bitmap, radius: size / 2 + 1.5, degrees: degrees)), "\(status) leaves its box at \(degrees)°")
        }
    }

    /// A background mark is the ring in dashes, in the arc's ink: around it ink and black take turns, and there are
    /// `backgroundDashes` of each. On the accent it is white, as the arc is.
    @Test func aBackgroundMarkIsADashedRing() throws {
        for (surface, ink) in [(Surface.sidebar, Palette.spinner), (.accent, Palette.onAccent)] {
            let bitmap = try drawn(.background, on: surface)
            let ring = size / 2 - size * 0.15 / 2
            let pixels = try (0..<360).map { try pixel(bitmap, radius: ring, degrees: CGFloat($0)) }
            let inked = pixels.map { !isBlack($0) }
            let dashes = zip(inked, inked.dropFirst() + [inked[0]]).filter { !$0 && $1 }.count
            #expect(dashes == StatusMark.backgroundDashes, "on \(surface): \(dashes) dashes")
            #expect(try pixels.contains { try matches($0, ink) }, "on \(surface): not in the arc's ink")
        }
    }

    /// A window the mark is really in, so its arc joins a layer tree Core Animation draws.
    private func hostInWindow(_ view: some View) -> (NSWindow, NSHostingView<some View>) {
        let host = NSHostingView(rootView: view.background(Color.black))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = testWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: [.borderless])
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
        circularDistance(try angle(host), Self.spinnerRotation(atMediaTime: CACurrentMediaTime()))
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
            .padding(size * 0.15 / 2)
            .frame(width: size, height: size)
        let (shapeWindow, shapeHost) = hostInWindow(shape)
        defer { shapeWindow.close() }
        let (window, host) = hostInWindow(StatusMark(status: .working, size: size))
        defer { window.close() }
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
        defer { first.close() }
        pump(0.43)
        let (second, b) = hostInWindow(StatusMark(status: .working, size: size))
        defer { second.close() }
        pump(0.27)

        #expect(circularDistance(try angle(a), try angle(b)) < 0.5)
        #expect(try offsetFromClock(a) < 3)
    }

    /// The arc turns on Core Animation's clock, not on an update per frame: over half a second
    /// (some thirty frames) its view is not updated at all, and the arc has still moved.
    @Test func aWorkingMarkTurnsWithoutAnUpdatePerFrame() throws {
        let (window, host) = hostInWindow(StatusMark(status: .working, size: size))
        defer { window.close() }
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
        defer { window.close() }
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
        defer { window.close() }
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
        defer { window.close() }
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
        defer { window.close() }
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
