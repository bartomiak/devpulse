import Foundation

struct Sample: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
}

/// Samples every `Pref.interval` seconds (1 s by default) and keeps the last `historyLength` samples.
@MainActor
final class Monitor: ObservableObject {
    static let historyLength = 60

    @Published private(set) var cpu: [Sample] = []
    @Published private(set) var temperature: [Sample] = []
    @Published private(set) var download: [Sample] = []
    @Published private(set) var upload: [Sample] = []
    @Published private(set) var memory: [Sample] = []          // % of RAM used
    @Published private(set) var gpuTemperature: [Sample] = []
    @Published private(set) var memoryUsage: MemorySampler.Usage?
    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var fans: [Fan] = []
    @Published private(set) var diskRead: [Sample] = []
    @Published private(set) var diskWrite: [Sample] = []
    @Published private(set) var diskSpace: DiskSpace?

    var currentCPU: Double? { cpu.last?.value }
    var currentTemperature: Double? { temperature.last?.value }
    var currentGPUTemperature: Double? { gpuTemperature.last?.value }
    var currentDownload: Double? { download.last?.value }
    var currentUpload: Double? { upload.last?.value }
    var currentDiskRead: Double? { diskRead.last?.value }
    var currentDiskWrite: Double? { diskWrite.last?.value }

    private var cpuSampler = CPUSampler()
    private var networkSampler = NetworkSampler()
    private let memorySampler = MemorySampler()
    private var thermalReader = ThermalReader()
    private var diskSampler = DiskSampler()
    private var tickCount = 0
    private var task: Task<Void, Never>?

    init() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                // Read each time, so changes in Settings apply immediately
                try? await Task.sleep(nanoseconds: UInt64(Pref.interval * 1_000_000_000))
            }
        }
    }

    deinit {
        task?.cancel()
    }

    private func tick() {
        let now = Date()

        if let value = cpuSampler.sample() {
            append(&cpu, Sample(time: now, value: value))
        }
        let thermal = thermalReader.sample()
        if let value = thermal.cpu {
            append(&temperature, Sample(time: now, value: value))
        }
        if let value = thermal.gpu {
            append(&gpuTemperature, Sample(time: now, value: value))
        }
        if let rate = networkSampler.sample() {
            append(&download, Sample(time: now, value: rate.down))
            append(&upload, Sample(time: now, value: rate.up))
        }
        if let usage = memorySampler.sample() {
            memoryUsage = usage
            append(&memory, Sample(time: now, value: usage.percent))
        }
        if let rate = diskSampler.sample() {
            append(&diskRead, Sample(time: now, value: rate.read))
            append(&diskWrite, Sample(time: now, value: rate.write))
        }
        fans = FanReader.read()
        // Battery and free space change slowly – every ~5 s is enough
        if tickCount % max(Int(5 / Pref.interval), 1) == 0 {
            battery = BatteryReader.read()
            diskSpace = DiskSpace.read()
        }
        tickCount += 1
    }

    private func append(_ series: inout [Sample], _ sample: Sample) {
        series.append(sample)
        if series.count > Self.historyLength {
            series.removeFirst(series.count - Self.historyLength)
        }
    }
}

extension BatteryInfo {
    /// SF Symbol name matching the battery state.
    var symbolName: String {
        if isCharging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default:    return "battery.100percent"
        }
    }
}

// MARK: - Formatting

enum Format {
    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond else { return "—" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = value
        var i = 0
        while v >= 1000, i < units.count - 1 {
            v /= 1000
            i += 1
        }
        return v < 10 && i > 0
            ? String(format: "%.1f %@", v, units[i])
            : String(format: "%.0f %@", v, units[i])
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value)
    }

    /// Short version for the menu bar, e.g. "1.2M", "340K", "0K".
    static func compactRate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond else { return "—" }
        switch value {
        case 1_000_000_000...: return String(format: "%.1fG", value / 1_000_000_000)
        case 10_000_000...:    return String(format: "%.0fM", value / 1_000_000)
        case 1_000_000...:     return String(format: "%.1fM", value / 1_000_000)
        default:               return String(format: "%.0fK", value / 1_000)
        }
    }

    /// "312 MB" or "1.4 GB"
    static func memory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    /// Disk sizes in decimal units, like Finder: "245 GB", "1.2 TB".
    static func storage(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb >= 1000 ? String(format: "%.1f TB", gb / 1000) : String(format: "%.0f GB", gb)
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    static func duration(minutes: Int) -> String {
        minutes >= 60
            ? String(format: "%d h %02d min", minutes / 60, minutes % 60)
            : "\(minutes) min"
    }

    /// "60 s", "2 min", "5 min"
    static func historySpan(seconds: Double) -> String {
        seconds < 120 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
    }

    /// Short temperature for the menu bar, e.g. "94°".
    static func degrees(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f°", value)
    }

    static func temperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f°C", value)
    }
}
