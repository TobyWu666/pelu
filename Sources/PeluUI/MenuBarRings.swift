#if os(macOS)
import AppKit
import PeluCore
import SwiftUI

/// Menu bar glyph: one ring per provider. The outer ring is quota used
/// (status colour), the inner ring is how far the window has run (sky, as in
/// the panel), and the provider letter sits in the middle. Drawn lazily so
/// `labelColor` follows the menu bar appearance.
public enum MenuBarRings {
    public struct Item: Equatable, Sendable {
        public let letter: String
        public let percent: Double?
        public let elapsed: Double?
        public let status: UsageStatus

        public init(metric: UsageMetric, now: Date = Date()) {
            letter = metric.provider.menuBarLetter
            percent = metric.usedPercent
            elapsed = metric.primaryWindowElapsed(at: now)
            status = metric.usedPercent == nil ? .unknown : UsageStatus.from(percent: metric.usedPercent)
        }
    }

    static let height: CGFloat = 18
    static let ringDiameter: CGFloat = 18
    static let gap: CGFloat = 4
    static let lineWidth: CGFloat = 2
    static let ringSpacing: CGFloat = 1

    /// Panel sky on dark bars; a deeper blue on light bars, where the panel
    /// tone washes out at this size.
    static let elapsedColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(PeluTheme.sky)
            : NSColor(red: 34 / 255, green: 116 / 255, blue: 230 / 255, alpha: 1)
    }

    public static func image(items: [Item]) -> NSImage {
        let width = CGFloat(items.count) * ringDiameter + CGFloat(max(0, items.count - 1)) * gap
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            for (index, item) in items.enumerated() {
                let x = CGFloat(index) * (gap + ringDiameter)
                draw(item, in: NSRect(x: x, y: (height - ringDiameter) / 2, width: ringDiameter, height: ringDiameter))
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Pelu " + items.map { "\($0.letter) \(PercentFormatter.string(from: $0.percent))" }.joined(separator: "，")
        return image
    }

    private static func draw(_ item: Item, in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let track = NSColor.labelColor.withAlphaComponent(0.16)

        let outerRadius = rect.width / 2 - lineWidth / 2
        ring(center: center, radius: outerRadius, fraction: 1, color: track)
        if let percent = item.percent, percent.isFinite {
            ring(center: center, radius: outerRadius,
                 fraction: min(1, max(0, percent / 100)), color: NSColor(item.status.tintColor))
        }

        let innerRadius = outerRadius - lineWidth - ringSpacing
        ring(center: center, radius: innerRadius, fraction: 1, color: track)
        if let elapsed = item.elapsed {
            ring(center: center, radius: innerRadius, fraction: elapsed, color: elapsedColor)
        }

        let text = NSAttributedString(string: item.letter, attributes: [
            .font: NSFont.systemFont(ofSize: 7, weight: .heavy),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(item.percent == nil ? 0.45 : 1),
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    private static func ring(center: NSPoint, radius: CGFloat, fraction: Double, color: NSColor) {
        guard fraction > 0 else { return }
        let path = NSBezierPath()
        if fraction >= 1 {
            path.appendOval(in: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        } else {
            path.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
            path.lineCapStyle = .round
        }
        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()
    }
}
#endif
