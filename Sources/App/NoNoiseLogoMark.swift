import SwiftUI

struct NoNoiseLogoMark: View {
    var isActive: Bool = true
    var isTemplate: Bool = false

    private var centerColor: Color {
        if isTemplate { return .primary }
        return isActive ? Color(red: 0.94, green: 0.28, blue: 0.09) : .secondary
    }

    private var sideColor: Color {
        if isTemplate { return .primary }
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
