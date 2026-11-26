import SwiftUI
import AppKit

/// The real vendor marks from the design canvas, as SVG. `NSImage(data:)` rasterises SVG on
/// macOS 13 and later, so the same path data the canvas uses can be drawn here without hand-porting
/// it to `Path` — and if a future system ever stops loading it, `Icon` falls back rather than
/// drawing nothing. Internal: nothing outside this module reads these — a mark is drawn with
/// `Icon(.brand(…))`, or `Icon(.gitlabTanuki)` and `Icon(.piBadge)` for the full-colour ones.
enum Logos {
    /// Pi's badge: three white blocks, for the black disc `VendorMark` sets it on.
    static let piBadgeSVG = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 560 560"><path fill="#FFFFFF" d="M420 280H280V140H0V0H420V280Z"/><path fill="#FFFFFF" d="M560 560H420V280H560V560Z"/><path fill="#FFFFFF" d="M140 560H0V140H140V280H280V420H140V560Z"/></svg>"##
    /// Google's full-colour Antigravity logo, as Google publishes it: a gradient arch of blurred colour
    /// fields under a mask, drawn for a light ground.
    static let antigravitySVG = ##"<svg width="180" height="180" viewBox="0 0 180 180" fill="none" xmlns="http://www.w3.org/2000/svg"> <path d="M144.248 149.062C151.748 154.688 162.998 150.938 152.685 140.625C121.748 110.625 128.31 28.125 89.8727 28.125C51.4352 28.125 57.9977 110.625 27.0602 140.625C15.8102 151.875 27.9977 154.688 35.4977 149.062C64.5602 129.375 62.6852 94.6875 89.8727 94.6875C117.06 94.6875 115.185 129.375 144.248 149.062Z" fill="#3186FF"/> <mask id="mask0_6001_409" style="mask-type:alpha" maskUnits="userSpaceOnUse" x="22" y="28" width="136" height="125"> <path d="M144.248 149.062C151.748 154.688 162.998 150.938 152.685 140.625C121.748 110.625 128.31 28.125 89.8727 28.125C51.4352 28.125 57.9977 110.625 27.0602 140.625C15.8102 151.875 27.9977 154.688 35.4977 149.062C64.5602 129.375 62.6852 94.6875 89.8727 94.6875C117.06 94.6875 115.185 129.375 144.248 149.062Z" fill="white"/> </mask> <g mask="url(#mask0_6001_409)"> <g filter="url(#filter0_f_6001_409)"> <ellipse cx="36.6225" cy="43.0872" rx="36.6225" ry="43.0872" transform="matrix(-0.112784 0.99362 -0.99362 -0.112781 106.557 -26.4847)" fill="#FFE432"/> </g> <g filter="url(#filter1_f_6001_409)"> <ellipse cx="155.163" cy="54.9292" rx="47.4118" ry="48.4541" transform="rotate(76.9243 155.163 54.9292)" fill="#FC413D"/> </g> <g filter="url(#filter2_f_6001_409)"> <ellipse cx="14.6006" cy="65.4425" rx="49.5515" ry="64.192" transform="rotate(74.1257 14.6006 65.4425)" fill="#00B95C"/> </g> <g filter="url(#filter3_f_6001_409)"> <ellipse cx="14.6006" cy="65.4425" rx="49.5515" ry="64.192" transform="rotate(74.1257 14.6006 65.4425)" fill="#00B95C"/> </g> <g filter="url(#filter4_f_6001_409)"> <ellipse cx="18.1226" cy="67.414" rx="48.5679" ry="53.4688" transform="rotate(45.6065 18.1226 67.414)" fill="#00B95C"/> </g> <g filter="url(#filter5_f_6001_409)"> <ellipse cx="121.837" cy="166.945" rx="46.6356" ry="44.9084" transform="rotate(76.9243 121.837 166.945)" fill="#3186FF"/> </g> <g filter="url(#filter6_f_6001_409)"> <ellipse cx="53.9456" cy="56.8997" rx="53.9456" ry="56.8997" transform="matrix(-0.409539 0.912293 -0.912294 -0.409537 162.811 -25.895)" fill="#FBBC04"/> </g> <g filter="url(#filter7_f_6001_409)"> <path d="M4.21557 239.063C-25.3231 227.467 25.1577 132.061 37.7105 100.085C50.2634 68.1097 84.3853 51.5888 113.924 63.1848C143.463 74.7809 178.474 138.65 165.921 170.626C153.368 202.601 33.7543 250.659 4.21557 239.063Z" fill="#3186FF"/> </g> <g filter="url(#filter8_f_6001_409)"> <path d="M183.197 120.315C175.289 129.545 154.652 124.839 137.102 109.803C119.553 94.7668 111.738 75.0955 119.646 65.8656C127.554 56.6357 148.191 61.3423 165.74 76.3782C183.289 91.414 191.105 111.085 183.197 120.315Z" fill="#749BFF"/> </g> <g filter="url(#filter9_f_6001_409)"> <ellipse cx="148.928" cy="36.7252" rx="71.1018" ry="44.199" transform="rotate(34.0763 148.928 36.7252)" fill="#FC413D"/> </g> <g filter="url(#filter10_f_6001_409)"> <ellipse cx="37.848" cy="46.0346" rx="38.1008" ry="22.1575" transform="rotate(112.516 37.848 46.0346)" fill="#FFEE48"/> </g> </g> <defs> <filter id="filter0_f_6001_409" x="4.09591" y="-44.1761" width="111.037" height="98.4416" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB"> <feGaussianBlur stdDeviation="6.25234"/> </filter> <filter id="filter1_f_6001_409" x="46.2974" y="-53.0009" width="217.731" height="215.86" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB"> <feGaussianBlur stdDeviation="30.2268"/> </filter> <filter id="filter2_f_6001_409" x="-100.018" y="-36.7558" width="229.238" height="204.397" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB"> <feGaussianBlur stdDeviation="25.6957"/> </filter> <filter id="filter3_f_6001_409" x="-100.018" y="-36.7558" width="229.238" height="204.397" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB"> <feGaussianBlur stdDeviation="25.6957"/> </filter> <filter id="filter4_f_6001_409" x="-84.3985" y="-35.003" width="205.042" height="204.834" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB"> <feGaussianBlur stdDeviation="25.6957"/> </filter> <filter id="filter5_f_6001_409" x="27.9915" y="71.5493" width="187.691" height="190.791" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB"> <feGaussianBlur stdDeviation="24.4184"/> </filter> <filter id="filter6_f_6001_409" x="-11.8808" y="-98.7085" width="201.38" height="197.45" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB"> <feGaussianBlur stdDeviation="22.1301"/> </filter> <filter id="filter7_f_6001_409" x="-44.4432" y="19.9522" width="252.513" height="260.404" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB"> <feGaussianBlur stdDeviation="19.7631"/> </filter> <filter id="filter8_f_6001_409" x="81.1915" y="25.7722" width="140.46" height="134.637" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB"> <feGaussianBlur stdDeviation="17.6843"/> </filter> <filter id="filter9_f_6001_409" x="55.1499" y="-47.2531" width="187.555" height="167.957" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB"> <feGaussianBlur stdDeviation="14.9365"/> </filter> <filter id="filter10_f_6001_409" x="-24.2633" y="-27.1515" width="124.223" height="146.372" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB"> <feGaussianBlur stdDeviation="18.4865"/> </filter> </defs> </svg>"##

