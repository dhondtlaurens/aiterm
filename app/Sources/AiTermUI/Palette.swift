import SwiftUI
import AppKit

/// The alpha of the white wash painted over a hovered sidebar row. A named top-level constant, not
/// an enum member, so it reads as what it is — a number, not a colour — rather than sitting among
/// `Palette`'s colour members.
private let rowHoverAlpha = 0.045

/// AiTerm is dark-only, so its greys are literal values rather than AppKit's semantic colours: a
/// graphite ramp of grounds, three inks and two hairlines. Grounds are the same with or without
/// Increase Contrast; inks and hairlines resolve to a stronger value of their own under it
/// (`contrast(_:_:)`). The accent, the status semantics and links stay AppKit's; brand marks keep
/// their vendor colours; terminal-background matching remains opt-in.
public enum Palette {
    /// `0xRRGGBB` as a colour. `Brand` reads it too, so a vendor's number is decoded one way.
    fileprivate static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// `0xRRGGBB` as an sRGB `NSColor`, for `contrast(_:_:)`.
    private static func srgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// White at `alpha`, as an sRGB `NSColor`, for `contrast(_:_:)`.
    private static func white(_ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
    }

    /// A colour that is `standard` in the dark appearance and `highContrast` under Increase Contrast
    /// (`.accessibilityHighContrastDarkAqua`). AppKit resolves it per drawing appearance, as it does
    /// its own semantic colours, so a view needs to know nothing about the setting.
    private static func contrast(_ standard: NSColor, _ highContrast: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { IncreaseContrast.isOn(in: $0) ? highContrast : standard })
    }

    // -- grounds, darkest first -------------------------------------------------------------
    /// The well, sunk below everything that holds it: the command block.
    public static let well = hex(0x111214)
    /// The command preview block in a sheet: the well, declared as an alias so the block reads
    /// locally.
    public static let codeBackground = well
    /// What you type into or pick from, a step darker than the ground it sits on: `fieldBox` (an
    /// `Input`, a `Select`, the prompt editor's box) and a segmented control's track.
    public static let field = hex(0x141518)
    /// The window: the sidebar and anything drawn flush on it, its titlebar band included. "Use dark
    /// terminal background" paints AiTerm's iTerm2 windows this too (`#17181B`, the daemon's
    /// `set_aiterm_background`), so the terminal and the sidebar read as one surface.
    public static let sidebar = hex(0x17181B)
    /// The sidebar footer's own ground under its System and Usage telemetry: a step darker than the
    /// window, between the well and a field, so the readings sit apart from the list above them.
    public static let sidebarFooter = hex(0x131416)
    /// The sheet: its whole ground, its footer included, a step lighter than the window it hangs on.
    public static let surface = hex(0x1E1F23)
    /// Cards and groups on a sheet: `groupChrome`'s default fill — a Settings card, a board card, a
    /// question waiting on you.
    public static let surfaceRaised = hex(0x26272C)
    /// The fill of anything that hangs over content: a dropdown, a `SearchPicker`'s results, the
    /// completion popup, the background-work card and the toast (`menuChrome`). Lighter than a card,
    /// so a popup over a card still stands off it.
    public static let menu = hex(0x2A2C31)
    /// A secondary button's fill: lighter than every ground it stands on, where a field is darker.
    public static let button = hex(0x2F3137)
    /// The selected segment of a `SegmentedControl` and the avatar
    /// group's `+n`: the lightest ground, so a selection stands off the `field` track it sits in.
    public static let controlActive = hex(0x383A41)

    // -- inks -------------------------------------------------------------------------------
    /// The default label colour: row titles, field values, button labels and most on-screen text.
    /// White under Increase Contrast.
    public static let text = contrast(srgb(0xECEDEF), srgb(0xFFFFFF))
    /// Secondary text: captions, help copy, timestamps and anything subordinate to the primary
    /// label.
    public static let muted = contrast(srgb(0xA1A4AC), srgb(0xC6C9D0))
    /// The third ink, behind `muted`: the idle ring (`idleRing`) and whatever has to recede
    /// further than secondary text.
    public static let tertiary = contrast(srgb(0x6E717A), srgb(0x9DA0A9))

    // -- hairlines --------------------------------------------------------------------------
    /// The soft hairline: a separator between rows (`Hairline`) and a card's or group's edge
    /// (`groupChrome`).
    public static let border = contrast(white(0.07), white(0.22))
    /// The firm hairline: a field's outline (`fieldBox`), a popover's edge (`menuChrome`) and a
    /// sheet-level edge, which has to hold against a darker or a floating ground.
    public static let borderStrong = contrast(white(0.12), white(0.32))

    /// The system accent colour: primary buttons, focus rings, switches and checkboxes.
    public static let accent = Color(nsColor: .controlAccentColor)
    /// The focus ring's halo (`focusRing`): the accent at 22 %, three points outside the control, around
    /// `focusEdge` — a hint, not a second border competing with a segmented track's own.
    public static let focusRing = accent.opacity(0.22)
    /// The focus ring's edge: a one-point stroke on the control's own edge, the accent at 80 %. The
    /// value `accentPressed` already has, declared as an alias.
    public static let focusEdge = accentPressed
    /// A clickable link's text colour, e.g. a URL or cross-reference inside body copy.
    public static let link = Color(nsColor: .linkColor)
    /// The positive/success semantic: a passing check, a connected status, a completed state shown
    /// inline.
    public static let green = Color(nsColor: .systemGreen)
    /// The warning semantic: a status needing attention without being an outright error.
    public static let amber = Color(nsColor: .systemOrange)
    /// The destructive semantic: an irreversible, data-losing action. SwiftUI's `role: .destructive`
    /// already supplies this colour at every call site that needs it (the three "Remove…" menu items
    /// in `SidebarView.swift`) — this token exists so the design system can *express* that colour,
    /// not so Swift call sites start reaching for it explicitly.
    public static let destructive = Color(nsColor: .systemRed)
    /// The pip colour on a badge that needs to draw the eye, e.g. an unread or pending count. The
    /// badge pip and the general amber semantic are the same colour family. Previously written
    /// twice as the identical `Color(nsColor: .systemOrange)` — the same defect this task removes
    /// elsewhere, caught by `PaletteDistinctionTests` rather than listed in the 4b brief.
    public static let badgeAmber = amber
    /// Lines a checkout adds against the branch it started from — the `+12` on the VS Code badge.
    /// The positive semantic, declared as an alias because it is the same green, not a new one.
    public static let diffAdded = green
    /// Lines a checkout removes against the branch it started from — the `−3` beside `diffAdded`.
    public static let diffRemoved = destructive
    /// The DEV pill a local build draws over its Dock icon (`DevBuildIcon`), so it is never mistaken
    /// for the release in Applications. The warning family, declared as an alias of `amber`.
    public static let devBuild = amber
    /// The "DEV" lettering on `devBuild`. White, like everything on a saturated fill: the pill sits
    /// on the app icon, not on the window, so no appearance-resolving label colour applies. An alias
    /// of `onAccent`, the one solid white this file writes.
    public static let devBuildInk = onAccent

    // -- on the accent ------------------------------------------------------------------
    /// Ink on the accent: a primary button's label, marks and keycaps.
    /// Literal white: the accent is saturated, and AppKit's own text on it is white.
    /// `Surface.accent.ink` is this — and so is a selected row's title (`Surface.selected.ink`),
    /// which lifts to full white on the neutral selection while everything else on the row keeps
    /// its resting ink.
    public static let onAccent = Color.white
    /// Subordinate ink on the accent: `onAccent` at 75 %, where `muted` would be a grey on blue.
    /// `Surface.accent.secondaryInk` is this.
    public static let onAccentSecondary = onAccent.opacity(0.75)
    /// A spinner's unfilled track on the accent — a busy primary button's mark — where
    /// `spinnerTrack`'s grey would read as a smudge.
    public static let spinnerTrackOnAccent = onAccent.opacity(0.3)
    /// A keycap's fill on a primary button (`Kbd`): enough white to lift the cap off the accent.
    public static let keycapFill = onAccent.opacity(0.22)
    /// A keycap's edge, fainter than its fill, so the cap reads as one shape rather than a box.
    public static let keycapStroke = onAccent.opacity(0.16)
    /// The accent at 80 %: the accent dimmed while the pointer holds it down, and the focus ring's
    /// edge (`focusEdge`, an alias).
    public static let accentPressed = accent.opacity(0.8)

    // -- field text ---------------------------------------------------------------------
    /// A field's placeholder, where AppKit cannot draw it for us — the prompt editor's is an overlay
    /// on an `NSTextView`. AppKit's own `placeholderTextColor` itself, not a literal: that is what
    /// AppKit draws every `Input` and `SearchField` placeholder in, and the editor's hint must be
    /// no brighter or dimmer than theirs, whatever AppKit decides that colour is.
    public static let placeholder = Color(nsColor: .placeholderTextColor)
    /// Text that sits back behind the secondary copy on its own line: a completion's source,
    /// after its detail. `muted` at 80 %.
    public static let faint = muted.opacity(0.8)

    // -- vendor marks -------------------------------------------------------------------
    /// The white of a round vendor mark: the Codex, GitLab and GitHub discs, and the logo on Claude's,
    /// Jira's, Pi's and the shell's. A mark keeps its vendor's colours, not the appearance's;
    /// the same white as `onAccent`, declared as an alias.
    public static let markPaper = onAccent
    /// The black of a round vendor mark: the Pi and shell discs.
    public static let markInk = Color.black

    // Brand marks, not UI colours.
    /// Anthropic's vendor colour for the Claude logo/glyph — a brand mark, not a UI colour; never
    /// use it to colour a button or status.
    public static let claude = Brand("claude", 0xD97757, path: Logos.claudePath, fallbackSymbol: "asterisk")
    /// Atlassian's vendor colour for the Jira mark — a brand mark, not a UI colour; do not reach
    /// for it to colour general UI.
    public static let jira = Brand("jira", 0x2684FF, path: Logos.jiraPath, fallbackSymbol: "ticket")
    /// GitLab's vendor colour for its mark — a brand mark, not a UI colour; reserved for the
    /// GitLab logo/badge only.
    public static let gitlab = Brand("gitlab", 0xFC6D26, path: Logos.gitlabPath, fallbackSymbol: "triangle.fill")
    /// GitHub's mark, in white: GitHub's mark is monochrome, and the app is dark-only. A brand
    /// mark, not a UI colour; reserved for the GitHub logo/badge only. A light ground — the
    /// Integrations disc — tints it `markInk`.
    public static let github = Brand("github", 0xFFFFFF, path: Logos.githubPath, fallbackSymbol: "chevron.left.forwardslash.chevron.right")
    /// Microsoft's vendor colour for the VS Code mark — a brand mark, not a UI colour; used only
    /// where the VS Code badge appears.
    public static let vscode = Brand("vscode", 0x23A9F2, path: Logos.vscodePath, fallbackSymbol: "chevron.left.forwardslash.chevron.right")
    /// OpenAI's mark, in its own black — drawn on `VendorMark`'s white Codex disc. A brand mark,
    /// not a UI colour.
    public static let openai = Brand("openai", 0x000000, path: Logos.openaiPath, fallbackSymbol: "hexagon")

    // -- selection and washes, over a ground ----------------------------------------------
    /// A selected row's ground (`RowPill`): a neutral white wash over the sidebar or the sheet, not
    /// the accent. On it the title lifts to white and every mark keeps its own colour
    /// (`Surface.selected`).
    public static let selected = Color.white.opacity(0.09)
    /// A selected row's one-point inside edge, which keeps the pill's shape against a neighbour
    /// under the pointer. The badge wash's 6 % white, declared as an alias.
    public static let selectedEdge = badge
    /// The opaque colour a selected sidebar row's avatar ring is painted: `selected` composited over
    /// `sidebar` (`Surface.selected.occludingBackground`).
    public static let selectedSolid: Color = composited(selected, over: sidebar)
    /// The same ring on a selected row on a sheet — the Archive's: `selected` over `surface`
    /// (`Surface.selectedOnSheet.occludingBackground`).
    public static let selectedOnSheetSolid: Color = composited(selected, over: surface)
    /// A neutral translucent wash behind an unselected count chip or badge: 6 % white.
    public static let badge = Color.white.opacity(0.06)
    /// A badge under the pointer, on any ground but a selected row or the accent.
    public static let badgeHovered = Color.white.opacity(0.12)
    /// The badge wash on a selected row (or the accent): stronger than `badge`, so a chip still
    /// stands off the lighter ground.
    public static let badgeSelected = Color.white.opacity(0.11)
    /// A badge under the pointer on a selected row: stronger than `badgeSelected`, as
    /// `badgeHovered` is than `badge`.
    public static let badgeSelectedHovered = Color.white.opacity(0.17)
    /// A dropdown's highlighted row — the one the keyboard or the pointer is on (`menuRowHighlight`).
    /// Neutral, so the row keeps its resting inks and brand colours.
    public static let menuHighlight = Color.white.opacity(0.10)
    /// That row while the pointer holds it down.
    public static let menuHighlightPressed = Color.white.opacity(0.14)
    /// The translucent white wash painted behind a sidebar row while the pointer is over it.
    /// Literal white, not `.primary`: `.primary` carries its own intrinsic alpha, which compounds
    /// with `.opacity()`.
    public static let rowHover = Color.white.opacity(rowHoverAlpha)
    /// The opaque colour a hovered row's avatar ring is painted: `rowHover` composited over
    /// `sidebar`. Derived, not hardcoded, so the two can never drift. Resolved once, under the
    /// forced `.darkAqua` AiTerm always draws in — the answer cannot change, so it is a stored
    /// constant rather than a composite recomputed on every read.
    ///
    /// Composited by hand in sRGB, not with `NSColor.blended(withFraction:of:)`: that method
    /// converts through `NSCalibratedRGBColorSpace`, whose gamma differs from sRGB enough to
    /// materially distort a dark base colour. sRGB is also the space the wash actually paints in on
    /// screen, so blending its components directly is the faithful composite, not an approximation.
    public static let rowHoverSolid: Color = composited(rowHover, over: sidebar)
    /// `rowHover` over `surface`: a hovered row on a sheet, the broadcast's tasks.
    public static let rowHoverOnSheetSolid: Color = composited(rowHover, over: surface)
    /// The Operator's row at rest, behind it in `RowPill`'s pill, which selection replaces (decided 21 Oct
    /// 2026, wash A): a neutral wash of its own, fainter than the hover's, so it says the row is different
    /// without a colour meaning anything and never reads as hover. Hovered, the row takes `badgeHovered`.
    public static let operatorRow = Color.white.opacity(0.035)
    /// The opaque colour the Operator row's avatar ring is painted at rest: `operatorRow` composited over
    /// `sidebar`, as `rowHoverSolid` is `rowHover` over it, and for the same reason: a ring has to occlude.
    public static let operatorRowSolid: Color = composited(operatorRow, over: sidebar)
    /// The same ring on the Operator's row hovered: `badgeHovered` composited over `sidebar`.
    public static let operatorRowHoveredSolid: Color = composited(badgeHovered, over: sidebar)

    /// `wash` painted over `base`, opaque: blended by hand in sRGB at the wash's own alpha, as
    /// `rowHoverSolid` is, under the `.darkAqua` AiTerm always draws in.
    private static func composited(_ wash: Color, over base: Color) -> Color {
        let appearance = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        var blended = NSColor(base)
        appearance.performAsCurrentDrawingAppearance {
            let ground = NSColor(base).usingColorSpace(.sRGB) ?? NSColor(base)
            guard let top = NSColor(wash).usingColorSpace(.sRGB) else { return }
            let alpha = top.alphaComponent
            blended = NSColor(
                srgbRed: ground.redComponent * (1 - alpha) + top.redComponent * alpha,
                green: ground.greenComponent * (1 - alpha) + top.greenComponent * alpha,
                blue: ground.blueComponent * (1 - alpha) + top.blueComponent * alpha,
                alpha: 1)
        }
        return Color(nsColor: blended)
    }

    /// A collapsed project's status-count chips (`StatusCountChips`): a fill and a stroke per
    /// status family, each a wash of that family's colour. The three pairs strengthen with urgency —
    /// idle and working in `muted`, needs-input in `amber`, done in `accent` — a deliberate
    /// progression, so each is written out rather than derived from one opacity.
    public static let statusChipQuietFill = muted.opacity(0.14)
    /// The quiet chip's edge.
    public static let statusChipQuietStroke = muted.opacity(0.30)
    /// A needs-input chip's fill.
    public static let statusChipAttentionFill = amber.opacity(0.16)
    /// A needs-input chip's edge.
    public static let statusChipAttentionStroke = amber.opacity(0.38)
    /// A done chip's fill.
    public static let statusChipDoneFill = accent.opacity(0.17)
    /// A done chip's edge.
    public static let statusChipDoneStroke = accent.opacity(0.42)
    /// A faint ring drawn around an item that is idle or inactive: the third ink, declared as an
    /// alias.
    public static let idleRing = tertiary
    /// The background track behind an active spinner or progress indicator's stroke.
    public static let spinnerTrack = Color(white: 0.56, opacity: 0.28)
    /// The active stroke of a spinner or progress indicator; shares `muted` so it reads as
    /// secondary UI, not an alert.
    public static let spinner = muted
    /// Marks a completed task or step; shares the accent family since completion is a positive,
    /// current-state signal.
    public static let done = accent
}

