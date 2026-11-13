# SysMonitor

A lightweight, native macOS menu bar app (SwiftUI + Swift Charts) that shows live system stats.

**In the menu bar:** network ↓/↑, CPU load and temperature, memory, GPU temperature, battery.

**In the popover:**

- **Charts**: network, CPU, memory and CPU/GPU temperature for the last 60 seconds, plus fan speeds and battery status
- **Processes**: the top 10 processes by CPU or memory, with a (confirmed) terminate button
- **Ports**: every listening TCP port with its process and working directory, so you can tell which project a `node` server belongs to. Click a port to open `http://localhost:<port>`, kill stale dev servers, and spot services exposed to the local network (🌐)

## Requirements

- macOS 13 Ventura or later
- Swift 5.9+ (the Xcode Command Line Tools are enough, full Xcode is not required)
- **Intel Mac** for temperatures and fan speeds. These are read from the SMC using Intel key names. Everything else works on Apple Silicon too.

## Build & run

```bash
./run.sh              # debug build + (re)start the app
./build.sh release    # release build → build/SysMonitor.app
```

In VS Code, `⇧⌘B` runs the **Build & Run** task.

To install it, copy the app to `/Applications` and add it under
*System Settings → General → Login Items* to start it at login:

```bash
./build.sh release && cp -R build/SysMonitor.app /Applications/
```

## Project structure

| File | Purpose |
|---|---|
| `Sources/SysMonitor/SysMonitorApp.swift` | `MenuBarExtra` and the menu bar label |
| `Sources/SysMonitor/ContentView.swift` | Popover with tabs and charts |
| `Sources/SysMonitor/Monitor.swift` | 1 s sampling loop, history, formatting |
| `Sources/SysMonitor/Sensors.swift` | CPU, network, memory, battery and temperature readers |
| `Sources/SysMonitor/Fans.swift` | Fan speeds (SMC) |
| `Sources/SysMonitor/Processes.swift` | Top processes (`ps`), listening ports (`lsof`), terminating processes |
| `Sources/SysMonitor/ProcessViews.swift` | Processes and Ports tabs |
| `Sources/CSMC/` | AppleSMC access, written in C |

## How it works

- **CPU**: `host_statistics(HOST_CPU_LOAD_INFO)` tick deltas
- **Network**: 64-bit interface counters via `sysctl(NET_RT_IFLIST2)`, summed over `en*` interfaces
- **Memory**: `host_statistics64(HOST_VM_INFO64)`, computed like Activity Monitor (app + wired + compressed)
- **Battery**: IOKit power sources (`IOPSCopyPowerSourcesInfo`)
- **Temperatures and fans**: AppleSMC via `IOConnectCallStructMethod`
- **Processes and ports**: `ps` and `lsof`, polled only while the popover is open

## License

MIT, see [LICENSE](LICENSE).
