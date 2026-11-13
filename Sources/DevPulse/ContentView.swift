import Charts
import SwiftUI

enum Tab: String, CaseIterable {
    case charts, processes, ports, services

    var title: String {
        switch self {
        case .charts:    return "Charts"
        case .processes: return "Processes"
        case .ports:     return "Ports"
        case .services:  return "Services"
        }
    }
}

struct ContentView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var processMonitor: ProcessMonitor
    @ObservedObject var brewServices: BrewServicesModel
    @ObservedObject var networkInfo: NetworkInfoModel
    @AppStorage("selectedTab") private var tab: Tab = .charts
    @State private var chartsHeight: CGFloat = 0
    @State private var showingSettings = false

    @AppStorage(Pref.showNetwork) private var showNetwork = true
    @AppStorage(Pref.showConnection) private var showConnection = true
    @AppStorage(Pref.showCPU) private var showCPU = true
    @AppStorage(Pref.showMemory) private var showMemory = true
    @AppStorage(Pref.showDisk) private var showDisk = true
    @AppStorage(Pref.showTemperature) private var showTemperature = true
    @AppStorage(Pref.showFans) private var showFans = true
    @AppStorage(Pref.showBattery) private var showBattery = true
    @AppStorage(Pref.refreshInterval) private var refreshInterval = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showingSettings {
                SettingsView { showingSettings = false }
            } else {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch tab {
                case .charts:
                    chartsTab
                case .processes:
                    ProcessesView(processMonitor: processMonitor)
                case .ports:
                    PortsView(processMonitor: processMonitor)
                case .services:
                    ServicesView(model: brewServices)
                }
            }

            Divider()

            HStack {
                if !showingSettings {
                    Text(footerText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(showingSettings ? Color.accentColor : .secondary)
                .keyboardShortcut(",")
                .help("Settings (⌘,)")

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: Charts tab

    /// Scrolls only when the charts don't fit on screen (e.g. 13" laptops):
    /// the content height is measured and the scroll view is sized to fit it, up to the screen limit.
    private var chartsTab: some View {
        let needsScroll = chartsHeight > Self.maxChartsHeight
        return ScrollView {
            chartSections
                .padding(.trailing, needsScroll ? 12 : 0)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
                    }
                )
        }
        .scrollDisabled(!needsScroll)
        .frame(height: min(chartsHeight, Self.maxChartsHeight))
        .onPreferenceChange(ContentHeightKey.self) { chartsHeight = $0 }
    }

    private var chartSections: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showNetwork { networkSection }
            if showCPU { cpuSection }
            if showMemory { memorySection }
            if showDisk { diskSection }
            if showTemperature { temperatureSection }
            if showFans, !monitor.fans.isEmpty {
                fanSection
            }
            if showBattery, let battery = monitor.battery {
                batterySection(battery)
            }
            if !(showNetwork || showCPU || showMemory || showDisk || showTemperature || showFans || showBattery) {
                Text("All charts are hidden – enable them in Settings (⌘,)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
    }

    /// Screen height minus room for the menu bar, tab picker and footer.
    private static var maxChartsHeight: CGFloat {
        max((NSScreen.main?.visibleFrame.height ?? 900) - 140, 320)
    }

    private var footerText: String {
        switch tab {
        case .charts:    return "Last \(Format.historySpan(seconds: Double(Monitor.historyLength) * refreshInterval))"
        case .processes: return "Refreshed every 3 s"
        case .ports:     return "Click a port to open it in the browser"
        case .services:  return "Managed with brew services"
        }
    }

    // MARK: Fans

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Fans", systemImage: "fanblades")
                .font(.headline)

            ForEach(monitor.fans) { fan in
                HStack(spacing: 8) {
                    Text(verbatim: String(fan.id + 1))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    ProgressView(value: fan.fraction)
                        .tint(.teal)
                    Text(verbatim: "\(Int(fan.rpm.rounded())) RPM")
                        .foregroundStyle(.teal)
                        .frame(width: 96, alignment: .trailing)
                }
                .font(.callout.monospacedDigit())
                .help("Min \(Int(fan.minRPM)) · max \(Int(fan.maxRPM)) RPM")
            }
        }
    }

    // MARK: Network

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Network", systemImage: "network")
                    .font(.headline)
                Spacer()
                Text("↓ \(Format.rate(monitor.currentDownload))")
                    .foregroundStyle(.blue)
                Text("↑ \(Format.rate(monitor.currentUpload))")
                    .foregroundStyle(.green)
            }
            .font(.callout.monospacedDigit())

            Chart {
                ForEach(monitor.download) { s in
                    AreaMark(x: .value("Time", s.time), y: .value("Download", s.value),
                             series: .value("Direction", "down"))
                        .foregroundStyle(.blue.opacity(0.15))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", s.time), y: .value("Download", s.value),
                             series: .value("Direction", "down"))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)
                }
                ForEach(monitor.upload) { s in
                    LineMark(x: .value("Time", s.time), y: .value("Upload", s.value),
                             series: .value("Direction", "up"))
                        .foregroundStyle(.green)
                        .interpolationMethod(.monotone)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(Format.rate(v)).font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 80)

            if showConnection {
                NetworkInfoView(model: networkInfo)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: CPU

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("CPU", systemImage: "cpu")
                    .font(.headline)
                Spacer()
                Text(Format.percent(monitor.currentCPU))
                    .foregroundStyle(.orange)
            }
            .font(.callout.monospacedDigit())

            Chart(monitor.cpu) { s in
                AreaMark(x: .value("Time", s.time), y: .value("CPU", s.value))
                    .foregroundStyle(.orange.opacity(0.15))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.time), y: .value("CPU", s.value))
                    .foregroundStyle(.orange)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v))%").font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 70)
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Memory", systemImage: "memorychip")
                    .font(.headline)
                Spacer()
                if let usage = monitor.memoryUsage {
                    Text("\(Format.gigabytes(usage.used)) / \(Format.gigabytes(usage.total))")
                        .foregroundStyle(.purple)
                } else {
                    Text("—")
                }
            }
            .font(.callout.monospacedDigit())

            Chart(monitor.memory) { s in
                AreaMark(x: .value("Time", s.time), y: .value("Memory", s.value))
                    .foregroundStyle(.purple.opacity(0.15))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.time), y: .value("Memory", s.value))
                    .foregroundStyle(.purple)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v))%").font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 70)
        }
    }

    // MARK: Disk

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Disk", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
                Text("R \(Format.rate(monitor.currentDiskRead))")
                    .foregroundStyle(.cyan)
                Text("W \(Format.rate(monitor.currentDiskWrite))")
                    .foregroundStyle(.pink)
            }
            .font(.callout.monospacedDigit())

            Chart {
                ForEach(monitor.diskRead) { s in
                    AreaMark(x: .value("Time", s.time), y: .value("Read", s.value),
                             series: .value("Direction", "read"))
                        .foregroundStyle(.cyan.opacity(0.15))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", s.time), y: .value("Read", s.value),
                             series: .value("Direction", "read"))
                        .foregroundStyle(.cyan)
                        .interpolationMethod(.monotone)
                }
                ForEach(monitor.diskWrite) { s in
                    LineMark(x: .value("Time", s.time), y: .value("Write", s.value),
                             series: .value("Direction", "write"))
                        .foregroundStyle(.pink)
                        .interpolationMethod(.monotone)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(Format.rate(v)).font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 70)

            if let space = monitor.diskSpace {
                HStack(spacing: 8) {
                    ProgressView(value: space.usedFraction)
                        .tint(space.usedFraction > 0.9 ? .red : space.usedFraction > 0.8 ? .orange : .accentColor)
                    Text("\(Format.storage(space.available)) free of \(Format.storage(space.total))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .help(space.name)
            }
        }
    }

    // MARK: Battery

    private func batterySection(_ battery: BatteryInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Battery", systemImage: battery.symbolName)
                    .font(.headline)
                Spacer()
                Text(batteryStatus(battery))
                    .foregroundStyle(.secondary)
                Text("\(battery.percent)%")
                    .foregroundStyle(batteryColor(battery))
            }
            .font(.callout.monospacedDigit())

            ProgressView(value: Double(battery.percent), total: 100)
                .tint(batteryColor(battery))
        }
    }

    private func batteryStatus(_ b: BatteryInfo) -> String {
        if b.isCharging {
            return b.minutesRemaining.map { "Charging · \(Format.duration(minutes: $0))" } ?? "Charging"
        }
        if b.isPluggedIn {
            return b.isCharged ? "Charged" : "Plugged in"
        }
        return b.minutesRemaining.map { "\(Format.duration(minutes: $0)) left" } ?? "On battery"
    }

    private func batteryColor(_ b: BatteryInfo) -> Color {
        if b.isCharging || b.isPluggedIn { return .green }
        if b.percent <= 10 { return .red }
        if b.percent <= 20 { return .orange }
        return .primary
    }

    // MARK: Temperature

    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Temperature", systemImage: "thermometer.medium")
                    .font(.headline)
                Spacer()
                Text("CPU \(Format.temperature(monitor.currentTemperature))")
                    .foregroundStyle(.red)
                Text("GPU \(Format.temperature(monitor.currentGPUTemperature))")
                    .foregroundStyle(.mint)
            }
            .font(.callout.monospacedDigit())

            if monitor.temperature.isEmpty && monitor.gpuTemperature.isEmpty {
                Text("No sensor reading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                Chart {
                    ForEach(monitor.temperature) { s in
                        LineMark(x: .value("Time", s.time), y: .value("°C", s.value),
                                 series: .value("Chip", "CPU"))
                            .foregroundStyle(.red)
                            .interpolationMethod(.monotone)
                    }
                    ForEach(monitor.gpuTemperature) { s in
                        LineMark(x: .value("Time", s.time), y: .value("°C", s.value),
                                 series: .value("Chip", "GPU"))
                            .foregroundStyle(.mint)
                            .interpolationMethod(.monotone)
                    }
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text("\(Int(v))°").font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 70)
            }
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
