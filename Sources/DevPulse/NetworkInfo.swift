import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import SwiftUI
import SystemConfiguration

// MARK: - Model

struct WiFiDetails: Sendable {
    /// Network name – only available with Location Services permission (macOS 14+).
    let ssid: String?
    let rssi: Int
    let transmitRate: Double
    let channel: Int
    let band: String?

    var quality: String {
        switch rssi {
        case (-60)...: return "Excellent"
        case (-67)...: return "Good"
        case (-75)...: return "Fair"
        default:       return "Weak"
        }
    }

    var qualityColor: Color {
        switch rssi {
        case (-67)...: return .green
        case (-75)...: return .orange
        default:       return .red
        }
    }
}

struct ConnectionSnapshot: Sendable {
    let interface: String?
    let localIP: String?
    let router: String?
    let wifi: WiFiDetails?
    /// Round-trip time to 1.1.1.1 in ms (nil = no reply).
    let ping: Double?

    var isWiFi: Bool { wifi != nil }
}

/// Connection details for the Charts tab: Wi-Fi, IP addresses and latency.
/// Refreshed every 5 s while the popover is open; the public IP is only fetched on request.
@MainActor
final class NetworkInfoModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var snapshot: ConnectionSnapshot?
    @Published private(set) var publicIP: String?
    @Published private(set) var isFetchingPublicIP = false
    @Published private(set) var locationStatus: CLAuthorizationStatus

    nonisolated static let pingHost = "1.1.1.1"

    private let locationManager = CLLocationManager()
    private var task: Task<Void, Never>?
    private var isRefreshing = false

    override init() {
        locationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self

        task = Task { [weak self] in
            while !Task.isCancelled {
                if NSApplication.shared.keyWindow != nil {
                    await self?.refresh()
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    deinit {
        task?.cancel()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        snapshot = await Task.detached(priority: .utility) { NetworkInfoReader.read() }.value
    }

    func fetchPublicIP() {
        guard !isFetchingPublicIP else { return }
        isFetchingPublicIP = true
        Task {
            defer { isFetchingPublicIP = false }
            var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
            request.timeoutInterval = 5
            if let (data, _) = try? await URLSession.shared.data(for: request) {
                let ip = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                publicIP = ip.isEmpty ? nil : ip
            }
        }
    }

    // MARK: Wi-Fi name permission

    var canRequestWiFiName: Bool { locationStatus == .notDetermined }
    var isWiFiNameDenied: Bool { locationStatus == .denied || locationStatus == .restricted }

    func requestWiFiName() {
        if canRequestWiFiName {
            locationManager.requestWhenInUseAuthorization()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            locationStatus = status
            await refresh()
        }
    }
}

// MARK: - Reading

enum NetworkInfoReader {
    static func read() -> ConnectionSnapshot {
        let global = primaryIPv4()
        let interface = global.interface
        let wifiInterface = CWWiFiClient.shared().interface()

        var wifi: WiFiDetails?
        if let wifiInterface, wifiInterface.interfaceName == interface, wifiInterface.powerOn() {
            let channel = wifiInterface.wlanChannel()
            wifi = WiFiDetails(
                ssid: wifiInterface.ssid(),
                rssi: wifiInterface.rssiValue(),
                transmitRate: wifiInterface.transmitRate(),
                channel: channel?.channelNumber ?? 0,
                band: channel.map { bandName($0.channelBand) } ?? nil
            )
        }

        return ConnectionSnapshot(
            interface: interface,
            localIP: interface.flatMap(ipv4Address(of:)),
            router: global.router,
            wifi: wifi,
            ping: interface == nil ? nil : ping(NetworkInfoModel.pingHost)
        )
    }

    /// Primary interface and router from the System Configuration dynamic store.
    private static func primaryIPv4() -> (interface: String?, router: String?) {
        guard let store = SCDynamicStoreCreate(nil, "DevPulse" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return (nil, nil) }
        return (global["PrimaryInterface"] as? String, global["Router"] as? String)
    }

    private static func ipv4Address(of interface: String) -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name) == interface
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    /// One ICMP echo with a 2 s timeout, parsed from `ping` output ("time=16.1 ms").
    private static func ping(_ host: String) -> Double? {
        guard let output = Shell.run("/sbin/ping", ["-c", "1", "-t", "2", host]),
              let range = output.range(of: "time=")
        else { return nil }
        let value = output[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(value)
    }

    private static func bandName(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        default: return nil
        }
    }
}

// MARK: - View

/// Compact connection details shown under the network chart.
struct NetworkInfoView: View {
    @ObservedObject var model: NetworkInfoModel

    var body: some View {
        if let snapshot = model.snapshot {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                if let wifi = snapshot.wifi {
                    GridRow {
                        label("Wi-Fi")
                        wifiName(wifi)
                    }
                    GridRow {
                        label("Signal")
                        HStack(spacing: 4) {
                            Text(verbatim: "\(wifi.quality) (\(wifi.rssi) dBm)")
                                .foregroundStyle(wifi.qualityColor)
                            Text(verbatim: wifiDetails(wifi))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let interface = snapshot.interface {
                    GridRow {
                        label("Interface")
                        Text(verbatim: interface)
                    }
                } else {
                    GridRow {
                        label("Status")
                        Text("Offline").foregroundStyle(.red)
                    }
                }

                GridRow {
                    label("Local IP")
                    CopyableText(snapshot.localIP ?? "—")
                }

                GridRow {
                    label("Public IP")
                    if let ip = model.publicIP {
                        CopyableText(ip)
                    } else if model.isFetchingPublicIP {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("Show") { model.fetchPublicIP() }
                            .buttonStyle(.link)
                            .help("Looks up your public IP via api.ipify.org")
                    }
                }

                GridRow {
                    label("Ping")
                    if let ping = snapshot.ping {
                        HStack(spacing: 6) {
                            Text(verbatim: String(format: "%.0f ms", ping))
                                .foregroundStyle(ping < 50 ? .green : ping < 150 ? .orange : .red)
                            Text(verbatim: NetworkInfoModel.pingHost)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("No reply").foregroundStyle(.red)
                    }
                }
            }
            .font(.caption.monospacedDigit())
        }
    }

    @ViewBuilder
    private func wifiName(_ wifi: WiFiDetails) -> some View {
        if let ssid = wifi.ssid {
            Text(verbatim: ssid).lineLimit(1)
        } else {
            Button(model.isWiFiNameDenied ? "Allow Location to show name" : "Show name") {
                model.requestWiFiName()
            }
            .buttonStyle(.link)
            .help("macOS only reveals the Wi-Fi name to apps with Location Services access")
        }
    }

    private func wifiDetails(_ wifi: WiFiDetails) -> String {
        var parts: [String] = []
        if let band = wifi.band { parts.append(band) }
        if wifi.channel > 0 { parts.append("ch \(wifi.channel)") }
        if wifi.transmitRate > 0 { parts.append(String(format: "%.0f Mb/s", wifi.transmitRate)) }
        return parts.joined(separator: " · ")
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
            .frame(width: 58, alignment: .leading)
    }
}

/// Text that copies itself to the clipboard on click.
struct CopyableText: View {
    let text: String
    @State private var copied = false

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: text)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(copied ? .green : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Copy")
    }
}
