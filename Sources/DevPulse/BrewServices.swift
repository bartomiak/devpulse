import AppKit
import Foundation
import SwiftUI

// MARK: - Model

struct BrewService: Identifiable, Decodable, Sendable {
    let name: String
    let status: String
    let user: String?
    let file: String?

    var id: String { name }

    var isRunning: Bool { status == "started" || status == "scheduled" }
    var hasError: Bool { status == "error" }

    var statusText: String {
        switch status {
        case "started": return "Running"
        case "scheduled": return "Scheduled"
        case "error": return "Error"
        case "none", "stopped": return "Stopped"
        default: return status.capitalized
        }
    }
}

/// `brew services` – list, start, stop and restart Homebrew-managed services (PostgreSQL, Redis…).
@MainActor
final class BrewServicesModel: ObservableObject {
    enum Action: String {
        case start, stop, restart
    }

    @Published private(set) var services: [BrewService] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var busy: Set<String> = []
    @Published var errorMessage: String?

    private var isRefreshing = false

    static let brewPath: String? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    var isAvailable: Bool { Self.brewPath != nil }

    /// Skip Homebrew's auto-update and analytics – we only want a quick status read.
    nonisolated private static let environment = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_ANALYTICS": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
    ]

    func refresh() async {
        guard let brew = Self.brewPath, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let result = await Task.detached(priority: .utility) {
            Shell.run(brew, ["services", "list", "--json"], environment: Self.environment)
        }.value

        if let data = result?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([BrewService].self, from: data) {
            services = decoded.sorted { $0.name < $1.name }
        }
        hasLoaded = true
    }

    func perform(_ action: Action, on service: BrewService) async {
        guard let brew = Self.brewPath else { return }
        busy.insert(service.name)
        defer { busy.remove(service.name) }

        let result = await Task.detached(priority: .userInitiated) {
            Shell.execute(brew, ["services", action.rawValue, service.name],
                          environment: Self.environment, includeErrors: true)
        }.value

        if let result, !result.succeeded {
            let message = result.output
                .split(separator: "\n")
                .last { $0.contains("Error") } ?? Substring(result.output)
            errorMessage = "\(service.name): \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        } else {
            errorMessage = nil
        }
        await refresh()
    }
}

// MARK: - Tab: Services

struct ServicesView: View {
    @ObservedObject var model: BrewServicesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Homebrew services", systemImage: "shippingbox")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh")
            }

            if !model.isAvailable {
                placeholder("Homebrew isn't installed")
            } else if !model.hasLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if model.services.isEmpty {
                placeholder("No Homebrew services installed")
            } else {
                VStack(spacing: 2) {
                    ForEach(model.services) { service in
                        ServiceRow(service: service, isBusy: model.busy.contains(service.name)) { action in
                            Task { await model.perform(action, on: service) }
                        }
                    }
                }
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        // Poll while the tab is visible; `brew` is slow, so not too often.
        .task {
            while !Task.isCancelled {
                if NSApplication.shared.keyWindow != nil {
                    await model.refresh()
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }
}

private struct ServiceRow: View {
    let service: BrewService
    let isBusy: Bool
    let onAction: (BrewServicesModel.Action) -> Void

    private var statusColor: Color {
        if service.hasError { return .red }
        return service.isRunning ? .green : .secondary
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(service.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(service.statusText)
                    .font(.caption)
                    .foregroundStyle(service.hasError ? .red : .secondary)
            }

            Spacer(minLength: 4)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 60)
            } else if service.isRunning {
                Button("Restart") { onAction(.restart) }
                    .controlSize(.small)
                Button("Stop") { onAction(.stop) }
                    .controlSize(.small)
            } else {
                Button("Start") { onAction(.start) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if let file = service.file {
                Button("Show plist in Finder") { Editor.revealInFinder(file) }
            }
        }
    }
}

private func placeholder(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 60)
}
