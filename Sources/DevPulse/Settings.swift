import ServiceManagement
import SwiftUI

/// UserDefaults keys for all settings, shared by @AppStorage and the sampling code.
enum Pref {
    // Menu bar items
    static let menuNetwork = "menuBar.network"
    static let menuCPU = "menuBar.cpu"
    static let menuCPUTemp = "menuBar.cpuTemperature"
    static let menuMemory = "menuBar.memory"
    static let menuGPUTemp = "menuBar.gpuTemperature"
    static let menuDisk = "menuBar.disk"
    static let menuBattery = "menuBar.battery"

    // Charts tab sections
    static let showNetwork = "charts.network"
    static let showConnection = "charts.connection"
    static let showCPU = "charts.cpu"
    static let showMemory = "charts.memory"
    static let showDisk = "charts.disk"
    static let showTemperature = "charts.temperature"
    static let showFans = "charts.fans"
    static let showBattery = "charts.battery"

    // General
    static let refreshInterval = "refreshInterval"

    /// Sampling interval in seconds (1, 2 or 5).
    static var interval: Double {
        let value = UserDefaults.standard.double(forKey: refreshInterval)
        return value > 0 ? value : 1
    }
}

// MARK: - Launch at login

enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - Settings view

struct SettingsView: View {
    let onDone: () -> Void

    @AppStorage(Pref.menuNetwork) private var menuNetwork = true
    @AppStorage(Pref.menuCPU) private var menuCPU = true
    @AppStorage(Pref.menuCPUTemp) private var menuCPUTemp = true
    @AppStorage(Pref.menuMemory) private var menuMemory = true
    @AppStorage(Pref.menuGPUTemp) private var menuGPUTemp = true
    @AppStorage(Pref.menuDisk) private var menuDisk = false
    @AppStorage(Pref.menuBattery) private var menuBattery = true

    @AppStorage(Pref.showNetwork) private var showNetwork = true
    @AppStorage(Pref.showConnection) private var showConnection = true
    @AppStorage(Pref.showCPU) private var showCPU = true
    @AppStorage(Pref.showMemory) private var showMemory = true
    @AppStorage(Pref.showDisk) private var showDisk = true
    @AppStorage(Pref.showTemperature) private var showTemperature = true
    @AppStorage(Pref.showFans) private var showFans = true
    @AppStorage(Pref.showBattery) private var showBattery = true

    @AppStorage(Pref.refreshInterval) private var refreshInterval = 1.0

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginStatus = LaunchAtLogin.status
    @State private var loginError: String?

    private let columns = [
        GridItem(.flexible(), alignment: .leading),
        GridItem(.flexible(), alignment: .leading),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Settings", systemImage: "gearshape")
                    .font(.headline)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }

            section("Menu bar") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    Toggle("Network", isOn: $menuNetwork)
                    Toggle("CPU load", isOn: $menuCPU)
                    Toggle("CPU temperature", isOn: $menuCPUTemp)
                    Toggle("Memory", isOn: $menuMemory)
                    Toggle("GPU temperature", isOn: $menuGPUTemp)
                    Toggle("Free disk space", isOn: $menuDisk)
                    Toggle("Battery", isOn: $menuBattery)
                }
            }

            section("Charts tab") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    Toggle("Network", isOn: $showNetwork)
                    Toggle("Connection details", isOn: $showConnection)
                        .disabled(!showNetwork)
                    Toggle("CPU", isOn: $showCPU)
                    Toggle("Memory", isOn: $showMemory)
                    Toggle("Disk", isOn: $showDisk)
                    Toggle("Temperature", isOn: $showTemperature)
                    Toggle("Fans", isOn: $showFans)
                    Toggle("Battery", isOn: $showBattery)
                }
            }

            section("General") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Refresh every")
                        Spacer()
                        Picker("Refresh every", selection: $refreshInterval) {
                            Text("1 s").tag(1.0)
                            Text("2 s").tag(2.0)
                            Text("5 s").tag(5.0)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    Toggle("Launch at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    ))

                    if loginStatus == .requiresApproval {
                        Button("Approve in System Settings…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .buttonStyle(.link)
                    }
                    if let loginError {
                        Text(loginError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            HStack(spacing: 4) {
                Text("DevPulse \(Self.version)")
                Text("·")
                Link("GitHub", destination: URL(string: "https://github.com/bartomiak/devpulse")!)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = LaunchAtLogin.isEnabled
        loginStatus = LaunchAtLogin.status
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
