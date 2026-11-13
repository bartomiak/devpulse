import AppKit
import Darwin
import Foundation

// MARK: - Models

struct ProcessEntry: Identifiable, Sendable {
    let pid: Int32
    let name: String
    let cpu: Double          // % of a single core (can exceed 100)
    let memory: UInt64       // bytes (RSS)
    let isOwn: Bool          // owned by the current user – only these can be terminated

    var id: Int32 { pid }
}

struct ListeningPort: Identifiable, Sendable {
    let pid: Int32
    let port: Int
    let processName: String
    /// The process working directory, e.g. "~/dev/my-app" – tells you which project it is.
    let directory: String?
    /// Listens on all interfaces (reachable from the network), not just localhost.
    var isExposed: Bool
    let isSystem: Bool

    var id: String { "\(pid)-\(port)" }
}

enum ProcessSort: String, CaseIterable {
    case cpu, memory
}

// MARK: - Process & port monitor

/// Refreshes processes and ports every 3 s, but only while the popover is open
/// (`ps` and `lsof` cost some CPU, and nobody is looking at it in the background).
@MainActor
final class ProcessMonitor: ObservableObject {
    @Published private(set) var processes: [ProcessEntry] = []
    @Published private(set) var ports: [ListeningPort] = []

    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var isRefreshing = false

    init() {
        // Fresh data as soon as the popover opens
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }

        task = Task { [weak self] in
            while !Task.isCancelled {
                if NSApplication.shared.keyWindow != nil {
                    await self?.refresh()
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    deinit {
        task?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let procs = Task.detached(priority: .utility) { ProcessReader.read() }.value
        async let listening = Task.detached(priority: .utility) { PortReader.read() }.value
        processes = await procs
        ports = await listening
    }

    func top(by sort: ProcessSort, limit: Int) -> [ProcessEntry] {
        let sorted: [ProcessEntry]
        switch sort {
        case .cpu:    sorted = processes.sorted { $0.cpu > $1.cpu }
        case .memory: sorted = processes.sorted { $0.memory > $1.memory }
        }
        return Array(sorted.prefix(limit))
    }

    /// GUI apps are quit gracefully (like ⌘Q – they may ask to save).
    /// Other processes get SIGTERM, then SIGKILL if they're still alive after 1.5 s.
    func terminate(pid: Int32) {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited {
            app.terminate()
        } else {
            guard kill(pid, SIGTERM) == 0 else {
                NSSound.beep()
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                await refresh()
            }
            return
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await refresh()
        }
    }
}

// MARK: - Reading processes (ps)

enum ProcessReader {
    static func read() -> [ProcessEntry] {
        guard let output = Shell.run("/bin/ps", ["-Ao", "pid=,uid=,pcpu=,rss=,comm="]) else { return [] }
        let myUID = getuid()
        let myPID = getpid()

        return output.split(separator: "\n").compactMap { line in
            // 4 numeric columns; the rest of the line is the path (may contain spaces)
            var rest = Substring(line)
            var fields: [Substring] = []
            for _ in 0..<4 {
                rest = rest.drop(while: { $0 == " " })
                guard let end = rest.firstIndex(of: " ") else { return nil }
                fields.append(rest[..<end])
                rest = rest[end...]
            }
            guard let pid = Int32(fields[0]),
                  let uid = UInt32(fields[1]),
                  let cpu = Double(fields[2]),
                  let rssKB = UInt64(fields[3]),
                  pid != myPID
            else { return nil }

            let path = rest.trimmingCharacters(in: .whitespaces)
            return ProcessEntry(
                pid: pid,
                name: (path as NSString).lastPathComponent,
                cpu: cpu,
                memory: rssKB * 1024,
                isOwn: uid == myUID
            )
        }
    }
}

// MARK: - Reading ports (lsof)

enum PortReader {
    /// macOS services that always listen (AirPlay, Handoff…) – hidden by default.
    static let systemProcesses: Set<String> = [
        "ControlCenter", "rapportd", "sharingd", "identityservicesd",
        "AirPlayXPCHelper", "remoted", "WiFiAgent", "UserEventAgent",
    ]

    static func read() -> [ListeningPort] {
        // -F pcn: machine-readable output – p=pid, c=command, n=address:port
        guard let output = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]) else {
            return []
        }

        var result: [String: ListeningPort] = [:]
        var pid: Int32 = 0
        var command = ""

        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()

            switch tag {
            case "p":
                pid = Int32(value) ?? 0
            case "c":
                command = String(value)
            case "n":
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...])
                else { continue }
                let host = value[..<colon]
                let exposed = !(host.hasPrefix("127.") || host == "[::1]" || host == "localhost")

                let key = "\(pid)-\(port)"
                if var existing = result[key] {
                    existing.isExposed = existing.isExposed || exposed
                    result[key] = existing
                } else {
                    result[key] = ListeningPort(
                        pid: pid,
                        port: port,
                        processName: command,
                        directory: workingDirectory(of: pid),
                        isExposed: exposed,
                        isSystem: systemProcesses.contains(command)
                    )
                }
            default:
                break
            }
        }
        return result.values.sorted { $0.port < $1.port }
    }

    /// The process working directory (works for the current user's processes).
    static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }

        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let home = NSHomeDirectory()
        guard !path.isEmpty, path != "/", path != home else { return nil }
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Running commands

enum Shell {
    static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // LC_ALL=C – so ps prints "27.5" rather than "27,5" in locales with a decimal comma
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
