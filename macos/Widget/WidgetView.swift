// Shared look for the widget: the device model, the icon mapping, and the
// ring row. Kept in its own file so the same code can be rendered offscreen by
// Widget/Preview.swift for visual checking.
//
// Visual target (the reference is Apple's own battery widget): a row of rings,
// each with a device glyph and its percentage underneath, with any unfilled
// slot drawn as an empty ring. Light and dark mode both get a blue gradient,
// with the glyphs and numbers in white on top of it.

import SwiftUI

/// One battery. Must stay in sync with what PhoneBatteryBLEApp.swift writes.
struct DeviceReading: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// mac | phone | headphones | airpods | watch | keyboard | mouse | gamepad | other
    var kind: String
    var level: Int
    var charging: Bool
}

func symbolName(for kind: String) -> String {
    switch kind {
    case "mac": return "laptopcomputer"
    case "phone": return "iphone"
    case "headphones": return "headphones"
    case "airpods": return "airpods"
    case "watch": return "applewatch"
    case "keyboard": return "keyboard"
    case "mouse": return "computermouse"
    case "gamepad": return "gamecontroller"
    default: return "battery.100"
    }
}

/// The card background.
///
/// The frosted look comes from a Material base: on the desktop the system
/// composites the widget live over the wallpaper, so the material genuinely
/// blurs what is behind it. The blue tint is layered on top rather than painted
/// opaque, which is what keeps it reading as glass instead of a flat panel.
/// (An opaque gradient — the first version — has no glass look at all.)
struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme

    private var tint: [Color] {
        scheme == .dark
            ? [Color(red: 0.05, green: 0.10, blue: 0.36),
               Color(red: 0.09, green: 0.21, blue: 0.58)]
            // Light mode needs a much more saturated blue at a higher opacity:
            // ultraThinMaterial is near-white in light appearance, so a pale
            // tint over it washes out to grey-white instead of reading as glass.
            : [Color(red: 0.11, green: 0.40, blue: 0.90),
               Color(red: 0.30, green: 0.63, blue: 0.98)]
    }

    private var tintOpacity: Double { scheme == .dark ? 0.60 : 0.82 }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(tintOpacity)
        }
    }
}

/// A single ring: track, progress arc, glyph. An empty slot is track only.
struct DeviceRing: View {
    let level: Int?
    let charging: Bool
    let symbol: String
    let size: CGFloat

    private var lineWidth: CGFloat { max(4, size * 0.115) }

    private var fraction: Double {
        guard let level else { return 0 }
        return min(1, max(0, Double(level) / 100))
    }

    private var tint: Color {
        guard let level else { return .white }
        if level <= 10 { return Color(red: 1.0, green: 0.35, blue: 0.32) }
        if level <= 20 { return Color(red: 1.0, green: 0.72, blue: 0.25) }
        return Color(red: 0.22, green: 0.80, blue: 0.32)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.22),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            if level != nil {
                Circle()
                    .trim(from: 0, to: max(0.004, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol)
                    .font(.system(size: size * 0.33, weight: .medium))
                    .foregroundStyle(.white)
                if charging {
                    // A bolt on a white disc, sat on the ring's lower-right.
                    Image(systemName: "bolt.fill")
                        .font(.system(size: size * 0.15, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: size * 0.28, height: size * 0.28)
                        .background(Circle().fill(.white))
                        .offset(x: size * 0.30, y: size * 0.30)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// The ring row itself, without a background, so the widget can supply one via
/// `containerBackground` and the preview can draw its own.
struct WidgetContent: View {
    let devices: [DeviceReading]
    /// Small widgets get a 2x2 grid; medium widgets get a single row of four.
    let compact: Bool

    private let slotCount = 4

    private var slots: [DeviceReading?] {
        var list: [DeviceReading?] = devices.prefix(slotCount).map { $0 }
        while list.count < slotCount { list.append(nil) }
        return list
    }

    private var ringSize: CGFloat { compact ? 50 : 64 }

    private var fontSize: CGFloat { compact ? 13 : 15 }

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 8) {
                    HStack(spacing: 14) { slot(0); slot(1) }
                    HStack(spacing: 14) { slot(2); slot(3) }
                }
            } else {
                HStack(spacing: 16) {
                    ForEach(0..<slotCount, id: \.self) { slot($0) }
                }
            }
        }
        .padding(.horizontal, compact ? 8 : 14)
    }

    @ViewBuilder
    private func slot(_ index: Int) -> some View {
        let device = slots[index]
        VStack(spacing: 5) {
            DeviceRing(level: device?.level,
                       charging: device?.charging ?? false,
                       symbol: symbolName(for: device?.kind ?? "other"),
                       size: ringSize)
            Text(device.map { "\($0.level)%" } ?? " ")
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .opacity(device == nil ? 0.55 : 1)
    }
}
