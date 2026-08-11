import SwiftUI

/// Shared colour scale. Everything that reports a fill — plan limits, context windows,
/// signal strength — uses these three steps so a colour means the same thing everywhere.
enum Severity: Sendable {
    case normal
    case warning
    case critical

    init(percent: Int) {
        self = percent >= 90 ? .critical : (percent >= 75 ? .warning : .normal)
    }

    /// The API sends its own severity, which is authoritative for plan limits because the
    /// thresholds are Anthropic's, not ours.
    init(api: String, percent: Int) {
        switch api {
        case "critical", "exceeded": self = .critical
        case "warning": self = .warning
        case "normal": self = .normal
        default: self = Severity(percent: percent)
        }
    }

    var color: Color {
        switch self {
        case .normal: Color(red: 0.20, green: 0.78, blue: 0.55)
        case .warning: Color(red: 0.98, green: 0.68, blue: 0.18)
        case .critical: Color(red: 0.95, green: 0.35, blue: 0.32)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [color.opacity(0.55), color],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// A capsule meter. Fills right, animates on change, and never renders a zero-width sliver
/// that reads as a rendering glitch.
struct MeterBar: View {
    let percent: Int
    let severity: Severity
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(severity.gradient)
                    .frame(width: max(percent > 0 ? height : 0, geometry.size.width * fraction))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: percent)
    }

    private var fraction: Double {
        min(1, max(0, Double(percent) / 100))
    }
}

/// The per-session context gauge: small enough to sit inline in a row.
struct RingGauge: View {
    let percent: Int
    let severity: Severity
    var size: CGFloat = 13
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0.01, Double(percent) / 100)))
                .stroke(severity.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.35), value: percent)
    }
}

/// Seven days of tokens, drawn from the figures Claude Code already keeps.
struct Sparkline: View {
    let values: [Int]
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geometry in
            let points = points(in: geometry.size)
            ZStack {
                if points.count > 1 {
                    area(points, height: geometry.size.height)
                        .fill(LinearGradient(
                            colors: [color.opacity(0.28), color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                    line(points)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    if let last = points.last {
                        Circle()
                            .fill(color)
                            .frame(width: 3.5, height: 3.5)
                            .position(last)
                    }
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let peak = max(1, values.max() ?? 1)
        let step = size.width / CGFloat(values.count - 1)
        // One point of headroom top and bottom so the peak and a zero day are both visible.
        return values.enumerated().map { index, value in
            let ratio = CGFloat(value) / CGFloat(peak)
            return CGPoint(x: CGFloat(index) * step, y: size.height - 1 - ratio * (size.height - 2))
        }
    }

    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        return path
    }

    private func area(_ points: [CGPoint], height: CGFloat) -> Path {
        var path = line(points)
        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: height))
        path.addLine(to: CGPoint(x: points[0].x, y: height))
        path.closeSubpath()
        return path
    }
}

/// A labelled slider sized for a menu bar panel: what it controls on the left, where it
/// currently sits on the right.
///
/// Hand-built rather than a `Slider`, because a stock one is drawn in the system accent
/// colour and this panel already has a palette of its own. The track is the same capsule
/// and the same gradient as `MeterBar`, so a filled slider and a filled meter read as the
/// same kind of object.
struct StopSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let caption: String
    var severity: Severity = .normal

    private static let knob: CGFloat = 12
    private static let track: CGFloat = 5

    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                // Deliberately not the accent colour: elsewhere in this menu a green
                // reading means "healthy", and "30 days" is not a health reading.
                Text(caption)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
            }

            GeometryReader { geometry in
                let travel = max(1, geometry.size.width - Self.knob)
                let offset = travel * fraction

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.09))
                        .frame(height: Self.track)

                    Capsule()
                        .fill(severity.gradient)
                        .frame(width: offset + Self.knob / 2, height: Self.track)

                    // Only where the stops are countable: ninety of them would be noise.
                    if stops > 1, stops <= 12 {
                        ForEach(0..<stops, id: \.self) { stop in
                            Circle()
                                .fill(Color.primary.opacity(0.22))
                                .frame(width: 2.5, height: 2.5)
                                .offset(x: Self.knob / 2 - 1.25 + travel * (Double(stop) / Double(stops - 1)))
                        }
                    }

                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(Circle().strokeBorder(severity.color, lineWidth: 2.5))
                        .frame(width: Self.knob, height: Self.knob)
                        .shadow(color: .black.opacity(0.22), radius: dragging ? 2.5 : 1, y: 0.5)
                        .scaleEffect(dragging ? 1.15 : 1)
                        .offset(x: offset)
                }
                .frame(height: Self.knob)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            dragging = true
                            set(from: gesture.location.x, travel: travel)
                        }
                        .onEnded { _ in dragging = false }
                )
                .animation(.easeOut(duration: 0.12), value: dragging)
            }
            .frame(height: Self.knob)
        }
    }

    private var span: Double { max(0.0001, range.upperBound - range.lowerBound) }
    private var fraction: Double { min(1, max(0, (value - range.lowerBound) / span)) }
    private var stops: Int { step > 0 ? Int((span / step).rounded()) + 1 : 0 }

    /// The pointer addresses the centre of the knob, so half of it comes off the front of
    /// the travel before the position is read.
    private func set(from x: CGFloat, travel: CGFloat) {
        let ratio = min(1, max(0, (x - Self.knob / 2) / travel))
        let raw = range.lowerBound + Double(ratio) * span
        let snapped = step > 0 ? (raw / step).rounded() * step : raw
        value = min(range.upperBound, max(range.lowerBound, snapped))
    }
}

/// Four rising bars, the ones filled being the ones the link quality earns.
struct WifiBars: View {
    let bars: Int
    let severity: Severity

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...4, id: \.self) { step in
                Capsule()
                    .fill(step <= bars ? AnyShapeStyle(severity.color) : AnyShapeStyle(Color.primary.opacity(0.15)))
                    .frame(width: 2.5, height: 3 + CGFloat(step) * 2.2)
            }
        }
        .frame(height: 12, alignment: .bottom)
        .animation(.easeOut(duration: 0.35), value: bars)
    }
}
