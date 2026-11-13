import CSMC

struct Fan: Identifiable {
    let id: Int
    let rpm: Double
    let minRPM: Double
    let maxRPM: Double

    /// 0–1 relative to the maximum speed.
    var fraction: Double {
        maxRPM > 0 ? Swift.min(Swift.max(rpm / maxRPM, 0), 1) : 0
    }
}

/// Fan speeds from the SMC (keys FNum, F<n>Ac/Mn/Mx).
enum FanReader {
    static func read() -> [Fan] {
        let count = smc_read_value("FNum")
        guard !count.isNaN, count > 0 else { return [] }

        return (0..<Int(count)).compactMap { i in
            let rpm = smc_read_value("F\(i)Ac")
            guard !rpm.isNaN else { return nil }
            let minRPM = smc_read_value("F\(i)Mn")
            let maxRPM = smc_read_value("F\(i)Mx")
            return Fan(
                id: i,
                rpm: rpm,
                minRPM: minRPM.isNaN ? 0 : minRPM,
                maxRPM: maxRPM.isNaN ? 0 : maxRPM
            )
        }
    }
}
