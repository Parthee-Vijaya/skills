import AppKit
import SwiftUI

/// Sizes and hit-testing for the wheel, in the panel's top-left-origin coordinates.
enum WheelGeometry {
    static let windowSize = CGSize(width: 380, height: 420)
    static let center = CGPoint(x: 190, y: 190)
    static let discRadius: CGFloat = 170
    static let ringRadius: CGFloat = 113
    static let centerRadius: CGFloat = 48
    /// Dropping inside this radius cancels, so the file just springs back.
    static let deadZone: CGFloat = 60

    static func cellRadius(count: Int) -> CGFloat {
        count <= 6 ? 40 : count <= 8 ? 37 : 34
    }

    static func angle(of index: Int, count: Int) -> CGFloat {
        -.pi / 2 + CGFloat(index) * 2 * .pi / CGFloat(max(count, 1))
    }

    static func position(of index: Int, count: Int) -> CGPoint {
        let angle = Self.angle(of: index, count: count)
        return CGPoint(x: center.x + ringRadius * cos(angle), y: center.y + ringRadius * sin(angle))
    }

    static func distanceFromCenter(_ point: CGPoint) -> CGFloat {
        hypot(point.x - center.x, point.y - center.y)
    }

    static func isInCenter(_ point: CGPoint) -> Bool {
        distanceFromCenter(point) < deadZone
    }

    /// The cell whose angular sector contains `point`, so aiming is forgiving.
    static func index(at point: CGPoint, count: Int) -> Int? {
        let distance = distanceFromCenter(point)
        guard count > 0, distance >= deadZone, distance <= discRadius + 10 else { return nil }
        var angle = atan2(point.y - center.y, point.x - center.x) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        let step = 2 * .pi / CGFloat(count)
        return Int((angle / step).rounded()) % count
    }
}

final class WheelModel: ObservableObject {
    @Published var items: [WheelItem] = []
    @Published var mode: WheelMode = .convert
    @Published var highlighted: Int?
    @Published var thumbnail: NSImage?
    @Published var fileName = ""
    @Published var sizeText = ""
    @Published var count = 1
    @Published var appeared = false
    @Published var clickMode = false
    var urls: [URL] = []

    var highlightedItem: WheelItem? {
        guard let highlighted, items.indices.contains(highlighted) else { return nil }
        return items[highlighted]
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        ZStack {
            disc
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                WheelCell(item: item, isHighlighted: model.highlighted == index, radius: WheelGeometry.cellRadius(count: model.items.count))
                    .position(WheelGeometry.position(of: index, count: model.items.count))
            }
            WheelCenter(model: model)
                .position(WheelGeometry.center)
            Text(model.mode.title)
                .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                .tracking(2.5)
                .foregroundStyle(Theme.honey.opacity(0.85))
                .position(x: WheelGeometry.center.x, y: WheelGeometry.center.y + WheelGeometry.centerRadius + 12)
            caption
                .position(x: WheelGeometry.center.x, y: WheelGeometry.center.y + WheelGeometry.discRadius + 24)
        }
        .frame(width: WheelGeometry.windowSize.width, height: WheelGeometry.windowSize.height)
        .scaleEffect(model.appeared ? 1 : 0.55, anchor: UnitPoint(x: 0.5, y: WheelGeometry.center.y / WheelGeometry.windowSize.height))
        .opacity(model.appeared ? 1 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: model.appeared)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: model.highlighted)
        .animation(.easeInOut(duration: 0.18), value: model.mode)
    }

    private var disc: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.inkSoft, Theme.ink], center: .center, startRadius: 20, endRadius: WheelGeometry.discRadius))
                .opacity(0.94)
            Circle()
                .strokeBorder(Theme.honey.opacity(0.55), lineWidth: 1.5)
            Circle()
                .strokeBorder(Theme.honey.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                .padding(WheelGeometry.discRadius - WheelGeometry.ringRadius - 1)
        }
        .frame(width: WheelGeometry.discRadius * 2, height: WheelGeometry.discRadius * 2)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .position(WheelGeometry.center)
    }

    private var caption: some View {
        let item = model.highlightedItem
        let text: String
        let warning: Bool
        if let item, let reason = item.disabledReason {
            text = reason
            warning = true
        } else if let item {
            text = item.symbol == nil ? "Gem som \(item.title)" : item.title.capitalized
            warning = false
        } else {
            text = model.fileName
            warning = false
        }
        return Text(text)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(warning ? Color.white : Theme.ink)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .truncationMode(.middle)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(warning ? Color(red: 0.75, green: 0.22, blue: 0.17) : Theme.honey))
            .frame(maxWidth: 340)
    }
}

private struct WheelCell: View {
    let item: WheelItem
    let isHighlighted: Bool
    let radius: CGFloat

    var body: some View {
        let width = radius * sqrt(3)
        let height = radius * 2
        ZStack {
            Hexagon(cornerRadius: 8)
                .fill(fill)
            Hexagon(cornerRadius: 8)
                .stroke(isHighlighted ? Theme.ink : Theme.honey.opacity(0.55), lineWidth: isHighlighted ? 2 : 1)
            VStack(spacing: 3) {
                if let symbol = item.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: radius * 0.4, weight: .semibold))
                }
                Text(item.title)
                    .font(.system(size: item.symbol == nil ? radius * 0.34 : radius * 0.2, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: width * 0.82)
                if !item.isEnabled {
                    Image(systemName: "lock.fill")
                        .font(.system(size: radius * 0.18))
                }
            }
            .foregroundStyle(Theme.ink.opacity(item.isEnabled ? 1 : 0.45))
        }
        .frame(width: width, height: height)
        .scaleEffect(isHighlighted ? 1.17 : 1)
        .shadow(color: isHighlighted ? Theme.honey.opacity(0.75) : .black.opacity(0.3), radius: isHighlighted ? 12 : 3)
        .zIndex(isHighlighted ? 1 : 0)
    }

    private var fill: AnyShapeStyle {
        if !item.isEnabled { return AnyShapeStyle(Color(white: 0.55).opacity(0.55)) }
        if isHighlighted { return AnyShapeStyle(Theme.honeyGradient) }
        return AnyShapeStyle(Theme.wax)
    }
}

private struct WheelCenter: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        let radius = WheelGeometry.centerRadius
        ZStack {
            Hexagon(cornerRadius: 10)
                .fill(Theme.wax)
            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: radius * sqrt(3), height: radius * 2)
                    .clipShape(Hexagon(cornerRadius: 10))
            } else {
                BeeMark(size: radius)
            }
            Hexagon(cornerRadius: 10)
                .stroke(Theme.honey, lineWidth: 2)
            VStack {
                Spacer()
                Text(model.sizeText)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.honey))
                    .padding(.bottom, 14)
            }
            if model.count > 1 {
                Text("\(model.count)")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.wax)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.ink))
                    .overlay(Circle().stroke(Theme.honey, lineWidth: 1.5))
                    .offset(x: radius * 0.72, y: -radius * 0.62)
            }
            if model.clickMode {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.honey))
                    .offset(x: -radius * 0.72, y: -radius * 0.62)
                    .help("Klik på midten for at skifte mellem konvertering og værktøjer")
            }
        }
        .frame(width: radius * sqrt(3), height: radius * 2)
        .shadow(color: .black.opacity(0.35), radius: 6)
    }
}
