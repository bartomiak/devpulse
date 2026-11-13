import CSMC
import Darwin
import Foundation
import IOKit.ps

// MARK: - CPU

/// Total CPU load (all cores), computed from the tick delta between samples.
struct CPUSampler {
    private let host = mach_host_self()
    private var previous: host_cpu_load_info?

    /// Returns load in % (0–100). The first call returns nil (no baseline yet).
    mutating func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { previous = info }
        guard let prev = previous else { return nil }

        let user   = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle   = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice   = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return (user + system + nice) / total * 100
    }
}

// MARK: - Network

/// Network throughput (bytes/s) summed over physical `en*` interfaces (Wi-Fi, Ethernet).
struct NetworkSampler {
    struct Rate {
        let down: Double
        let up: Double
    }

    private var previous: (rx: UInt64, tx: UInt64, time: TimeInterval)?

    mutating func sample() -> Rate? {
        guard let counters = Self.readCounters() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previous = (counters.rx, counters.tx, now) }
        guard let prev = previous, now > prev.time else { return nil }

        let dt = now - prev.time
        // Counters may reset (e.g. an interface goes away) – report 0 instead of garbage.
        let down = counters.rx >= prev.rx ? Double(counters.rx - prev.rx) / dt : 0
        let up   = counters.tx >= prev.tx ? Double(counters.tx - prev.tx) / dt : 0
        return Rate(down: down, up: up)
    }

    /// 64-bit counters from sysctl NET_RT_IFLIST2 (getifaddrs only has 32-bit ones, which wrap around).
    private static func readCounters() -> (rx: UInt64, tx: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var rx: UInt64 = 0
        var tx: UInt64 = 0

        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }

                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if msg.ifm_flags & IFF_LOOPBACK == 0, isPhysical(index: msg.ifm_index) {
                        rx += msg.ifm_data.ifi_ibytes
                        tx += msg.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (rx, tx)
    }

    private static func isPhysical(index: UInt16) -> Bool {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &name) != nil else { return false }
        return String(cString: name).hasPrefix("en")
    }
}

// MARK: - Memory

/// Used memory, computed like Activity Monitor: app memory + wired + compressed.
struct MemorySampler {
    struct Usage {
        let used: UInt64
        let total: UInt64
        var percent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
    }

    private let host = mach_host_self()

    func sample() -> Usage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeable ? internalPages - purgeable : 0
        let usedPages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)

        return Usage(used: usedPages * pageSize, total: ProcessInfo.processInfo.physicalMemory)
    }
}

// MARK: - Battery

struct BatteryInfo {
    let percent: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    let isCharged: Bool
    /// Minutes until full (charging) or until empty (on battery). nil = the system is still estimating.
    let minutesRemaining: Int?
}

enum BatteryReader {
    /// Returns nil on Macs without a battery (iMac, Mac mini…).
    static func read() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let charged = desc[kIOPSIsChargedKey] as? Bool ?? false
            let pluggedIn = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let timeKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (desc[timeKey] as? Int).flatMap { $0 > 0 ? $0 : nil }

            return BatteryInfo(
                percent: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current,
                isCharging: charging,
                isPluggedIn: pluggedIn,
                isCharged: charged,
                minutesRemaining: pluggedIn && !charging ? nil : minutes
            )
        }
        return nil
    }
}

// MARK: - Temperature

/// Temperature from the SMC. Picks the first key that works and remembers it.
struct TemperatureSampler {
    /// CPU. Intel: PECI/die → proximity. Then Apple Silicon (M1–M3) performance-core keys.
    static let cpuKeys = ["TCXC", "TC0F", "TC0E", "TC0D", "TC0P", "TC0H", "TC1C",
                          "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0b"]
    /// GPU. Intel: proximity → discrete GPU die (TGDD drops when the dGPU is asleep).
    /// Then Apple Silicon GPU keys.
    static let gpuKeys = ["TG0P", "TG1P", "TG0D", "TGDD",
                          "Tg05", "Tg0D", "Tg0f", "Tg0j", "Tg0L"]

    private let candidates: [String]
    private(set) var activeKey: String?

    init(keys: [String]) {
        candidates = keys
    }

    mutating func sample() -> Double? {
        if let key = activeKey {
            let value = smc_read_temperature(key)
            if Self.isValid(value) { return value }
            activeKey = nil
        }
        for key in candidates {
            let value = smc_read_temperature(key)
            if Self.isValid(value) {
                activeKey = key
                return value
            }
        }
        return nil
    }

    private static func isValid(_ value: Double) -> Bool {
        value > 1 && value < 130
    }
}
