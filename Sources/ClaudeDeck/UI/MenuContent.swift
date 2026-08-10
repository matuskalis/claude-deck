import ServiceManagement
import SwiftUI

struct MenuContent: View {
    let store: SessionStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var search = ""
    @State private var showDormant = false

    private var filtered: [Session] {
        guard !search.isEmpty else { return store.sessions }
        return store.sessions.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.shortPath.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            TimelineView(.periodic(from: .now, by: 1)) { context in
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

                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(filtered.filter { !$0.isDormant(now: context.date) }) { session in
                                    SessionRow(session: session, now: context.date)
                                }

                                let dormant = filtered.filter { $0.isDormant(now: context.date) }
                                if !dormant.isEmpty {
                                    dormantGroup(dormant, now: context.date)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .frame(maxHeight: 340)
                    }

                    if !store.jobs.isEmpty {
                        Divider()
                        JobsSection(jobs: store.jobs, now: context.date)
                    }

                    Divider()
                    UsageSection(usage: store.usage, wifi: store.wifi, now: context.date)
                }
            }

            Divider()
            StatsSection(stats: store.stats)
            Divider()
            launcher
            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear {
            store.menuOpened()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// Terminal tabs left open days ago are most of the list on a normal machine, and they
    /// push the two sessions actually doing something off the top of it.
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

    private var launcher: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Launch Claude in…")
                .font(.system(size: 11, weight: .medium))
                .padding(.bottom, 1)

            ForEach(store.recentProjects, id: \.self) { project in
                HStack(spacing: 6) {
                    Text((project as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("New") { Launcher.launch(directory: project, resume: false) }
                    Button("Continue") { Launcher.launch(directory: project, resume: true) }
                }
                .controlSize(.small)
                .font(.system(size: 11))
            }

            Button("Browse folder…") {
                guard let directory = Launcher.chooseDirectory() else { return }
                Launcher.launch(directory: directory, resume: false)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claude Deck").font(.system(size: 12, weight: .semibold))
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
                if store.hooksInstalled {
                    Label("Hooks installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Hooks not installed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.hooksInstalled ? "Reinstall" : "Install hooks") {
                    store.installHooks()
                }
                .controlSize(.small)
            }
            .font(.system(size: 11))

            Text("Hooks are read when a session starts, so already-running sessions report nothing until they are restarted.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

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
