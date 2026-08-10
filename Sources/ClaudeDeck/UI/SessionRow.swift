import SwiftUI

struct SessionRow: View {
    let session: Session
    let now: Date

    @State private var hovering = false

    var body: some View {
        Button {
            Launcher.focus(pid: session.pid, name: session.name)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: dotSymbol)
                    .font(.system(size: 9))
                    .foregroundStyle(dotColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: isBusy)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(session.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let model = shortModel {
                            tag(model)
                        }
                        if session.parkedJobId != nil {
                            tag("parked")
                        }
                        Spacer(minLength: 4)
                        Text(statusText)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let percent = session.contextPercent {
                            RingGauge(percent: percent, severity: Severity(percent: percent))
                            Text("\(percent)%")
                                .monospacedDigit()
                                .foregroundStyle(Severity(percent: percent).color)
                        }
                    }
                    .font(.system(size: 12))

                    HStack(spacing: 6) {
                        Text(session.shortPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                        if let prompt = session.lastPrompt, !prompt.isEmpty {
                            Text("“\(prompt.replacingOccurrences(of: "\n", with: " "))”")
                                .italic()
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
        .help("Bring this session's terminal window to the front")
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private var isBusy: Bool {
        if case .busy = session.state { return true }
        return false
    }

    /// `claude-opus-4-8` reads as `opus` in a row that is already tight.
    private var shortModel: String? {
        guard let model = session.usage?.model else { return nil }
        let parts = model.split(separator: "-")
        guard parts.count > 1, parts[0] == "claude" else { return nil }
        return String(parts[1])
    }

    private var dotSymbol: String {
        switch session.state {
        case .busy: "circle.fill"
        case .waitingPermission: "circle.lefthalf.filled"
        case .idle: "circle"
        }
    }

    private var dotColor: Color {
        switch session.state {
        case .busy: .orange
        case .waitingPermission: Severity.critical.color
        case .idle: .secondary
        }
    }

    private var statusText: String {
        switch session.state {
        case .busy(let since):
            "\(session.tool ?? "busy") \(Self.duration(now.timeIntervalSince(since)))"
        case .waitingPermission(let message): "waiting: \(message)"
        case .idle: "idle"
        }
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m\(String(format: "%02d", seconds % 60))s" }
        return "\(seconds / 3600)h\(String(format: "%02d", (seconds % 3600) / 60))m"
    }
}
