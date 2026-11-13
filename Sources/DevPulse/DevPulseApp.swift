import AppKit
import SwiftUI

@main
struct DevPulseApp: App {
    @StateObject private var monitor = Monitor()
    @StateObject private var processMonitor = ProcessMonitor()

    init() {
        // `DevPulse --sensors` prints every sensor it can see and exits – useful for bug reports.
        if CommandLine.arguments.contains("--sensors") {
            SensorReport.print()
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor, processMonitor: processMonitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar label.
///
/// The menu bar only shows a single Text or Image from the label, and SF Symbols embedded
/// in text get dropped. So the whole content is rendered into one template image,
/// letting the system pick the right color for a light or dark menu bar.
struct MenuBarLabel: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        Image(nsImage: render())
    }

    @MainActor
    private func render() -> NSImage {
        let renderer = ImageRenderer(content: MenuBarContent(monitor: monitor))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

/// ↓1.2M ↑30K   [cpu] 23% 94°   [ram] 68%   [gpu] 59°   [battery] 100%
private struct MenuBarContent: View {
    let monitor: Monitor

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 1) {
                icon("arrow.down")
                value(Format.compactRate(monitor.currentDownload), width: 36)
                icon("arrow.up")
                value(Format.compactRate(monitor.currentUpload), width: 36)
            }
            HStack(spacing: 3) {
                icon("cpu")
                value(Format.percent(monitor.currentCPU), width: 32)
                value(Format.degrees(monitor.currentTemperature), width: 28)
            }
            HStack(spacing: 3) {
                icon("memorychip")
                value(Format.percent(monitor.memoryUsage?.percent), width: 32)
            }
            HStack(spacing: 3) {
                icon("display")
                value(Format.degrees(monitor.currentGPUTemperature), width: 28)
            }
            if let battery = monitor.battery {
                HStack(spacing: 3) {
                    icon(battery.symbolName)
                    value("\(battery.percent)%", width: 40)
                }
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.black) // template image: only the alpha channel matters
        .frame(height: 18)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .medium))
    }

    /// Fixed width so the menu bar doesn't jump around as the number of digits changes.
    private func value(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }
}
