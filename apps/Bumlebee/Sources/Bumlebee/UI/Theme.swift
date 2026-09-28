import AppKit
import SwiftUI

/// Bumlebee's honey-and-ink look.
enum Theme {
    static let honey = Color(red: 0.98, green: 0.74, blue: 0.13)
    static let honeyLight = Color(red: 1.0, green: 0.86, blue: 0.42)
    static let honeyDeep = Color(red: 0.89, green: 0.55, blue: 0.05)
    static let ink = Color(red: 0.12, green: 0.10, blue: 0.06)
    static let inkSoft = Color(red: 0.20, green: 0.17, blue: 0.11)
    static let wax = Color(red: 1.0, green: 0.97, blue: 0.88)

    static let honeyGradient = LinearGradient(colors: [honeyLight, honey, honeyDeep], startPoint: .top, endPoint: .bottom)

    static let nsHoney = NSColor(red: 0.98, green: 0.74, blue: 0.13, alpha: 1)
    static let nsInk = NSColor(red: 0.12, green: 0.10, blue: 0.06, alpha: 1)
}

/// A pointy-top hexagon with softly rounded corners – one honeycomb cell.
struct Hexagon: Shape {
    var cornerRadius: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width / sqrt(3), rect.height / 2)
        let corners = (0..<6).map { index -> CGPoint in
            let angle = CGFloat(index) * .pi / 3 - .pi / 2
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        var path = Path()
        for index in 0..<6 {
            let previous = corners[(index + 5) % 6]
            let current = corners[index]
            let next = corners[(index + 1) % 6]
            let start = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            if index == 0 { path.move(to: start) }
            path.addArc(tangent1End: current, tangent2End: next, radius: cornerRadius)
        }
        path.closeSubpath()
        return path
    }
}

/// The Bumlebee mark: a honeycomb cell with a striped bee body.
struct BeeMark: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Hexagon(cornerRadius: size * 0.12)
                .fill(Theme.honeyGradient)
            Hexagon(cornerRadius: size * 0.12)
                .stroke(Theme.ink.opacity(0.85), lineWidth: max(1, size * 0.05))
            VStack(spacing: size * 0.07) {
                Capsule().fill(Theme.ink).frame(width: size * 0.5, height: size * 0.1)
                Capsule().fill(Theme.ink).frame(width: size * 0.58, height: size * 0.1)
                Capsule().fill(Theme.ink).frame(width: size * 0.42, height: size * 0.1)
            }
            .offset(y: size * 0.05)
            HStack(spacing: size * 0.18) {
                Ellipse().fill(Color.white.opacity(0.85)).frame(width: size * 0.2, height: size * 0.13).rotationEffect(.degrees(25))
                Ellipse().fill(Color.white.opacity(0.85)).frame(width: size * 0.2, height: size * 0.13).rotationEffect(.degrees(-25))
            }
            .offset(y: -size * 0.24)
        }
        .frame(width: size * sqrt(3) / 2 * 1.02, height: size)
    }
}

enum MenuBarIcon {
    /// A template hexagon with bee stripes for the status bar.
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 8
            let hexagon = NSBezierPath()
            for index in 0..<6 {
                let angle = CGFloat(index) * .pi / 3 + .pi / 2
                let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                index == 0 ? hexagon.move(to: point) : hexagon.line(to: point)
            }
            hexagon.close()
            hexagon.lineWidth = 1.6
            hexagon.lineJoinStyle = .round
            NSColor.black.setStroke()
            hexagon.stroke()
            NSColor.black.setFill()
            for (offset, width) in [(3.0, 7.0), (0.0, 8.0), (-3.0, 6.0)] {
                let stripe = NSBezierPath(roundedRect: NSRect(x: center.x - width / 2, y: center.y + offset - 0.9, width: width, height: 1.8), xRadius: 0.9, yRadius: 0.9)
                stripe.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