    static let claudePath = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"

    static let openaiPath = "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"

    static let jiraPath = "M11.571 11.513H0a5.218 5.218 0 0 0 5.232 5.215h2.13v2.057A5.215 5.215 0 0 0 12.575 24V12.518a1.005 1.005 0 0 0-1.005-1.005zm5.723-5.756H5.736a5.215 5.215 0 0 0 5.215 5.214h2.129v2.058a5.218 5.218 0 0 0 5.215 5.214V6.758a1.001 1.001 0 0 0-1.001-1.001zM23.013 0H11.455a5.215 5.215 0 0 0 5.215 5.215h2.129v2.057A5.215 5.215 0 0 0 24 12.483V1.005A1.001 1.001 0 0 0 23.013 0Z"

    static let gitlabPath = "m23.6004 9.5927-.0337-.0862L20.3.9814a.851.851 0 0 0-.3362-.405.8748.8748 0 0 0-.9997.0539.8748.8748 0 0 0-.29.4399l-2.2055 6.748H7.5375l-2.2057-6.748a.8573.8573 0 0 0-.29-.4412.8748.8748 0 0 0-.9997-.0537.8585.8585 0 0 0-.3362.4049L.4332 9.5015l-.0325.0862a6.0657 6.0657 0 0 0 2.0119 7.0105l.0113.0087.03.0213 4.976 3.7264 2.462 1.8633 1.4995 1.1321a1.0085 1.0085 0 0 0 1.2197 0l1.4995-1.1321 2.4619-1.8633 5.006-3.7489.0125-.01a6.0682 6.0682 0 0 0 2.0094-7.003z"

