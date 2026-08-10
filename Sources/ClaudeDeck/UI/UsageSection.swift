import SwiftUI

/// Plan limits as Claude Code last fetched them, plus the link they all depend on.
struct UsageSection: View {
    let usage: UsageSnapshot
    let wifi: WifiStatus
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Plan limits").font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                if wifi.present { link }
            }

            if usage.limits.isEmpty {
                Text("No usage figures cached yet. Claude Code writes them to ~/.claude.json when it fetches your limits.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(usage.limits.prefix(4)) { limit in
                    meter(limit)
                }
                if let fetched = usage.fetchedAt {
                    Text("as of \(Self.clock.string(from: fetched)), refreshed by Claude Code")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func meter(_ limit: UsageLimit) -> some View {
        let severity = Severity(api: limit.severity, percent: limit.percent)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(limit.title)
                    .foregroundStyle(limit.isActive ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let resets = limit.resetsAt, resets > now {
                    Text("resets in \(SessionRow.duration(resets.timeIntervalSince(now)))")
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text("\(limit.percent)%")
                    .monospacedDigit()
                    .foregroundStyle(severity.color)
                    .fontWeight(.medium)
            }
            .font(.system(size: 11))

            MeterBar(percent: limit.percent, severity: severity)

            if let reaches = usage.forecast[limit.id] {
                Text("on course to hit 100% \(Self.when(reaches))")
                    .font(.system(size: 9))
                    .foregroundStyle(Severity.warning.color.opacity(0.9))
            }
        }
    }

    /// Same day reads as a time, anything further out needs the day with it.
    private static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        if !Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "EEE " + (formatter.dateFormat ?? "HH:mm")
        }
        return formatter.string(from: date)
    }

    private var link: some View {
        let severity: Severity = wifi.bars >= 3 ? .normal : (wifi.bars == 2 ? .warning : .critical)
        return HStack(spacing: 4) {
            WifiBars(bars: wifi.bars, severity: severity)
            Text(wifi.connected ? "\(wifi.label) · \(Int(wifi.transmitRate)) Mbps" : "offline")
                .font(.system(size: 10))
                .foregroundStyle(wifi.connected ? AnyShapeStyle(.secondary) : AnyShapeStyle(severity.color))
                .monospacedDigit()
        }
        .help(wifi.connected
              ? "RSSI \(wifi.rssi) dBm, noise \(wifi.noise) dBm, SNR \(wifi.snr) dB"
              : "No Wi-Fi association")
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
