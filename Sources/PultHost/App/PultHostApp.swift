import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

/// Pult host: a menu-bar app that lets a paired phone see and control this
/// Mac. The icon shows whether a phone is connected; the menu holds the
/// pairing details, the macOS permissions it needs, and updates.
@main
struct PultHostApp: App {
    @State private var server = HostServer()
    @State private var updater = Updater()
    @State private var systemSleep: PowerAssertion?

    var body: some Scene {
        MenuBarExtra {
            HostMenu(server: server, updater: updater)
                .onAppear(perform: boot)
        } label: {
            Image(systemName: isConnected ? "iphone.radiowaves.left.and.right" : "iphone")
                .task { boot() }
        }
        .menuBarExtraStyle(.window)
    }

    private var isConnected: Bool {
        if case .connected = server.status { return true }
        return false
    }

    private func boot() {
        guard systemSleep == nil else { return }
        // The point of the app is to be reachable, so keep the Mac awake.
        systemSleep = PowerAssertion.preventIdleSleep(reason: "Pult host")
        server.start()
        updater.startChecking()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
    }
}

struct HostMenu: View {
    @Bindable var server: HostServer
    @Bindable var updater: Updater

    @State private var screenOK = CGPreflightScreenCaptureAccess()
    @State private var inputOK = AXIsProcessTrusted()
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            pairingSection
            addressSection
            Divider()
            permissionsSection
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin, applyLoginItem)
            Divider()
            updateRow
            Button("Quit Pult") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            screenOK = CGPreflightScreenCaptureAccess()
            inputOK = AXIsProcessTrusted()
        }
    }

    private var header: some View {
        HStack {
            Text("Pult").font(.headline)
            Spacer()
            statusBadge
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch server.status {
        case .starting: Text("Starting…").foregroundStyle(.secondary)
        case .listening: Label("Ready", systemImage: "circle.fill").foregroundStyle(.green)
        case .connected: Label("Connected", systemImage: "iphone.radiowaves.left.and.right").foregroundStyle(.blue)
        case .failed(let message): Text(message).foregroundStyle(.red).lineLimit(2)
        }
    }

    @ViewBuilder private var pairingSection: some View {
        Toggle("Require pairing code", isOn: $server.requireCode)
        if server.requireCode {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pairing code").font(.caption).foregroundStyle(.secondary)
                Text(server.pairingCode)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
            }
        }
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("From anywhere (mobile data)").font(.caption).foregroundStyle(.secondary)
            LabeledContent("Public IP") {
                Text(server.access.publicIPv4 ?? "…")
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            Text("Forward TCP port \(String(Pult.securePort)) on your router to this Mac. Only the encrypted connection works there; the phone gets the key automatically when it first connects at home.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            permissionRow("Screen Recording", granted: screenOK) {
                CGRequestScreenCaptureAccess()
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
            permissionRow("Accessibility (mouse & keyboard)", granted: inputOK) {
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
        }
    }

    @ViewBuilder private var updateRow: some View {
        switch updater.state {
        case .available(let version):
            Button("Update to \(version)…") { Task { await updater.download() } }
        case .checking, .downloading:
            Label("Checking for updates…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .readyToInstall(let app):
            Button("Install update & relaunch") { updater.install(app) }
        case .failed:
            Button("Check for updates") { Task { await updater.check() } }
        case .idle, .upToDate:
            Button("Pult \(updater.currentVersion) — check for updates") { Task { await updater.check() } }
                .foregroundStyle(.secondary)
        }
    }

    private func permissionRow(_ title: String, granted: Bool, fix: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            if !granted { Button("Grant", action: fix) }
        }
    }

    private func applyLoginItem(_: Bool, _ enabled: Bool) {
        do {
            enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        } catch {
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}
