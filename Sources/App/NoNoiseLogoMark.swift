import SwiftUI
import AppKit

enum NoNoiseLogoImage {
    static func menuBar(isActive: Bool) -> NSImage {
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
    var body: some View {
        Group {
            if let path = Bundle.main.path(forResource: "NoNoiseMacLogo", ofType: "png"),
               let nsImage = NSImage(contentsOfFile: path) {
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
