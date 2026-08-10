import SwiftUI

struct SessionRow: View {
    let session: Session
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: dotSymbol)
                .font(.system(size: 9))
                .foregroundStyle(dotColor)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(statusText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let percent = session.contextPercent {
                        Text("\(percent)%")
                            .monospacedDigit()
                            .foregroundStyle(contextColor(percent))
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
        .padding(.horizontal, 12)
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
        case .waitingPermission: .red
        case .idle: .secondary
        }
    }

    private var statusText: String {
        switch session.state {
        case .busy(let since): "busy \(Self.duration(now.timeIntervalSince(since)))"
        case .waitingPermission(let message): "waiting: \(message)"
        case .idle: "idle"
        }
    }

    private func contextColor(_ percent: Int) -> Color {
        percent >= 80 ? .red : (percent >= 60 ? .yellow : .green)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m\(String(format: "%02d", seconds % 60))s" }
        return "\(seconds / 3600)h\(String(format: "%02d", (seconds % 3600) / 60))m"
    }
}
