import SwiftUI
import AppKit

enum NoNoiseLogoImage {
    // The status icon is byte-identical regardless of AI state — the drawing fills with
    // `NSColor.labelColor` unconditionally and never branches on `isActive`. So the offscreen
    // `lockFocus` render is run exactly once and cached; re-rendering it on every MenuBarExtra
    // Scene re-evaluation (25×/sec while telemetry stormed) was pure main-thread waste that
    // slowed popover presentation. If the icon is ever made to reflect AI on/off, swap this for
    // two cached variants keyed on `isActive`.
    private static let cachedBar: NSImage = renderBar()

    static func menuBar(isActive: Bool) -> NSImage { cachedBar }

    private static func renderBar() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let barColor = NSColor.labelColor
        barColor.setFill()

        let bars: [(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)] = [
            (1.5, 5.6, 2.2, 6.8),
            (5.0, 3.2, 3.0, 11.6),
            (8.2, 1.8, 2.8, 14.4),
            (11.2, 3.2, 3.0, 11.6),
            (14.3, 5.6, 2.2, 6.8)
        ]

        for bar in bars {
            let rect = NSRect(x: bar.x, y: bar.y, width: bar.width, height: bar.height)
            NSBezierPath(roundedRect: rect, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

struct NoNoiseLogoMark: View {
    var isActive: Bool = true

    private var centerColor: Color {
        return isActive ? Color(red: 0.94, green: 0.28, blue: 0.09) : .secondary
    }

    private var sideColor: Color {
        return isActive ? Color(red: 0.05, green: 0.25, blue: 0.16) : .secondary
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let centerWidth = width * 0.16
            let innerWidth = width * 0.18
            let outerWidth = width * 0.11

            ZStack {
                Capsule()
                    .fill(sideColor)
                    .frame(width: outerWidth, height: height * 0.38)
                    .offset(x: -width * 0.42)

                Capsule()
                    .fill(sideColor)
                    .frame(width: innerWidth, height: height * 0.66)
                    .offset(x: -width * 0.22)

                Capsule()
                    .fill(centerColor)
                    .frame(width: centerWidth, height: height * 0.82)

                Capsule()
                    .fill(sideColor)
                    .frame(width: innerWidth, height: height * 0.66)
                    .offset(x: width * 0.22)

                Capsule()
                    .fill(sideColor)
                    .frame(width: outerWidth, height: height * 0.38)
                    .offset(x: width * 0.42)
            }
            .frame(width: width, height: height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct NoNoiseLogoAsset: View {
    // Load + decode the header PNG from the bundle exactly once. Reading the file inside `body`
    // re-decoded it on every ContentView recompute (25×/sec while the popover was open, driven by
    // the telemetry storm) — see the menu-bar perf plan. `nil` when the resource is missing, which
    // falls back to the vector mark below.
    private static let cachedLogo: NSImage? = {
        guard let path = Bundle.main.path(forResource: "NoNoiseMacLogo", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }()

    var body: some View {
        Group {
            if let nsImage = Self.cachedLogo {
                Image(nsImage: nsImage)
                    .resizable()
            } else {
                NoNoiseLogoMark()
            }
        }
        .aspectRatio(contentMode: .fit)
        .accessibilityHidden(true)
    }
}