    /// Simple Icons "GitHub" (v16.31.0, CC0): the Invertocat, single colour.
    static let githubPath = "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"

    /// Simple Icons "Visual Studio Code" (v16.31.0, CC0), same path the design canvas inlines.
    static let vscodePath = "M23.15 2.587L18.21.21a1.494 1.494 0 0 0-1.705.29l-9.46 8.63-4.12-3.128a.999.999 0 0 0-1.276.057L.327 7.261A1 1 0 0 0 .326 8.74L3.899 12 .326 15.26a1 1 0 0 0 .001 1.479L1.65 17.94a.999.999 0 0 0 1.276.057l4.12-3.128 9.46 8.63a1.492 1.492 0 0 0 1.704.29l4.942-2.377A1.5 1.5 0 0 0 24 20.06V3.939a1.5 1.5 0 0 0-.85-1.352zm-5.146 14.861L10.826 12l7.178-5.448v10.896z"

    /// The four-colour tanuki as drawn on the design canvas (decision "GitLab B", 17 Sep 2026).
    static let gitlabFourColourSVG = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#E24329" d="M12 23.6 7.6 10h8.8z"/><path fill="#FC6D26" d="M12 23.6 2 10h5.6zM12 23.6 22 10h-5.6z"/><path fill="#FCA326" d="M2 10 .6 14.2c-.1.4 0 .9.4 1.1L12 23.6zM22 10l1.4 4.2c.1.4 0 .9-.4 1.1L12 23.6z"/><path fill="#E24329" d="M2 10 4.6 1.9c.1-.4.7-.4.9 0L7.6 10zM22 10 19.4 1.9c-.1-.4-.7-.4-.9 0L16.4 10z"/></svg>"##

    /// A brand's mark is cached under its name and fill, since a body asks for its mark each time
    /// it runs and hashing a path of kilobytes is what a path key would cost every time. The entry
    /// keeps the path it was drawn from, and a hit counts only for that path: two brands given one
    /// name by mistake are drawn apart, at the cost of a string comparison that is a pointer check
    /// for the same brand — `Palette`'s paths are literals, one buffer however often read.
    private struct BrandKey: Hashable { let name: String, fill: String }

    /// Main-actor state: every reader is a view's `body`.
    @MainActor private static var brands: [BrandKey: (path: String, image: NSImage)] = [:]
    @MainActor private static var documents: [String: (svg: String, image: NSImage)] = [:]

    /// A single-colour mark — the brand's path in a 24 × 24 viewBox, filled with `fill` —
    /// rasterised once per brand and fill.
    @MainActor static func image(brand: Brand, fill: String) -> NSImage? {
        let key = BrandKey(name: brand.name, fill: fill)
        if let hit = brands[key], hit.path == brand.path { return hit.image }
        guard let image = rasterise(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="\#(fill)" d="\#(brand.path)"/></svg>"#) else {
            return nil
        }
        brands[key] = (brand.path, image)
        return image
    }

    /// Any small SVG document, rasterised once.
    @MainActor static func image(name: String, svg: String) -> NSImage? {
        if let hit = documents[name], hit.svg == svg { return hit.image }
        guard let image = rasterise(svg) else { return nil }
        documents[name] = (svg, image)
        return image
    }

    private static func rasterise(_ svg: String) -> NSImage? {
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.isTemplate = false
        return image
    }
}

/// A single-colour vendor logo at a given size, with an SF Symbol stand-in if SVG ever fails to
/// load. Internal: `Icon(.brand(…))` is how anything draws one, so the fill never travels as text
/// outside this module.
struct LogoGlyph: View {
    let brand: Brand, fill: String, size: CGFloat

    var body: some View {
        if let image = Logos.image(brand: brand, fill: fill) {
            // Decorative: whatever carries the mark — a badge, a row — says what it is.
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: brand.fallbackSymbol).font(.system(size: size * 0.9, weight: .bold))
                .accessibilityHidden(true)
        }
    }
}
