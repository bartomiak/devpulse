import CSMC
import Foundation

/// Picks the right temperature source for the current Mac.
///
/// - **Apple Silicon**: IOHIDEventSystem sensors (pACC/eACC = CPU cores, GPU = graphics),
///   falling back to the Apple Silicon SMC keys.
/// - **Intel**: SMC keys (TCXC, TC0P, TG0P…).
struct ThermalReader {
    struct Reading {
        let cpu: Double?
        let gpu: Double?
    }

    private var cpuSMC = TemperatureSampler(keys: TemperatureSampler.cpuKeys)
    private var gpuSMC = TemperatureSampler(keys: TemperatureSampler.gpuKeys)

    mutating func sample() -> Reading {
        #if arch(arm64)
        let hid = HIDThermal.read()
        if hid.cpu != nil || hid.gpu != nil {
            return Reading(cpu: hid.cpu ?? cpuSMC.sample(), gpu: hid.gpu ?? gpuSMC.sample())
        }
        #endif
        return Reading(cpu: cpuSMC.sample(), gpu: gpuSMC.sample())
    }
}

/// Apple Silicon temperatures from IOHIDEventSystem sensors.
///
/// Sensor names vary between chip generations, for example:
/// - "pACC MTR Temp Sensor3" / "eACC MTR Temp Sensor0": performance and efficiency CPU cores
/// - "GPU MTR Temp Sensor1": GPU
/// - "PMU tdie1" / "SOC MTR Temp Sensor0": die or SoC sensors (used when the core sensors are missing)
enum HIDThermal {
    static func read() -> ThermalReader.Reading {
        let sensors = readAll()
        guard !sensors.isEmpty else { return .init(cpu: nil, gpu: nil) }

        let cpuCores = sensors.filter { $0.name.contains("pACC") || $0.name.contains("eACC") }
        let gpu = sensors.filter { $0.name.contains("GPU") }
        let die = sensors.filter { $0.name.contains("tdie") || $0.name.contains("SOC") }

        return .init(
            cpu: average(cpuCores.isEmpty ? die : cpuCores),
            gpu: average(gpu)
        )
    }

    /// All sensors with a plausible reading – handy for debugging new chips.
    static func readAll() -> [(name: String, celsius: Double)] {
        var buffer = [hid_temperature_t](repeating: hid_temperature_t(), count: 128)
        let count = Int(hid_read_temperatures(&buffer, Int32(buffer.count)))

        return buffer.prefix(count).compactMap { entry in
            var entry = entry
            let name = withUnsafeBytes(of: &entry.name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard entry.celsius > 1, entry.celsius < 130 else { return nil }
            return (name, entry.celsius)
        }
    }

    private static func average(_ sensors: [(name: String, celsius: Double)]) -> Double? {
        guard !sensors.isEmpty else { return nil }
        return sensors.map(\.celsius).reduce(0, +) / Double(sensors.count)
    }
}

/// Diagnostic output for `DevPulse --sensors`.
enum SensorReport {
    static func print() {
        #if arch(arm64)
        let arch = "arm64 (Apple Silicon)"
        #else
        let arch = "x86_64 (Intel)"
        #endif
        Swift.print("DevPulse sensor report – \(arch)\n")

        Swift.print("HID temperature sensors:")
        let hid = HIDThermal.readAll()
        if hid.isEmpty { Swift.print("  (none)") }
        for sensor in hid.sorted(by: { $0.name < $1.name }) {
            Swift.print(String(format: "  %-36@ %6.1f °C", sensor.name as NSString, sensor.celsius))
        }

        Swift.print("\nSMC temperature keys:")
        for key in TemperatureSampler.cpuKeys + TemperatureSampler.gpuKeys {
            let value = smc_read_value(key)
            if !value.isNaN { Swift.print(String(format: "  %@  %6.1f", key as NSString, value)) }
        }

        Swift.print("\nFans:")
        let fans = FanReader.read()
        if fans.isEmpty { Swift.print("  (none)") }
        for fan in fans {
            Swift.print("  #\(fan.id + 1): \(Int(fan.rpm)) RPM (min \(Int(fan.minRPM)), max \(Int(fan.maxRPM)))")
        }

        var reader = ThermalReader()
        let reading = reader.sample()
        Swift.print("\nDevPulse would show: CPU \(Format.temperature(reading.cpu)), GPU \(Format.temperature(reading.gpu))")
    }
}
