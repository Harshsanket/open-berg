import SwiftUI

/// Shared visual language for the panel and the setup window.
///
/// The look follows the dark card-based control app it was remodelled on: a
/// deep navy backdrop, glassy raised surfaces, blue accent glows when
/// something is active, and warm orange for the light. The app is dark-only —
/// each window pins `darkAqua` once — and every colour is fixed, never
/// derived from `Color.primary`.
enum Palette {
    /// The panel backdrop — neutral near-black.
    static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    /// The fan itself — the electric blue the reference tiles glow with.
    static let fan = Color(red: 0.25, green: 0.55, blue: 1.0)
    /// Brighter accent for tinted-only glyphs that carry no fill.
    static let fanBright = Color(red: 0.40, green: 0.70, blue: 1.0)
    /// The light on the fan.
    static let light = Color(red: 1.0, green: 0.62, blue: 0.20)
    /// Vivid orange — the runtime stat.
    static let orange = Color(red: 1.0, green: 0.58, blue: 0.0)
    /// Green — the energy stat.
    static let green = Color(red: 0.20, green: 0.80, blue: 0.38)
    /// Idle or unreachable.
    static let idle = Color(red: 0.45, green: 0.48, blue: 0.55)
    /// Primary text.
    static let text = Color.white
    /// Secondary text.
    static let textSecondary = Color.white.opacity(0.55)
    /// Tertiary text.
    static let textTertiary = Color.white.opacity(0.35)
    /// Hairline strokes.
    static let stroke = Color.white.opacity(0.08)
}

// MARK: - Surfaces

private struct CardSurface: ViewModifier {
    var radius: CGFloat
    var padding: CGFloat
    var tint: Color

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                // Opaque near-black base under a light tint wash, so every
                // surface reads the same colour whatever sits behind it.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(tint.opacity(0.10))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(tint.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

extension View {
    /// One raised surface. Every card shares the same opaque base, so the
    /// panel looks identical over any desktop.
    func card(
        radius: CGFloat = 16,
        padding: CGFloat = 14,
        tint: Color = Palette.fan
    ) -> some View {
        modifier(CardSurface(radius: radius, padding: padding, tint: tint))
    }
}

// MARK: - Labels

struct SectionLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Palette.textTertiary)
            Spacer(minLength: 0)
        }
    }
}

/// The "· Online · cloud" style status line under a title.
struct StatusLine: View {
    let online: Bool?
    let local: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
                .shadow(color: dot.opacity(0.8), radius: 3)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
        }
        .help(help)
    }

    private var dot: Color {
        if online == false { return Palette.idle }
        return local ? .green : Palette.fan
    }

    private var text: String {
        if online == false { return "Offline · last reported values" }
        return local ? "Online · local network" : "Online · cloud"
    }

    private var help: String {
        if online == false {
            return "The fan has not reported in, so these values are the last known ones."
        }
        return local
            ? "Controlled over your local network, which uses no API calls."
            : "Controlled through the Atomberg cloud API."
    }
}

// MARK: - Buttons

/// Circular icon button, used for power, the light and the − / + steppers.
struct CircleButton: View {
    let systemName: String
    var size: CGFloat = 32
    var tint: Color = Palette.fan
    var filled: Bool = false
    var glow: Bool = false
    /// Give the resting state a tinted disc instead of staying transparent —
    /// used for the steppers inside cards, where a bare outline disappears.
    var tinted: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.40, weight: .semibold))
                .frame(width: size, height: size)
                .background {
                    // Solid accent at full opacity when on; a light tint at
                    // rest for in-card steppers, transparent for the header.
                    Circle().fill(
                        filled ? tint : (tinted ? tint.opacity(0.18) : Color.clear)
                    )
                }
                .overlay {
                    Circle().strokeBorder(
                        filled
                            ? Color.clear
                            : (tinted ? tint.opacity(0.30) : Color.white.opacity(0.12)),
                        lineWidth: 1
                    )
                }
                .foregroundStyle(filled ? Color.white : Palette.text)
                .shadow(color: filled && glow ? tint.opacity(0.6) : .clear, radius: 12, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// The tile from the reference: icon on top, label and value below,
/// tinted border and glow while active.
struct QuickTile: View {
    let icon: String
    let title: String
    let value: String
    var active: Bool = false
    var tint: Color = Palette.fan
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(active ? Color.white : Palette.textSecondary)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 6)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(active ? Color.white.opacity(0.8) : Palette.textSecondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Palette.text)
                    .lineLimit(1)
            }
            // Only the content dims when disabled — the surface itself is
            // added below, after this opacity, so it stays the full navy.
            .opacity(enabled ? 1 : 0.45)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .padding(11)
            .background {
                // Same recipe as every card: opaque near-black base under a
                // light tint wash, solid accent when on.
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Palette.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(active ? tint : tint.opacity(0.10))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(
                        active ? Color.clear : tint.opacity(0.25),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: active ? tint.opacity(0.55) : .black.opacity(0.25),
                radius: active ? 14 : 6,
                y: 2
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        // `.disabled` makes macOS dim the whole tile, which turns translucent
        // over the glass panel; hit-testing alone keeps the same navy surface
        // and still stops the action while the fan is off.
        .allowsHitTesting(enabled)
    }
}

/// Pill used for the small "All on" style actions.
struct PillButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Palette.stroke))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Controls

/// The rounded gradient track with a sliding white thumb.
///
/// A commit only happens when the drag ends, so dragging across six speeds
/// sends one command rather than six.
struct GradientSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let gradient: LinearGradient
    var onCommit: () -> Void

    private let trackHeight: CGFloat = 34
    private let thumbWidth: CGFloat = 48

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - thumbWidth)
            let span = range.upperBound - range.lowerBound
            let fraction = span == 0 ? 0 : (value - range.lowerBound) / span
            let offset = travel * min(max(fraction, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(gradient)
                    .frame(height: trackHeight)
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    }

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white)
                    .frame(width: thumbWidth, height: trackHeight - 8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.black.opacity(0.10), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.30), radius: 5, y: 1)
                    .offset(x: offset + 4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clamped = min(max(drag.location.x - thumbWidth / 2, 0), travel)
                        value = range.lowerBound + (clamped / travel) * span
                    }
                    .onEnded { _ in onCommit() }
            )
        }
        .frame(height: trackHeight)
    }
}

/// A big light numeric readout, as used for the headline value.
struct Readout: View {
    let value: String
    var unit: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: 52, weight: .light))
                .monospacedDigit()
                .foregroundStyle(Palette.text)
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

// MARK: - Stat cards

/// A small card showing one lifetime statistic: icon, big number, caption.
struct StatCard: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Palette.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            // The standard card interior, same as every other surface — the
            // accent lives in the icon only.
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Palette.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Palette.fan.opacity(0.10))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Palette.fan.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

// MARK: - Notices

struct Notice: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 14)
    }
}
