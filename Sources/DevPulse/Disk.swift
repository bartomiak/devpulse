import Foundation
import IOKit

/// Disk throughput (bytes/s) summed over all block storage drivers.
struct DiskSampler {
    struct Rate {
        let read: Double
        let write: Double
    }

    private var previous: (read: UInt64, write: UInt64, time: TimeInterval)?

    mutating func sample() -> Rate? {
        guard let counters = Self.readCounters() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previous = (counters.read, counters.write, now) }
        guard let prev = previous, now > prev.time else { return nil }

        let dt = now - prev.time
        // Counters reset when a disk is ejected – report 0 instead of garbage.
        let read  = counters.read  >= prev.read  ? Double(counters.read  - prev.read)  / dt : 0
        let write = counters.write >= prev.write ? Double(counters.write - prev.write) / dt : 0
        return Rate(read: read, write: write)
    }

    /// Cumulative "Bytes (Read)" / "Bytes (Write)" from every IOBlockStorageDriver.
    private static func readCounters() -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, write)
    }
}

/// Free and total space of the startup volume.
struct DiskSpace {
    let name: String
    let available: Int64
    let total: Int64

    var used: Int64 { max(total - available, 0) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func read() -> DiskSpace? {
        // The home folder lives on the data volume, which is what Finder reports as free space.
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }

        return DiskSpace(name: values.volumeName ?? "Disk", available: available, total: Int64(total))
    }
}
