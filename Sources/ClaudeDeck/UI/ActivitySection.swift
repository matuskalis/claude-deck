import SwiftUI

/// What the sessions cost the machine, as opposed to what they cost the plan.
struct ActivitySection: View {
    let activity: ActivitySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Machine").font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                if let busiest = activity.busiest, busiest.cpuPercent >= 5 {
                    Text("\(busiest.name) busiest")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 10) {
                reading("CPU", Self.cpu(activity.cpuPercent), cpuSeverity)
                reading("Memory", Self.bytes(activity.residentBytes), memorySeverity)
                reading("~/.claude", Self.bytes(activity.claudeBytes), .normal)
                reading("Free", Self.bytes(activity.freeBytes), freeSeverity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func reading(_ label: String, _ value: String, _ severity: Severity) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(severity.color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Against one core, not against all of them: a single session cannot use more than one
    /// core's worth of the main thread, so 100% is the number that means "flat out".
    private var cpuSeverity: Severity {
        activity.cpuPercent >= 150 ? .critical : (activity.cpuPercent >= 60 ? .warning : .normal)
    }

    private var memorySeverity: Severity {
        let gigabytes = Double(activity.residentBytes) / 1_073_741_824
        return gigabytes >= 8 ? .critical : (gigabytes >= 4 ? .warning : .normal)
    }

    private var freeSeverity: Severity {
        let gigabytes = Double(activity.freeBytes) / 1_073_741_824
        return gigabytes < 10 ? .critical : (gigabytes < 30 ? .warning : .normal)
    }

    static func cpu(_ percent: Double) -> String {
        percent < 10 ? String(format: "%.1f%%", percent) : "\(Int(percent.rounded()))%"
    }

    static func bytes(_ value: Int) -> String {
        let units = Double(value)
        switch units {
        case 1_073_741_824...: return String(format: "%.1f GB", units / 1_073_741_824)
        case 1_048_576...: return String(format: "%.0f MB", units / 1_048_576)
        case 1024...: return String(format: "%.0f KB", units / 1024)
        default: return "\(value) B"
        }
    }
}
