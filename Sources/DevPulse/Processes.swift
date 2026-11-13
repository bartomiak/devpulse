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
    /// The process working directory (absolute path).
    let directoryPath: String?
    /// The project the process runs from (package.json, Gemfile…), if recognized.
    let project: ProjectInfo?
    /// A well-known service (PostgreSQL, Redis…), recognized by process name.
    let service: Framework?
    /// Listens on all interfaces (reachable from the network), not just localhost.
    var isExposed: Bool
    let isSystem: Bool

    var id: String { "\(pid)-\(port)" }

    var framework: Framework? { project?.framework ?? service }

    /// Path shown under the name, e.g. "~/dev/my-app".
    var directory: String? {
        guard let path = project?.root ?? directoryPath else { return nil }
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var url: URL? { URL(string: "http://localhost:\(port)") }
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
                    let directory = workingDirectory(of: pid)
                    result[key] = ListeningPort(
                        pid: pid,
                        port: port,
                        processName: command,
                        directoryPath: directory,
                        project: directory.flatMap(ProjectDetector.detect(directory:)),
                        service: ProjectDetector.service(forProcess: command),
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

    /// The process working directory as an absolute path (works for the current user's processes).
    static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }

        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        guard !path.isEmpty, path != "/", path != NSHomeDirectory() else { return nil }
        return path
    }
}

// MARK: - Running commands

enum Shell {
    struct Result {
        let output: String
        let status: Int32
        var succeeded: Bool { status == 0 }
    }

    /// Runs a command and returns its standard output (nil if it couldn't be started).
    static func run(_ executable: String, _ arguments: [String],
                    environment: [String: String] = [:]) -> String? {
        execute(executable, arguments, environment: environment)?.output
    }

    /// Runs a command and returns its output and exit status.
    /// With `includeErrors`, standard error is captured too (useful for showing failures).
    static func execute(_ executable: String, _ arguments: [String],
                        environment: [String: String] = [:],
                        includeErrors: Bool = false) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        // LC_ALL=C – so ps prints "27.5" rather than "27,5" in locales with a decimal comma
        env["LC_ALL"] = "C"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.merge(environment) { _, new in new }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = includeErrors ? pipe : FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus)
    }
}
