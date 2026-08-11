import ServiceManagement
import SwiftUI

struct MenuContent: View {
    let store: SessionStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var search = ""
    @State private var showDormant = false
    @AppStorage("menu.tab") private var tab = Tab.sessions

    private var filtered: [Session] {
        guard !search.isEmpty else { return store.sessions }
        return store.sessions.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.shortPath.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Picker("", selection: $tab) {
                Text("Sessions").tag(Tab.sessions)
                Text("Usage").tag(Tab.usage)
                Text("Changelog").tag(Tab.changelog)
                Text("News").tag(Tab.news)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.bottom, 7)

            Divider()

            // Every tab gets the same box and fills it. Nothing scrolls: a page that does
            // not fit is a page that is trying to be two pages.
            VStack(alignment: .leading, spacing: 0) {
                switch tab {
                case .sessions: sessionsTab
                case .usage: usageTab
                case .changelog:
                    ChangelogSection(releases: store.releases, installedVersion: store.installedVersion)
                case .news:
                    NewsSection(
                        feed: store.news,
                        refreshing: store.newsRefreshing,
                        error: store.newsError,
                        worstLimit: store.usage.worst,
                        refresh: { store.refreshNews() }
                    )
                }
            }
            .frame(height: Self.contentHeight, alignment: .top)

            Divider()
            footer
        }
        // Height is shared so the panel never jumps; width is not, because prose needs the
        // room and readings look stretched in it.
        .frame(width: tab == .news ? 540 : 360)
        .onAppear {
            store.menuOpened()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// One box, every tab. Chosen so the fullest page — sessions with jobs under it — fits
    /// without cutting anything.
    static let contentHeight: CGFloat = 410

    enum Tab: String {
        case sessions
        case usage
        case changelog
        case news
    }

    /// What is running, and what is waiting on you.
    private var sessionsTab: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let live = filtered.filter { !$0.isDormant(now: context.date) }
            let dormant = filtered.filter { $0.isDormant(now: context.date) }
            let shown = live.prefix(Self.visibleSessions)

            VStack(alignment: .leading, spacing: 0) {
                if store.sessions.isEmpty {
                    Text("No active sessions")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                } else {
                    if store.sessions.count > 6 {
                        TextField("Filter", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(size: 11))
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { session in
                            SessionRow(session: session, now: context.date)
                        }
                        if live.count > shown.count {
                            Text("+\(live.count - shown.count) more running — filter to reach them")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 2)
                        }
                        if !dormant.isEmpty {
                            dormantGroup(dormant, now: context.date)
                        }
                    }
                    .padding(.vertical, 3)
                }

                if !store.jobs.isEmpty {
                    Divider()
                    JobsSection(jobs: Array(store.jobs.prefix(Self.visibleJobs)), now: context.date)
                    if store.jobs.count > Self.visibleJobs {
                        Text("+\(store.jobs.count - Self.visibleJobs) more background jobs")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                    }
                }

                Spacer(minLength: 0)
                Divider()
                launcher
            }
        }
    }

    /// What it is costing: the plan, then the machine, then the tokens.
    private var usageTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                UsageSection(usage: store.usage, wifi: store.wifi, now: context.date)
            }
            Divider()
            ActivitySection(activity: store.activity)
            Divider()
            StatsSection(stats: store.stats)
            Spacer(minLength: 0)
        }
    }

    /// Caps rather than a scrollbar. Both are generous enough that hitting one means
    /// something is worth attending to, not that the panel is too small.
    private static let visibleSessions = 6
    private static let visibleJobs = 2


    private func dormantGroup(_ dormant: [Session], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    showDormant.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showDormant ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                        Text("\(dormant.count) dormant")
                        Text("idle over 12h").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)
                Button("Quit all") { Launcher.quit(dormant) }
                    .controlSize(.small)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            if showDormant {
                ForEach(dormant) { session in
                    SessionRow(session: session, now: now)
                        .opacity(0.65)
                }
            }
        }
    }

    /// The recent-project list with its New and Continue buttons went unused and cost more
    /// vertical space than everything below it; a folder picker covers the same ground in
    /// one line.
    private var launcher: some View {
        HStack(spacing: 6) {
            Text("Launch Claude in…")
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 4)
            Button("Browse folder…") {
                guard let directory = Launcher.chooseDirectory() else { return }
                Launcher.launch(directory: directory, resume: false)
            }
            .controlSize(.small)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claude Deck").font(.system(size: 12, weight: .semibold))
            Text(Self.version)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .help("Running from \(Bundle.main.bundlePath)")
            Spacer(minLength: 4)
            if store.waitingCount > 0 {
                pill("\(store.waitingCount) waiting", .critical)
            }
            if store.blockedJobCount > 0 {
                pill("\(store.blockedJobCount) blocked", .warning)
            }
            if store.busyCount > 0 {
                pill("\(store.busyCount) busy", .warning)
            }
            if store.busyCount == 0, store.waitingCount == 0 {
                Text("\(store.sessions.count) idle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [Color.primary.opacity(0.05), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// Read from the bundle rather than hardcoded, so it cannot drift from Info.plist and
    /// answers "which build is actually running" without a terminal.
    private static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short.map { "v\($0)" } ?? ""
    }

    private func pill(_ text: String, _ severity: Severity) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(severity.color.opacity(0.16), in: Capsule())
            .foregroundStyle(severity.color)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if store.hooksAreStale {
                    Label("Hooks need updating", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Severity.warning.color)
                } else if store.hooksInstalled {
                    Label("Hooks installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Severity.normal.color)
                } else {
                    Label("Hooks not installed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.hooksInstalled || store.hooksAreStale {
                    Button("Remove") { store.removeHooks() }
                        .controlSize(.small)
                }
                Button(store.hooksInstalled ? "Reinstall" : "Install hooks") {
                    store.installHooks()
                }
                .controlSize(.small)
            }
            .font(.system(size: 11))

            if store.hooksAreStale {
                Text("Hooks from an earlier version are still installed, and they record whole prompts and tool inputs. Reinstall replaces them with ones that record only what this menu shows.")
                    .font(.system(size: 10))
                    .foregroundStyle(Severity.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Hooks are read when a session starts, so already-running sessions report nothing until they are restarted.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Stores session ids, tool names and prompt-permission text in ~/.claude/claude-deck.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Clear data") { store.clearLocalData() }
                    .controlSize(.small)
            }

            if !Installer.isInstalled {
                HStack {
                    Label("Running from dist/", systemImage: "shippingbox")
                        .foregroundStyle(Severity.warning.color)
                    Spacer()
                    Button("Install") { Installer.installAndRelaunch() }
                        .controlSize(.small)
                }
                .font(.system(size: 11))
                .help("Copy to ~/Applications and restart there, so it survives a rebuild and can launch at login")
            }

            if store.notificationsBlocked {
                HStack {
                    Label("Notifications are turned off", systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Settings") {
                        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
                        NSWorkspace.shared.open(url)
                    }
                    .controlSize(.small)
                }
                .font(.system(size: 11))
            }

            if let error = store.installError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Text("Quit")
                    Spacer()
                    Text("⌘Q").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Registering only sticks from a stable location; from `dist/` the path moves on
    /// the next build and login would silently start a stale copy.
    private func setLaunchAtLogin(_ enabled: Bool) {
        guard Installer.isInstalled else {
            Launcher.alert(
                "Install Claude Deck first",
                "Launch at login needs the app in a stable location. Press Install above to copy it to ~/Applications and restart there, then switch this on.\n\nRunning from: \(Bundle.main.bundlePath)"
            )
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Launcher.alert("Could not change the login item", error.localizedDescription)
        }

        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        // Registering succeeds without throwing even when the item is switched off in
        // System Settings, which would otherwise just snap the checkbox back off.
        if enabled, status == .requiresApproval {
            Launcher.alert(
                "Claude Deck needs approval to launch at login",
                "The login item is registered but switched off. Turn Claude Deck on in System Settings › General › Login Items."
            )
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
