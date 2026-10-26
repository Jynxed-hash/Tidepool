import AppKit
import ProviderKit
import SwiftUI

struct MenuBarLabel: View {
    var store: TidepoolStore

    var body: some View {
        let needsYou = store.snapshot.needsAttention
        let image = MenuBarArtwork.image(
            usedPercent: store.menuBarUsedPercent,
            percent: store.menuPercent,
            needsYou: needsYou
        )
        Image(nsImage: image)
            .renderingMode(.template)
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["Tidepool"]
        if let percent = store.menuPercent {
            parts.append(percent)
        }
        if store.snapshot.needsAttention {
            parts.append("Needs you")
        }
        return parts.joined(separator: ", ")
    }
}

/// Allowance mark from the 18×18 SVG. Coordinates below are that viewBox.
/// Bars are left-aligned capsules. Needs-you lengthens only the top bar to the track.
enum AllowanceMark {
    static let canvas: CGFloat = 18
    static let originX: CGFloat = 2
    static let barHeight: CGFloat = 3
    static let cornerRadius: CGFloat = 1.5
    /// Full top bar in the needs-you SVG: x=2, width=14, so the right margin matches the left.
    static let track: CGFloat = 14
    /// A capsule this short is a circle. Shorter than the height and the corner radius overflows.
    static let minimumWidth: CGFloat = 3
    /// Static mark: `option1.svg` widths, top to bottom.
    static let staticWidths: [CGFloat] = [10.5, 8, 5]
    /// SVG `y` of each bar, top to bottom.
    static let svgOrigins: [CGFloat] = [3, 7.5, 12]

    /// Widths top to bottom. `usedPercent` is the 5-hour window already used (0–100).
    /// Remaining length scales the static step-down. 25% used is the static mark
    /// (top bar 10.5, which is 75% of the 14pt track). Missing data keeps that mark.
    static func widths(usedPercent: Double?, needsYou: Bool) -> [CGFloat] {
        let base: [CGFloat]
        if let usedPercent, usedPercent.isFinite {
            let used = min(100, max(0, usedPercent))
            let remaining = 1 - (used / 100)
            let top = min(track, max(minimumWidth, track * remaining))
            let mid = min(top, max(minimumWidth, top * staticWidths[1] / staticWidths[0]))
            let bottom = min(mid, max(minimumWidth, top * staticWidths[2] / staticWidths[0]))
            base = [top, mid, bottom]
        } else {
            base = staticWidths
        }
        guard needsYou else { return base }
        return [track, base[1], base[2]]
    }

    /// AppKit rects in an 18×18 image whose origin is the bottom left.
    static func bars(usedPercent: Double?, needsYou: Bool) -> [CGRect] {
        zip(widths(usedPercent: usedPercent, needsYou: needsYou), svgOrigins).map { width, svgY in
            CGRect(
                x: originX,
                y: canvas - svgY - barHeight,
                width: width,
                height: barHeight
            )
        }
    }
}

enum MenuBarArtwork {
    static let symbolSide: CGFloat = 18
    static let textGap: CGFloat = 3
    static let percentFontSize: CGFloat = 12

    static func image(usedPercent: Double?, percent: String?, needsYou: Bool) -> NSImage {
        let text = percent ?? ""
        let font = NSFont.monospacedDigitSystemFont(ofSize: percentFontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let textWidth = text.isEmpty ? 0 : ceil(textSize.width)
        let gap: CGFloat = text.isEmpty ? 0 : textGap
        let size = NSSize(width: symbolSide + gap + textWidth, height: symbolSide)
        let canvas = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            for rect in AllowanceMark.bars(usedPercent: usedPercent, needsYou: needsYou) {
                NSBezierPath(
                    roundedRect: rect,
                    xRadius: AllowanceMark.cornerRadius,
                    yRadius: AllowanceMark.cornerRadius
                ).fill()
            }
            if !text.isEmpty {
                let y = (symbolSide - textSize.height) / 2
                (text as NSString).draw(at: NSPoint(x: symbolSide + gap, y: y), withAttributes: attributes)
            }
            return true
        }
        canvas.isTemplate = true
        return canvas
    }
}
