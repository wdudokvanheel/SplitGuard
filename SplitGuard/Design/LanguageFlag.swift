import SwiftUI

// MARK: - Language Flag Artwork

/// Flat, brutalist-style flag drawn to fill whatever frame it is given.
struct LanguageFlag: View {
    let language: AppLanguage

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            switch language {
            case .english:
                drawUnionFlag(in: rect, context: &context)
            case .spanish:
                drawHorizontalBands(
                    [(FlagColor.red, 1), (FlagColor.yellow, 2), (FlagColor.red, 1)],
                    in: rect,
                    context: &context
                )
            case .french:
                drawVerticalBands(
                    [FlagColor.blue, FlagColor.white, FlagColor.red],
                    in: rect,
                    context: &context
                )
            case .german:
                drawHorizontalBands(
                    [(FlagColor.black, 1), (FlagColor.red, 1), (FlagColor.yellow, 1)],
                    in: rect,
                    context: &context
                )
            case .dutch:
                drawHorizontalBands(
                    [(FlagColor.red, 1), (FlagColor.white, 1), (FlagColor.blue, 1)],
                    in: rect,
                    context: &context
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func drawHorizontalBands(
        _ bands: [(Color, CGFloat)],
        in rect: CGRect,
        context: inout GraphicsContext
    ) {
        let total = bands.reduce(0) { $0 + $1.1 }
        var originY = rect.minY
        for (color, weight) in bands {
            let height = rect.height * weight / total
            context.fill(Path(CGRect(x: rect.minX, y: originY, width: rect.width, height: height)), with: .color(color))
            originY += height
        }
    }

    private func drawVerticalBands(
        _ bands: [Color],
        in rect: CGRect,
        context: inout GraphicsContext
    ) {
        let width = rect.width / CGFloat(bands.count)
        for (index, color) in bands.enumerated() {
            let originX = rect.minX + CGFloat(index) * width
            context.fill(Path(CGRect(x: originX, y: rect.minY, width: width, height: rect.height)), with: .color(color))
        }
    }

    private func drawUnionFlag(in rect: CGRect, context: inout GraphicsContext) {
        // Proportions follow the 60x30 construction sheet, scaled to the frame height.
        let unit = rect.height / 30
        context.fill(Path(rect), with: .color(FlagColor.blue))

        var diagonals = Path()
        diagonals.move(to: CGPoint(x: rect.minX, y: rect.minY))
        diagonals.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        diagonals.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        diagonals.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))

        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            layer.stroke(diagonals, with: .color(FlagColor.white), lineWidth: unit * 6)
            layer.stroke(diagonals, with: .color(FlagColor.red), lineWidth: unit * 2)
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let whiteCross = cross(center: center, thickness: unit * 10, in: rect)
        let redCross = cross(center: center, thickness: unit * 6, in: rect)
        context.fill(whiteCross, with: .color(FlagColor.white))
        context.fill(redCross, with: .color(FlagColor.red))
    }

    private func cross(center: CGPoint, thickness: CGFloat, in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(CGRect(x: rect.minX, y: center.y - thickness / 2, width: rect.width, height: thickness))
        path.addRect(CGRect(x: center.x - thickness / 2, y: rect.minY, width: thickness, height: rect.height))
        return path
    }
}

/// Flag colors tuned to the app's pop palette while staying recognizable.
private enum FlagColor {
    static let red = Color(red: 0xF0 / 255.0, green: 0x3A / 255.0, blue: 0x3A / 255.0)
    static let blue = Color(red: 0x24 / 255.0, green: 0x4C / 255.0, blue: 0xE0 / 255.0)
    static let yellow = SGColor.popYellow
    static let white = SGColor.pureWhite
    static let black = SGColor.pureBlack
}
