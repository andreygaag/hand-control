import AppKit
import HandControlEngine
import ServiceManagement
import SwiftUI

@main
struct HandControlApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.symbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor @Observable
final class AppModel {
    private(set) var status = EngineStatus()
    private(set) var camera: CameraMonitor.Snapshot?
    private(set) var loginItem = SMAppService.mainApp.status

    @ObservationIgnored private var engine: Engine!
    @ObservationIgnored private let monitor = CameraMonitor()
    @ObservationIgnored private var refresh: Timer?

    /// How often the camera readers section is recomputed. A snapshot is cheap (a lock, a
    /// CoreMediaIO query, a name lookup per candidate) and never waits for the log history.
    /// A timer rather than refresh-on-open: MenuBarExtra's .menu style gives no reliable
    /// "menu will open" hook.
    private static let refreshInterval: TimeInterval = 3

    /// Login items point at the bundle's path, so only an installed copy may register:
    /// build/HandControl.app is deleted by the next build.
    let isInstalled = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        .contains { Bundle.main.bundlePath.hasPrefix($0) }

    init() {
        engine = Engine(onStatus: { [weak self] status in
            // Main-queue blocks run in submission order; separate Tasks would not.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.status = status } }
        })
        monitor.start()
        Task { try? await engine.start() }
        refresh = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCamera() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [monitor] _ in
            monitor.stop()
            event("stopped (quit)")
        }
    }

    var symbol: String {
        switch status.state {
        case .active: "hand.raised.fill"
        case .idle, .starting: "hand.raised"
        case .paused: "hand.raised.slash"
        case .failed: "exclamationmark.triangle"
        }
    }

    var stateText: String {
        switch status.state {
        case .starting: "Starting…"
        case .active: "Active"
        case .idle: "Idle (no hand, low frame rate)"
        case .paused: "Paused (camera released)"
        case .failed(let message): "Error: \(message)"
        }
    }

    func refreshCamera() {
        camera = monitor.snapshot(engineStreaming: status.isStreaming)
        loginItem = SMAppService.mainApp.status
    }

    func togglePause() {
        let paused = status.state == .paused
        // AVFoundation start/stop block; the actor keeps them off the main thread.
        Task { paused ? await engine.resume() : await engine.pause() }
    }

    func reload() {
        Task { try? await engine.reload() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            event("error: launch at login: \(error)")
        }
        loginItem = SMAppService.mainApp.status
    }
}

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Text(model.stateText)
        if let camera = model.status.camera { Text("Camera: \(camera)") }
        if let fire = model.status.lastFire {
            Text("Last: \(fire.label) → \(fire.action) at \(fire.date.formatted(date: .omitted, time: .shortened))")
        }
        if let error = model.status.reloadError { Text("Reload failed: \(error)") }
        switch model.status.missingPermission {
        case .camera?: settingsButton("Open Camera Settings…", pane: "Privacy_Camera")
        case .accessibility?: settingsButton("Open Accessibility Settings…", pane: "Privacy_Accessibility")
        case nil: EmptyView()
        }

        Divider()
        cameraReaders

        Divider()
        if !model.status.bindings.isEmpty {
            Menu("Bindings") {
                ForEach(model.status.bindings, id: \.self) { Text($0) }
            }
        }
        Button(model.status.state == .paused ? "Resume" : "Pause") { model.togglePause() }
            .keyboardShortcut("p")
            .disabled(!(model.status.isStreaming || model.status.state == .paused))
        Button("Reload Config") { model.reload() }
            .keyboardShortcut("r")
            .disabled(model.status.state == .starting)
        Button("Open Config") { NSWorkspace.shared.open(Paths.current.config) }
        Button("Open Event Log") { NSWorkspace.shared.open(Paths.current.eventLog) }
        launchAtLogin

        Divider()
        Button("Quit Hand Control") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func settingsButton(_ title: String, pane: String) -> some View {
        Button(title) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        }
    }

    @ViewBuilder private var launchAtLogin: some View {
        if !model.isInstalled {
            Text("Launch at Login: install to ~/Applications first")
        } else if model.loginItem == .requiresApproval {
            Button("Launch at Login: approve in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
        } else {
            Toggle("Launch at Login", isOn: Binding(
                get: { model.loginItem == .enabled },
                set: { model.setLaunchAtLogin($0) }))
        }
    }

    @ViewBuilder private var cameraReaders: some View {
        if let camera = model.camera {
            if let error = camera.error { Text("Camera monitor: \(error)") }
            if camera.loading || model.status.state == .starting {
                // While our own stream starts, the log may count it before the status says so.
                Text("Checking other camera readers…")
            } else if camera.foreignStreams == 0 {
                Text("No other app is reading the camera")
            } else {
                Text("Other camera streams: \(camera.foreignStreams)")
                if camera.candidates.isEmpty {
                    Text("Owner unknown (connected before the 1 h log window)")
                }
                // The log cannot say which connected process owns a stream; list them all,
                // those seen starting a stream first.
                ForEach(camera.candidates.prefix(10), id: \.self) { client in
                    Text("\(client.name) (pid \(client.pid))\(client.startedStream ? " — started a stream" : "")")
                }
            }
        }
    }
}
