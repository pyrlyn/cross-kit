import SwiftUI
import AppKit
import CrossKitCore

/// A macOS-style document icon: white page with a folded top-right corner, a coloured language band
/// and a badge (see `FileIconStyle`). Used in the file lists of the Test Results, Run, Debugger, Preview
/// and Coverage windows and in Settings.
struct FileIconView: View {
    let style: FileIconStyle
    var size: CGFloat = 16

    init(style: FileIconStyle, size: CGFloat = 16) {
        self.style = style
        self.size = size
    }

    init(path: String, size: CGFloat = 16) {
        self.init(style: FileIconStyle.forFile(path), size: size)
    }

    init(language: Language, size: CGFloat = 16) {
        self.init(style: FileIconStyle.forLanguage(language), size: size)
    }

    var body: some View {
        Canvas { context, canvasSize in
            FileIconRenderer.draw(style, in: &context, size: canvasSize)
        }
        .frame(width: size * 0.78, height: size)
        .accessibilityLabel(Text("\(style.badge) file"))
    }
}

enum FileIconRenderer {
    static func color(_ rgb: UInt32) -> Color {
        let c = FileIconStyle.components(rgb)
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    static func draw(_ style: FileIconStyle, in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let fold = w * 0.3
        let radius = w * 0.08
        var page = Path()
        page.move(to: CGPoint(x: radius, y: 0))
        page.addLine(to: CGPoint(x: w - fold, y: 0))
        page.addLine(to: CGPoint(x: w, y: fold))
        page.addLine(to: CGPoint(x: w, y: h - radius))
        page.addQuadCurve(to: CGPoint(x: w - radius, y: h), control: CGPoint(x: w, y: h))
        page.addLine(to: CGPoint(x: radius, y: h))
        page.addQuadCurve(to: CGPoint(x: 0, y: h - radius), control: CGPoint(x: 0, y: h))
        page.addLine(to: CGPoint(x: 0, y: radius))
        page.addQuadCurve(to: CGPoint(x: radius, y: 0), control: CGPoint(x: 0, y: 0))
        page.closeSubpath()

        context.fill(page, with: .linearGradient(Gradient(colors: [.white, Color(white: 0.93)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        // Language band across the lower half, clipped to the page.
        var band = context
        band.clip(to: page)
        let bandRect = CGRect(x: 0, y: h * 0.52, width: w, height: h * 0.34)
        band.fill(Path(bandRect), with: .linearGradient(Gradient(colors: [color(style.color), color(style.secondaryColor)]),
                                                         startPoint: CGPoint(x: 0, y: bandRect.minY),
                                                         endPoint: CGPoint(x: 0, y: bandRect.maxY)))
        // A few "text lines" above the band, like Finder's document icons.
        if h >= 24 {
            for i in 0..<3 {
                let y = h * (0.2 + Double(i) * 0.09)
                let lineWidth = (i == 0 ? w - fold - w * 0.22 : w * 0.64)
                band.fill(Path(CGRect(x: w * 0.16, y: y, width: lineWidth, height: max(h * 0.025, 0.6))),
                          with: .color(Color(white: 0.78)))
            }
        }
        context.stroke(page, with: .color(Color(white: 0.55)), lineWidth: max(w * 0.035, 0.5))
        // The folded corner.
        var corner = Path()
        corner.move(to: CGPoint(x: w - fold, y: 0))
        corner.addLine(to: CGPoint(x: w - fold, y: fold - radius))
        corner.addQuadCurve(to: CGPoint(x: w - fold + radius, y: fold), control: CGPoint(x: w - fold, y: fold))
        corner.addLine(to: CGPoint(x: w, y: fold))
        corner.closeSubpath()
        context.fill(corner, with: .linearGradient(Gradient(colors: [Color(white: 0.98), Color(white: 0.8)]),
                                                   startPoint: CGPoint(x: w - fold, y: 0), endPoint: CGPoint(x: w, y: fold)))
        context.stroke(corner, with: .color(Color(white: 0.55)), lineWidth: max(w * 0.03, 0.4))
        // Badge text, scaled to fit the band.
        guard !style.badge.isEmpty else { return }
        let maxFont = bandRect.height * 0.78
        let fitted = min(maxFont, w * 1.5 / CGFloat(max(style.badge.count, 1)))
        let text = Text(style.badge)
            .font(.system(size: max(fitted, 3), weight: .heavy, design: .rounded))
            .foregroundColor(color(style.textColor))
        band.draw(text, at: CGPoint(x: w / 2, y: bandRect.midY), anchor: .center)
    }

    /// The icon as an image (for menus, `NSImage`-based views and the Dock).
    @MainActor
    static func image(_ style: FileIconStyle, size: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: FileIconView(style: style, size: size))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}
