import AppKit
import SwiftUI

// MARK: - Tab: Processes

struct ProcessesView: View {
    @ObservedObject var processMonitor: ProcessMonitor
    @AppStorage("processSort") private var sort: ProcessSort = .cpu

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Top processes", systemImage: "list.number")
                    .font(.headline)
                Spacer()
                Picker("Sort by", selection: $sort) {
                    Text("CPU").tag(ProcessSort.cpu)
                    Text("Memory").tag(ProcessSort.memory)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }

            if processMonitor.processes.isEmpty {
                placeholder("Loading processes…")
            } else {
                VStack(spacing: 2) {
                    ForEach(processMonitor.top(by: sort, limit: 10)) { process in
                        ProcessRow(process: process, sort: sort) {
                            processMonitor.terminate(pid: process.pid)
                        }
                    }
                }
            }
        }
    }
}

private struct ProcessRow: View {
    let process: ProcessEntry
    let sort: ProcessSort
    let onTerminate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(pid: process.pid)

            Text(process.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("\(process.name) (PID \(process.pid))")

            Spacer(minLength: 4)

            Text(String(format: "%.0f%%", process.cpu))
                .foregroundStyle(sort == .cpu ? .orange : .secondary)
                .frame(width: 42, alignment: .trailing)
            Text(Format.memory(process.memory))
                .foregroundStyle(sort == .memory ? .purple : .secondary)
                .frame(width: 62, alignment: .trailing)

            if process.isOwn {
                KillButton(action: onTerminate)
            } else {
                // System / other users' processes – no permission
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .frame(width: 22)
                    .help("System process – can't be terminated without administrator privileges")
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.vertical, 3)
    }
}

// MARK: - Tab: Ports

struct PortsView: View {
    @ObservedObject var processMonitor: ProcessMonitor
    @AppStorage("showSystemPorts") private var showSystem = false

    private var ports: [ListeningPort] {
        processMonitor.ports.filter { showSystem || !$0.isSystem }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Listening ports", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)

            if ports.isEmpty {
                placeholder("Nothing is listening")
            } else {
                VStack(spacing: 2) {
                    ForEach(ports) { port in
                        PortRow(port: port) {
                            processMonitor.terminate(pid: port.pid)
                        }
                    }
                }
            }

            Toggle("Show system services", isOn: $showSystem)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PortRow: View {
    let port: ListeningPort
    let onTerminate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if let url = URL(string: "http://localhost:\(port.port)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                // String(...) – otherwise some locales insert a grouping separator: ":5 432"
                Text(verbatim: ":" + String(port.port))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .frame(width: 56, alignment: .leading)
            }
            .buttonStyle(.link)
            .help("Open http://localhost:\(port.port)")

            VStack(alignment: .leading, spacing: 1) {
                Text(port.processName)
                    .font(.callout)
                    .lineLimit(1)
                if let directory = port.directory {
                    Text(directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 4)

            if port.isExposed {
                Image(systemName: "globe")
                    .foregroundStyle(.orange)
                    .help("Reachable from the local network (listening on all interfaces)")
            }

            KillButton(action: onTerminate)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Shared

/// Terminate button with confirmation: the first click arms it, the second one kills.
/// Disarms itself after 3 s – protects against accidental clicks.
private struct KillButton: View {
    let action: () -> Void
    @State private var armed = false

    var body: some View {
        Button {
            if armed {
                armed = false
                action()
            } else {
                armed = true
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    armed = false
                }
            }
        } label: {
            if armed {
                Text("Quit?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.red))
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
        }
        .buttonStyle(.plain)
        .help(armed ? "Click again to terminate" : "Terminate process")
    }
}

private struct AppIcon: View {
    let pid: Int32

    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "gearshape")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }
}

private func placeholder(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 60)
}