/// Whether an appearance asks for Increase Contrast, which `Palette`'s inks and hairlines answer
/// with their stronger value. AppKit says so through `bestMatch(from:)`; it will not build an
/// accessibility appearance by name (`NSAppearance(named: .accessibilityHighContrastDarkAqua)` is
/// plain `.darkAqua`), so a test resolves the high-contrast value by setting `forced` around the read.
enum IncreaseContrast {
    @TaskLocal static var forced: Bool?

    static func isOn(in appearance: NSAppearance) -> Bool {
        forced ?? (appearance.bestMatch(from: [.darkAqua, .accessibilityHighContrastDarkAqua]) == .accessibilityHighContrastDarkAqua)
    }
}

/// A vendor's single-colour mark: its colour, its path, and what to draw if the path will not
/// decode.
///
/// The marks are SVG documents built at runtime, so `Icon` wants the colour as text while SwiftUI
/// wants a `Color`. Deriving both from one number is what stops them drifting — `#2684FF` used to be
/// written twice, once as `Palette.jira` and once as a literal in `JiraChip`.
public struct Brand: Sendable, Hashable {
    /// What the brand is called, and the whole of its identity: two brands are equal when their names
    /// are, so an image cache keys on a few characters, not on the path's kilobytes.
    public let name: String
    public let color: Color
    /// `color` as `#RRGGBB`, for the SVG fill. Internal: only `Icon` builds the document.
    let hex: String
    /// The vendor mark as an SVG path string in a 24 × 24 viewBox. `NSImage(data:)` rasterises SVG
    /// on macOS, so the mark is path data rather than a hand-ported `Path`.
    public let path: String
    /// Drawn instead when the SVG will not decode, so a mark never silently vanishes.
    public let fallbackSymbol: String

    /// The brand's colour as a faint wash, behind a label in the brand's own ink: a ticket's or a
    /// merge request's lane in a picker — neutral information in the vendor's colour, not a warning.
    public var wash: Color { color.opacity(0.18) }

    public static func == (lhs: Brand, rhs: Brand) -> Bool { lhs.name == rhs.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }

    public init(_ name: String, _ value: UInt32, path: String, fallbackSymbol: String) {
        self.name = name
        color = Palette.hex(value)
        hex = String(format: "#%06X", value)
        self.path = path
        self.fallbackSymbol = fallbackSymbol
    }
}
