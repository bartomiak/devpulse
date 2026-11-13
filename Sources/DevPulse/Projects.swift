import AppKit
import Foundation

/// A recognized framework or service behind a listening port.
enum Framework: String, Sendable {
    // JavaScript / TypeScript
    case nuxt, next, sveltekit, astro, remix, angular, nest, vite, vue, react, express, fastify, node
    // Other languages
    case django, flask, fastapi, rails, laravel, go, rust
    // Services
    case postgres, mysql, redis, mongodb, nginx, docker

    var displayName: String {
        switch self {
        case .nuxt: return "Nuxt"
        case .next: return "Next.js"
        case .sveltekit: return "SvelteKit"
        case .astro: return "Astro"
        case .remix: return "Remix"
        case .angular: return "Angular"
        case .nest: return "NestJS"
        case .vite: return "Vite"
        case .vue: return "Vue"
        case .react: return "React"
        case .express: return "Express"
        case .fastify: return "Fastify"
        case .node: return "Node.js"
        case .django: return "Django"
        case .flask: return "Flask"
        case .fastapi: return "FastAPI"
        case .rails: return "Rails"
        case .laravel: return "Laravel"
        case .go: return "Go"
        case .rust: return "Rust"
        case .postgres: return "PostgreSQL"
        case .mysql: return "MySQL"
        case .redis: return "Redis"
        case .mongodb: return "MongoDB"
        case .nginx: return "nginx"
        case .docker: return "Docker"
        }
    }
}

/// The project a process is running from.
struct ProjectInfo: Sendable {
    let name: String
    let framework: Framework?
    /// Project root (where package.json, Gemfile… lives).
    let root: String
}

enum ProjectDetector {
    private static var cache: [String: ProjectInfo] = [:]
    private static var misses: Set<String> = []
    private static let lock = NSLock()

    /// Detects the project for a process working directory by walking up to the nearest
    /// project marker (package.json, Gemfile, manage.py…), staying inside the home folder.
    static func detect(directory: String) -> ProjectInfo? {
        lock.lock()
        if let cached = cache[directory] { lock.unlock(); return cached }
        if misses.contains(directory) { lock.unlock(); return nil }
        lock.unlock()

        let result = scan(from: directory)

        lock.lock()
        if let result { cache[directory] = result } else { misses.insert(directory) }
        lock.unlock()
        return result
    }

    /// Well-known services, recognized by process name.
    static func service(forProcess name: String) -> Framework? {
        switch name {
        case "postgres", "postmaster": return .postgres
        case "mysqld", "mariadbd": return .mysql
        case "redis-server": return .redis
        case "mongod": return .mongodb
        case "nginx": return .nginx
        case "com.docker.backend", "com.docke", "docker-proxy", "vpnkit-bridge": return .docker
        default: return nil
        }
    }

    // MARK: - Scanning

    private static func scan(from directory: String) -> ProjectInfo? {
        let home = NSHomeDirectory()
        var url = URL(fileURLWithPath: directory)

        for _ in 0..<5 {
            let path = url.path
            guard path.hasPrefix(home), path != home else { return nil }
            if let info = inspect(url) { return info }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func inspect(_ dir: URL) -> ProjectInfo? {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        func text(_ name: String) -> String {
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        let folderName = dir.lastPathComponent

        if exists("package.json") {
            return packageJSON(at: dir.appendingPathComponent("package.json"), fallbackName: folderName)
        }
        if exists("manage.py") {
            return ProjectInfo(name: folderName, framework: .django, root: dir.path)
        }
        if exists("artisan") {
            return ProjectInfo(name: folderName, framework: .laravel, root: dir.path)
        }
        if exists("Gemfile") {
            let gemfile = text("Gemfile")
            return ProjectInfo(name: folderName, framework: gemfile.contains("rails") ? .rails : nil, root: dir.path)
        }
        if exists("go.mod") {
            return ProjectInfo(name: folderName, framework: .go, root: dir.path)
        }
        if exists("Cargo.toml") {
            return ProjectInfo(name: folderName, framework: .rust, root: dir.path)
        }
        if exists("pyproject.toml") || exists("requirements.txt") {
            let deps = (text("pyproject.toml") + text("requirements.txt")).lowercased()
            let framework: Framework? = deps.contains("fastapi") ? .fastapi
                : deps.contains("flask") ? .flask
                : deps.contains("django") ? .django
                : nil
            return ProjectInfo(name: folderName, framework: framework, root: dir.path)
        }
        return nil
    }

    private static func packageJSON(at url: URL, fallbackName: String) -> ProjectInfo {
        let root = url.deletingLastPathComponent().path
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ProjectInfo(name: fallbackName, framework: .node, root: root)
        }

        var deps = Set<String>()
        for key in ["dependencies", "devDependencies"] {
            if let section = json[key] as? [String: Any] { deps.formUnion(section.keys) }
        }

        // Most specific first: meta-frameworks bundle Vite/React/Vue themselves.
        let rules: [(String, Framework)] = [
            ("nuxt", .nuxt), ("next", .next), ("@sveltejs/kit", .sveltekit), ("astro", .astro),
            ("@remix-run/dev", .remix), ("@angular/core", .angular), ("@nestjs/core", .nest),
            ("vite", .vite), ("vue", .vue), ("react-scripts", .react), ("react", .react),
            ("fastify", .fastify), ("express", .express),
        ]
        let framework = rules.first { deps.contains($0.0) }?.1 ?? .node

        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        return ProjectInfo(name: name, framework: framework, root: root)
    }
}

// MARK: - Opening projects

/// The user's code editor – first installed one wins.
enum Editor {
    private static let candidates: [(bundleID: String, name: String)] = [
        ("com.microsoft.VSCode", "VS Code"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.microsoft.VSCodeInsiders", "VS Code Insiders"),
        ("dev.zed.Zed", "Zed"),
        ("com.sublimetext.4", "Sublime Text"),
    ]

    static let preferred: (url: URL, name: String)? = {
        for candidate in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate.bundleID) {
                return (url, candidate.name)
            }
        }
        return nil
    }()

    static func open(_ path: String) {
        let folder = URL(fileURLWithPath: path)
        if let editor = preferred {
            NSWorkspace.shared.open([folder], withApplicationAt: editor.url,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func openInTerminal(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
