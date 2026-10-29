# AiTerm UI

The design system is Swift. `Palette.swift` and `Metrics.swift` define its values; this file defines
the rules for using them. [The HTML reference](../../../docs/design/design-system.html) mirrors the
code for humans. [App patterns](../../../docs/design/ui-patterns.md) describe feature composition.

## Boundaries and reuse

`AiTermUI` imports neither `AiTermCore` nor `AiTerm`. Its primitives use standard names and carry no
AiTerm domain types in their signatures. Product patterns live in `AiTerm/Views`, where both Core
and UI are available. App-shell composition stays there even if reused: sheet anatomy and snapshot
switches are product decisions, not primitives.

Before adding a control, use the first suitable option:

1. Add a variant/content case to an existing primitive.
2. Arrange existing primitives into an app pattern.
3. Add a primitive only for a reusable, domain-independent part. Declare its variant/state matrix,
   add it to this inventory and test it in `AiTermUITests`. Public structs need an explicit public
   initializer; Swift's memberwise initializer is internal.

## Colour

Every colour comes from `Palette`. Views never write literal colours or derive a token using
`.opacity(...)`: name the derived colour in `Palette`, even for one caller. `Brand.wash` is the one
shared vendor derivation. Use `onAccent`/the surface's ink for accent content, `markPaper`/`markInk`
for vendor artwork, and `Icon` for marks. GitHub is white on dark ground and tinted `markInk` on
its `markPaper` integration disc. Vendor colours identify vendors, not general status or controls.

Distinctly written Palette tokens must resolve differently. When roles deliberately share a value,
declare an alias (`sidebar = surface`). `PaletteDistinctionTests` checks the source aliases and
rendered colours, including washes against their grounds. Add derived tokens to its manifest.

A component reads `@Environment(\.surface)` for the ground beneath it, rather than taking a
`selected` flag to derive colours. `Surface.sidebar`, `.hover`, `.washed`, `.washedHover`, `.accent`
and `.sheet` supply ink, secondary ink, badge washes and occluding background. The container drawing
the ground declares it: `RowPill`, `menuRowHighlight`, or `SegmentedControl`. The label does not
repeat the selection decision.

AiTerm is dark-only. AppKit/SwiftUI hosts, sheets and alerts inherit the same dark appearance.

## Measurements

Every height, width, radius, spacing and text size comes from `Metrics`: `Space`, `Radius`, `Size`,
`Typography`, `Sheet` and `Opacity`. Zero is allowed directly. System text styles, AppKit control
sizes and AppKit corner radii supply the native scales; Space supplies the house rhythm. Equal
numbers across measurement roles are fine: their names let those roles change independently.

`Opacity.disabled` is the shared disabled fade. Apply it to the part actually disabled: a rejected
segment, the Oracle-off goal editor/rounds field (not their labels/help), or the entire switched-off
Oracle group as its pattern specifies.

If no token fits, add a documented member explaining its role and mention it in the change summary.
Do not choose an arbitrary nearby number. Truly local geometry may be a documented private static
constant describing what that component measures and why no token fits. When another file needs
the same measurement for the same reason, promote it to Metrics. Kerning and one-element optical
shadows (including their black/blur/offset/opacity) remain local optical corrections.

`DesignRulesTests` enforces the target boundary and rejects raw colours, derived Palette opacity,
raw system font sizes and numeric padding/spacing/radius/offset/frame values in UI and app views.
The snapshot renderer is exempt; other narrowly documented exceptions remain explicit in the test.

## Scaling

Metrics values are ×1. `InterfaceScale` offers standard ×1, large ×1.15 and extra large ×1.3.
Only the sidebar scales; `SidebarSheet` resets to standard because native controls retain Apple's
sizes. Settings' `InterfaceSize` maps to this UI environment.

- `View.font(TypeStyle)` reads the environment and scales text without rounding.
- Read owned `Space`/`Radius`/`Size` values through `@Environment(\.interfaceScale) var scale`, then
  `scale(Space.base)`. Geometry rounds to whole points; standard is identity.
- A `size:` argument already means screen points. The caller scales its token; the callee does not
  scale that argument again. Components scale their own token reads.
- Borders, hairlines, outline rings and focus rings do not scale. A mark's proportional ring stroke
  scales with its diameter. `Select` remains a native unscaled bezel.
- A sheet-only primitive moved to the sidebar must first scale its own tokens.

Round status marks are rings, never discs: stroke width is 15% of their size, kept inside the box
using `strokeBorder` or a half-stroke inset. `UsageRing` and `ToneRing` follow the same recipe.
`StatusMark` draws idle, working arc/track, amber input, done and an eight-dash background-work ring
rotating once per six seconds. Accent-ground marks use the surface's accent ink. Reduce Motion
keeps the shapes and removes rotation.

## Interaction and accessibility

Specify default, hover, pressed, disabled, focus and selected states together. If a target does not
exist, omit its control rather than disabling it. Use native semantics and meaningful accessibility
labels/actions; an icon-only count needs words. Plain Return belongs to the focused field/list;
⌘Return invokes a sheet's primary action and Escape closes an open popup before backing out.
[Keyboard rules](../../../docs/keyboard.md) cover the product wiring.

The sidebar keeps an empty titlebar band in `Palette.sidebar` at AppKit's native titlebar height,
independent of sidebar zoom. Clip scrolling content below it so pills/marks cannot reach the
traffic-light controls. Focus/selection and surface declaration must work while the app is inactive.

## Primitive inventory

| Type | Responsibility |
| --- | --- |
| `Badge` | Shared chip, quiet style, icon/diff/suffix/count variants, action/menu and accessibility label. |
| `Icon` / `IconSource` | SF Symbol, branded glyph or full-colour artwork with a fallback; caller supplies size. |
| `FormField` | Label/control stack with dropdown overhang above following content. |
| `FrontToBackStack` | Earlier children draw above later ones, including nested overhangs. |
| `HelpText` | Secondary or warning caption; choose tone rather than overriding its foreground. |
| `Input` | Native plain/secure text field in shared chrome; optional caret-at-end on focus. |
| `SearchField` | Native single-line field that delegates navigation to an open popup first. |
| `Select` | Native full-column popup button. |
| `SegmentedControl` | Neutral/focus or accent styles, selectable predicate, labels inked for their grounds. |
| `Kbd` | Shortcut keycaps using the current surface's ink/wash. |
| `SidebarHeading` | Micro uppercase tracked heading. |
| `SymbolMark` | SF Symbol on the standard paper/ink disc. |
| `Hairline` | Shared unscaled border/separator; use instead of a bare Divider. |

Foundations are `Palette`/`Brand`, Metrics and `TypeStyle`, `Surface`, `InterfaceScale`, `IconSource`
and `ControlChrome` modifiers: `focusRing`, `fieldChrome`, `fieldBox`, `menuChrome`,
`menuRowHighlight`, `groupChrome`. They are rules/data rather than component cards. `Logos`,
`LogoGlyph` and text-editing coordinators remain implementation details.

## Human reference and proposals

The [design-system skill](../../../.agents/skills/design-system/SKILL.md) syncs the single HTML
page's Foundations and Components from Swift and publishes the existing artifact. Never use the
page to change a token or invent an absent type.

Proposals stays present and contains only unimplemented visual options, drawn from the current
tokens (or explicitly proposed new ones). Publish the options and wait for a choice before changing
the affected Swift. After implementation, remove only that proposal and sync the shipped reference.
An empty Proposals tab retains its intro and “No open proposals.” This structural refactor selects
no visual change.
