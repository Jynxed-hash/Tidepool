import AppKit
import ProviderKit
import SwiftUI

struct MenuBarLabel: View {
    var store: TidepoolStore

    var body: some View {
        let needsYou = store.snapshot.needsAttention
        let image = MenuBarArtwork.image(
            percent: store.menuPercent,
            reset: store.menuReset,
            needsYou: needsYou
        )
        Image(nsImage: image)
            .renderingMode(needsYou ? .original : .template)
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

enum MenuBarArtwork {
    static func image(percent: String?, reset: String?, needsYou: Bool) -> NSImage {
        let pieces = [percent, reset].compactMap { $0 }
        let text = pieces.joined(separator: " ")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let color: NSColor = needsYou ? .systemOrange : .black
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let symbolSide: CGFloat = 15
        let gap: CGFloat = text.isEmpty ? 0 : 4
        let width = symbolSide + gap + (text.isEmpty ? 0 : ceil(textSize.width))
        let height: CGFloat = 18
        let canvas = NSImage(size: NSSize(width: max(width, symbolSide), height: height), flipped: false) { _ in
            let symbolRect = NSRect(x: 0, y: (height - symbolSide) / 2, width: symbolSide, height: symbolSide)
            if let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)) {
                let drawn = needsYou ? tint(symbol, color: .systemOrange) : symbol
                drawn.draw(in: symbolRect)
            }
            if !text.isEmpty {
                let y = (height - textSize.height) / 2
                (text as NSString).draw(at: NSPoint(x: symbolSide + gap, y: y), withAttributes: attributes)
            }
            return true
        }
        canvas.isTemplate = !needsYou
        return canvas
    }

    private static func tint(_ image: NSImage, color: NSColor) -> NSImage {
        let copy = NSImage(size: image.size)
        copy.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }
}
