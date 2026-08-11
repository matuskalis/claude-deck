import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [Session] = []
    private(set) var hooksInstalled = false
    private(set) var notificationsBlocked = false
    private(set) var installError: String?
    private(set) var recentProjects: [String] = []
    private(set) var stats = StatsSnapshot()
    private(set) var usage = UsageSnapshot()
    private(set) var wifi = WifiStatus()
    private(set) var jobs: [Job] = []

    @ObservationIgnored private let transcripts = TranscriptTail()
    @ObservationIgnored private let statsReader = StatsReader()
    @ObservationIgnored private let usageReader = UsageReader()
    @ObservationIgnored private let jobsReader = JobsReader()
    @ObservationIgnored private let history = HistoryTail()
    @ObservationIgnored private let spool = EventsSpool()
    @ObservationIgnored private let toolSpool = ToolSpool()
    @ObservationIgnored private let notifier = Notifier()

    @ObservationIgnored private var sessionsWatcher: DirWatcher?
    @ObservationIgnored private var spoolDirectoryWatcher: DirWatcher?
    @ObservationIgnored private var spoolFileWatcher: DirWatcher?
    @ObservationIgnored private var toolFileWatcher: DirWatcher?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var statsTimer: Timer?
    @ObservationIgnored private var meterTimer: Timer?
    /// One entry per threshold already announced, keyed by the window it applies to so the
    /// same limit alerts again after it resets.
    @ObservationIgnored private var announcedThresholds: Set<String> = []
    /// Job ids whose processes are alive, from the background session files.
    @ObservationIgnored private var runningJobIds: Set<String> = []
    /// The last `needs` each job was announced for, so a new question alerts again but the
    /// same one does not.
    @ObservationIgnored private var announcedNeeds: [String: String] = [:]

    /// Sessions blocked on a permission prompt. There is no on-disk signal for this,
    /// so the state comes from a hook event and is cleared once the session writes a
    /// newer status than the moment the event arrived.
    @ObservationIgnored private var permissionWaits: [String: (message: String, at: Date)] = [:]
    /// The tool each session is inside right now, set by PreToolUse and cleared by
    /// PostToolUse. Also cleared when a turn ends, so a killed session does not sit there
    /// claiming to be running something.
    @ObservationIgnored private var currentTool: [String: String] = [:]
    /// Turns that ended on an API error. Cleared only by the next prompt: the session goes
    /// idle the moment it fails, so nothing in its own status distinguishes the two.
    @ObservationIgnored private var failures: [String: String] = [:]
    @ObservationIgnored private var contextAnnounced: Set<String> = []
    @ObservationIgnored private var lastStatus: [String: String] = [:]
    @ObservationIgnored private var busySince: [String: Date] = [:]
    @ObservationIgnored private var usageCache: [String: TranscriptUsage] = [:]
    @ObservationIgnored private var oneMillionConfigured = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var sessionIdsStartedToday: Set<String> = []
    @ObservationIgnored private var statsPrimed = false

    var busyCount: Int {
        sessions.count { if case .busy = $0.state { return true } else { return false } }
    }

    var waitingCount: Int {
        sessions.count { if case .waitingPermission = $0.state { return true } else { return false } }
    }

    var blockedJobCount: Int {
        jobs.count { $0.isBlocked }
    }

    var failedCount: Int {
        sessions.count { if case .failed = $0.state { return true } else { return false } }
    }

    func start() {
        notifier.requestAuthorization()

        let sessionsDir = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/sessions")
        sessionsWatcher = DirWatcher(url: sessionsDir) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        // A directory watcher never sees appends to an existing file, so the spool
        // itself is watched too; the directory watcher only catches its recreation.
        // The tool spool is rotated by replacing the file, so the directory watcher is what
        // re-arms the file watcher onto the new inode.
        spoolDirectoryWatcher = DirWatcher(url: EventsSpool.directory) { [weak self] in
            Task { @MainActor in
                self?.watchSpoolFiles()
                self?.drainEvents()
            }
        }
        watchSpoolFiles()

        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.drainEvents()
            }
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMeters() }
        }

        refresh()
        refreshStats()
        refreshMeters()
    }

    private func watchSpoolFiles() {
        spoolFileWatcher = DirWatcher(url: EventsSpool.url) { [weak self] in
            Task { @MainActor in self?.drainEvents() }
        }
        toolFileWatcher = DirWatcher(url: ToolSpool.url) { [weak self] in
            Task { @MainActor in self?.drainEvents() }
        }
    }

    func menuOpened() {
        refresh()
        refreshStats()
        refreshMeters()
        loadUsage(for: sessions.map(\.id))
        Task { notificationsBlocked = await notifier.isBlocked() }
    }

    // MARK: - Plan limits and Wi-Fi

    private func refreshMeters() {
        Task.detached(priority: .utility) { [usageReader, jobsReader] in
            let usage = await usageReader.snapshot()
            let wifi = WifiStatus.read()
            let jobs = await jobsReader.snapshot()
            await self.apply(usage: usage, wifi: wifi, jobs: jobs)
        }
    }

    private func apply(usage: UsageSnapshot, wifi: WifiStatus, jobs incoming: [Job]) {
        jobs = incoming.map { job in
            var job = job
            job.running = runningJobIds.contains(job.id)
            return job
        }

        for job in jobs where job.isBlocked {
            guard let waiting = job.waitingOn, !waiting.isEmpty, announcedNeeds[job.id] != waiting else { continue }
            announcedNeeds[job.id] = waiting
            notifier.jobBlocked(job: job)
        }
        let blocked = Set(jobs.filter(\.isBlocked).map(\.id))
        announcedNeeds = announcedNeeds.filter { blocked.contains($0.key) }

        apply(usage: usage, wifi: wifi)
    }

    private func apply(usage: UsageSnapshot, wifi: WifiStatus) {
        if self.wifi.present, self.wifi.connected != wifi.connected {
            wifi.connected ? notifier.wifiRestored() : notifier.wifiDropped()
        }
        self.wifi = wifi

        guard usage != self.usage else { return }
        self.usage = usage
        for limit in usage.limits {
            let window = limit.resetsAt.map { "\(Int($0.timeIntervalSince1970))" } ?? "none"
            for threshold in [95, 80] where limit.percent >= threshold {
                let key = "\(limit.id)-\(window)-\(threshold)"
                guard announcedThresholds.insert(key).inserted else { break }
                notifier.usageThreshold(limit: limit, threshold: threshold)
                break
            }
        }
    }

    private func refreshStats() {
        let started = sessionIdsStartedToday
        Task.detached(priority: .utility) { [statsReader, history] in
            // History has to have been read at least once for today's prompts to exist.
            _ = await history.latestPrompts()
            let promptedToday = await history.sessionsPromptedToday()
            let snapshot = await statsReader.snapshot(
                sessionIdsStartedToday: started,
                promptedToday: promptedToday
            )
            await self.apply(stats: snapshot)
        }
    }

    private func apply(stats: StatsSnapshot) {
        self.stats = stats
    }

    func installHooks() {
        do {
            try HookInstaller.install()
            installError = nil
        } catch {
            installError = error.localizedDescription
        }
        hooksInstalled = HookInstaller.isInstalled
    }

    // MARK: - Refresh

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true

        Task.detached(priority: .utility) { [history] in
            let scan = Self.scanSessions()
            let prompts = await history.latestPrompts()
            let projects = await history.recentProjects(limit: 8)
            let oneMillion = TranscriptTail.oneMillionConfigured()
            let installed = HookInstaller.isInstalled
            await self.apply(
                scan: scan.live,
                runningJobIds: scan.runningJobIds,
                startedToday: scan.startedToday,
                prompts: prompts,
                projects: projects,
                oneMillion: oneMillion,
                hooksInstalled: installed
            )
        }
    }

    /// Background sessions are scanned too, but they are not listed as sessions: they have
    /// no terminal to go back to, and their job directory says far more about them than
    /// their session file does. All they contribute here is which jobs are still running.
    private nonisolated static func scanSessions() -> (live: [SessionFile], runningJobIds: Set<String>, startedToday: Set<String>) {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()

        let candidates = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SessionFile? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SessionFile.self, from: data)
            }
            .filter { $0.sessionId != nil && $0.pid != nil }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let startedToday = Set(candidates.filter {
            $0.kind != "bg" && Date(epochMilliseconds: $0.startedAt ?? 0) >= startOfDay
        }.compactMap(\.sessionId))

        let alive = ProcessCheck.alive(candidates.map { (pid: $0.pid ?? 0, procStart: $0.procStart) })
        let live = candidates.filter { alive.contains($0.pid ?? 0) }
        return (
            live.filter { $0.kind != "bg" },
            Set(live.filter { $0.kind == "bg" }.compactMap(\.jobId)),
            startedToday
        )
    }

    private func apply(
        scan: [SessionFile],
        runningJobIds: Set<String>,
        startedToday: Set<String>,
        prompts: [String: String],
        projects: [String],
        oneMillion: Bool,
        hooksInstalled: Bool
    ) {
        refreshing = false
        oneMillionConfigured = oneMillion
        self.hooksInstalled = hooksInstalled
        sessionIdsStartedToday = startedToday
        if self.runningJobIds != runningJobIds {
            self.runningJobIds = runningJobIds
            for index in jobs.indices { jobs[index].running = runningJobIds.contains(jobs[index].id) }
        }
        recentProjects = projects
        // The refresh at launch runs alongside the first session scan, so today's count
        // is only complete once that scan has landed.
        if !statsPrimed {
            statsPrimed = true
            refreshStats()
        }

        let liveIds = Set(scan.compactMap(\.sessionId))
        var flipped: [String] = []
        var built: [Session] = []

        for file in scan {
            guard let id = file.sessionId, let pid = file.pid else { continue }
            let statusChangedAt = Date(epochMilliseconds: file.statusUpdatedAt ?? file.updatedAt ?? file.startedAt ?? 0)
            let isBusy = file.status == "busy"

            if isBusy { busySince[id] = statusChangedAt }
            if lastStatus[id] != file.status {
                if lastStatus[id] != nil { flipped.append(id) }
                lastStatus[id] = file.status
            }

            var state: SessionState = isBusy ? .busy(since: statusChangedAt) : .idle
            if let wait = permissionWaits[id] {
                if statusChangedAt > wait.at {
                    permissionWaits[id] = nil
                } else {
                    state = .waitingPermission(message: wait.message)
                }
            }
            if let failure = failures[id], !isBusy {
                state = .failed(message: failure)
            }

            let usage = usageCache[id]
            built.append(Session(
                id: id,
                pid: pid,
                procStart: file.procStart,
                name: file.name ?? file.cwd.map { ($0 as NSString).lastPathComponent } ?? String(id.prefix(8)),
                cwd: file.cwd ?? "",
                state: state,
                rawStatus: file.status,
                lastPrompt: prompts[id],
                usage: usage,
                contextWindow: TranscriptTail.contextWindow(
                    used: usage?.contextUsed ?? 0,
                    oneMillionConfigured: oneMillion
                ),
                tool: currentTool[id],
                parkedJobId: file.parkedJobId,
                idleSince: isBusy ? nil : statusChangedAt
            ))
        }

        sessions = built.sorted(by: Self.order)
        permissionWaits = permissionWaits.filter { liveIds.contains($0.key) }
        lastStatus = lastStatus.filter { liveIds.contains($0.key) }
        busySince = busySince.filter { liveIds.contains($0.key) }
        usageCache = usageCache.filter { liveIds.contains($0.key) }
        currentTool = currentTool.filter { liveIds.contains($0.key) }
        failures = failures.filter { liveIds.contains($0.key) }
        contextAnnounced = contextAnnounced.filter { liveIds.contains($0) }
        Task.detached(priority: .background) { [transcripts] in await transcripts.forget(sessionIds: liveIds) }

        if !flipped.isEmpty { loadUsage(for: flipped) }
    }

    private static func order(_ lhs: Session, _ rhs: Session) -> Bool {
        func rank(_ state: SessionState) -> Int {
            switch state {
            case .waitingPermission: 0
            case .failed: 1
            case .busy: 2
            case .idle: 3
            }
        }
        let (left, right) = (rank(lhs.state), rank(rhs.state))
        return left == right ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending : left < right
    }

    // MARK: - Transcripts

    private func loadUsage(for ids: [String]) {
        guard !ids.isEmpty else { return }
        Task.detached(priority: .utility) { [transcripts] in
            var found: [String: TranscriptUsage] = [:]
            for id in ids {
                if let usage = await transcripts.usage(for: id) { found[id] = usage }
            }
            await self.applyUsage(found)
        }
    }

    private func applyUsage(_ found: [String: TranscriptUsage]) {
        guard !found.isEmpty else { return }
        usageCache.merge(found) { _, new in new }
        for index in sessions.indices {
            guard let usage = found[sessions[index].id] else { continue }
            sessions[index].usage = usage
            sessions[index].contextWindow = TranscriptTail.contextWindow(
                used: usage.contextUsed,
                oneMillionConfigured: oneMillionConfigured
            )
            announceContext(sessions[index])
        }
    }

    /// Re-arms below 70%, so a session that compacts and fills up again alerts a second
    /// time rather than going quiet for the rest of its life.
    private func announceContext(_ session: Session) {
        guard let percent = session.contextPercent else { return }
        if percent < 70 {
            contextAnnounced.remove(session.id)
        } else if percent >= 85, contextAnnounced.insert(session.id).inserted {
            notifier.contextFilling(name: session.name, percent: percent)
        }
    }

    // MARK: - Hook events

    private func drainEvents() {
        Task.detached(priority: .utility) { [spool, toolSpool] in
            // Tool events first, so that a Stop arriving in the same batch as the
            // PreToolUse before it still wins and clears the label.
            let events = await toolSpool.newEvents() + spool.newEvents()
            guard !events.isEmpty else { return }
            await self.handle(events: events)
        }
    }

    private func handle(events: [DeckEvent]) {
        for event in events {
            guard let id = event.sessionId else { continue }
            let session = sessions.first { $0.id == id }
            let project = (session?.cwd ?? event.cwd ?? "") as NSString

            switch event.hookEventName {
            case "Notification":
                permissionWaits[id] = (event.message ?? "Waiting for your approval", Date())
                notifier.permissionNeeded(
                    sessionId: id,
                    project: project.lastPathComponent,
                    message: event.message,
                    pid: session?.pid
                )

            case "PreToolUse":
                currentTool[id] = event.toolName

            case "PostToolUse":
                currentTool[id] = nil

            case "Stop":
                clearWait(id)
                currentTool[id] = nil
                if let since = busySince[id], Date().timeIntervalSince(since) >= 10 {
                    notifier.sessionFinished(
                        sessionId: id,
                        name: session?.name ?? project.lastPathComponent,
                        project: project.lastPathComponent,
                        pid: session?.pid
                    )
                }
                busySince[id] = nil
                loadUsage(for: [id])

            case "StopFailure":
                clearWait(id)
                currentTool[id] = nil
                busySince[id] = nil
                let message = event.message ?? "The turn ended with an API error"
                failures[id] = message
                notifier.sessionFailed(
                    sessionId: id,
                    name: session?.name ?? project.lastPathComponent,
                    message: message
                )

            case "UserPromptSubmit", "SessionEnd":
                clearWait(id)
                currentTool[id] = nil
                failures[id] = nil

            default:
                break
            }
        }
        // Applied here as well as in the next scan: a tool label that waited on the 3 s
        // refresh would be stale by the time it appeared.
        for index in sessions.indices {
            sessions[index].tool = currentTool[sessions[index].id]
        }
        refresh()
    }

    private func clearWait(_ id: String) {
        permissionWaits[id] = nil
        notifier.clearPermissionAlert(sessionId: id)
    }
}
