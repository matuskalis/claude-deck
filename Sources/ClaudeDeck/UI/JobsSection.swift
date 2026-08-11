import SwiftUI

/// Background jobs: the sessions with no window to look at.
struct JobsSection: View {
    let jobs: [Job]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Background jobs").font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                Text("\(jobs.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            ForEach(jobs) { job in
                JobRow(job: job, now: now)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

private struct JobRow: View {
    let job: Job
    let now: Date

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(severity.color)
                    .frame(width: 6, height: 6)
                Text(job.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(severity.color)
                if job.tokens > 0 {
                    Text(StatsSection.compact(job.tokens))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            // What it is blocked on comes first: a blocked job is the only kind that will
            // sit there indefinitely without someone acting on it.
            if job.isBlocked, let waiting = job.waitingOn {
                Text(waiting)
                    .font(.system(size: 10))
                    .foregroundStyle(Severity.warning.color)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if !job.options.isEmpty {
                    Text(job.options.joined(separator: "  ·  "))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let detail = job.detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(job.fan) { task in
                HStack(spacing: 4) {
                    Image(systemName: task.kind == "shell" ? "terminal" : "sparkle")
                        .font(.system(size: 8))
                    Text(task.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let started = task.startedAt {
                        Text(SessionRow.duration(now.timeIntervalSince(started)))
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }

            if !job.timeline.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    // Bounded and scrolled: a timeline note can be a paragraph, and three of
                    // them would otherwise push the rest of the page out of its box.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(job.timeline.reversed()) { entry in
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text(entry.state ?? "")
                                        Spacer()
                                        if let at = entry.at {
                                            Text("\(SessionRow.duration(now.timeIntervalSince(at))) ago")
                                                .monospacedDigit()
                                        }
                                    }
                                    .foregroundStyle(.tertiary)
                                    Text(entry.detail ?? entry.text ?? "")
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                    .frame(maxHeight: 120)
                } label: {
                    Text(expanded ? "Hide timeline" : "Timeline")
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 9))
                .font(.system(size: 9))
            }
        }
        .padding(.vertical, 3)
    }

    /// A job whose directory still says "working" but whose process is gone died without
    /// writing a final state, and that is worth seeing rather than hiding.
    private var status: String {
        if !job.running { return "not running" }
        if job.isBlocked { return "blocked" }
        if job.inFlight > 0 {
            return job.queued > 0 ? "\(job.inFlight) running, \(job.queued) queued" : "\(job.inFlight) running"
        }
        return job.state
    }

    private var severity: Severity {
        if !job.running { return .critical }
        return job.isBlocked ? .warning : .normal
    }
}
