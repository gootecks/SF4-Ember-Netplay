import Foundation

public enum DiagnosticsBundle {
    public static let defaultMaxLogBytes = 5 * 1024 * 1024

    public static func isDenied(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("ssfn") || lower.hasSuffix(".vdf") || lower.hasSuffix(".key")
            || lower.hasSuffix(".pem") || lower.hasSuffix(".p12")
        {
            return true
        }
        return ["token", "identity", "secret", "credential", "password", "loginusers", "auth"].contains {
            lower.contains($0)
        }
    }

    public static func create(
        paths: EmberPaths,
        manifest: EngineManifest,
        to destination: URL,
        maxLogBytes: Int = defaultMaxLogBytes
    ) async throws -> URL {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let top = "ember-diagnostics-\(stamp)"
        let work = fm.temporaryDirectory.appending(path: "emberkit-diag-\(UUID().uuidString)", directoryHint: .isDirectory)
        let stage = work.appending(path: top, directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: work) }
        try makeDir(stage)

        var report = Report()
        let collector = Collector(stage: stage, maxBytes: maxLogBytes)

        try collector.gather(
            from: paths.logsDir, matching: { _ in true }, into: "emberkit-logs", label: "EmberKit logs",
            recursive: true, report: &report)

        let prefix = paths.prefixDir
        let emberDir = prefix.appending(path: "drive_c/ember", directoryHint: .isDirectory)
        let isLog: (String) -> Bool = { $0.lowercased().hasSuffix(".log") }
        let wineBefore = report.included.count
        try collector.gather(
            from: emberDir, matching: isLog, into: "wine", label: "Wine/DXVK logs (drive_c/ember)",
            recursive: false, report: &report, reportMissing: false)
        try collector.gather(
            from: emberDir.appending(path: "logs", directoryHint: .isDirectory), matching: isLog,
            into: "wine", label: "Wine/DXVK logs (drive_c/ember/logs)", recursive: false, report: &report,
            reportMissing: false)
        if report.included.count == wineBefore { report.missing.append("Wine/DXVK logs (drive_c/ember/*.log)") }

        try gatherEmberLogs(prefix: prefix, collector: collector, report: &report)

        let steamLogs = prefix.appending(path: "drive_c/Program Files (x86)/Steam/logs", directoryHint: .isDirectory)
        for name in ["connection_log.txt", "steamui_login.txt"] {
            try collector.gatherFile(
                steamLogs.appending(path: name), into: "steam", label: "Steam logs/\(name)", report: &report)
        }

        let manifestData = try encodeManifest(manifest)
        try write(manifestData, to: stage.appending(path: "manifest.json"))
        report.included.append("manifest.json")

        if let marker = try? Data(contentsOf: paths.prefixMarker) {
            try write(marker, to: stage.appending(path: "prefix-marker.txt"))
            report.included.append("prefix-marker.txt")
        } else {
            report.missing.append("prefix marker (\(PrefixMarker.fileName))")
        }

        try write(Data(await systemInfo().utf8), to: stage.appending(path: "system-info.txt"))
        report.included.append("system-info.txt")

        try write(Data(report.render(maxBytes: maxLogBytes).utf8), to: stage.appending(path: "summary.txt"))

        try makeDir(destination.deletingLastPathComponent())
        try? fm.removeItem(at: destination)
        _ = try await ProcessRunner.runChecked("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", stage.path, destination.path])
        return destination
    }

    private static func gatherEmberLogs(prefix: URL, collector: Collector, report: inout Report) throws {
        let fm = FileManager.default
        let users = prefix.appending(path: "drive_c/users", directoryHint: .isDirectory)
        let names = ((try? fm.contentsOfDirectory(atPath: users.path)) ?? []).sorted()
        var found = false
        for user in names {
            let logs = users.appending(path: "\(user)/AppData/Roaming/sf4e/logs", directoryHint: .isDirectory)
            guard fm.fileExists(atPath: logs.path) else { continue }
            found = true
            let matches: (String) -> Bool = {
                let n = $0.lowercased()
                return (n.hasPrefix("sf4e") && n.hasSuffix(".log")) || (n.hasPrefix("session-") && n.hasSuffix(".log"))
                    || n == "launcher.log"
            }
            try collector.gather(
                from: logs, matching: matches, into: "ember/\(user)", label: "Ember logs (\(user))",
                recursive: false, report: &report)
            let present = Set((try? fm.contentsOfDirectory(atPath: logs.path)) ?? [])
            if !present.contains("launcher.log") { report.missing.append("Ember logs (\(user))/launcher.log") }
        }
        if !found { report.missing.append("Ember logs (drive_c/users/*/AppData/Roaming/sf4e/logs)") }
    }

    private static func encodeManifest(_ manifest: EngineManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    private static func systemInfo() async -> String {
        let commands: [(String, String, [String])] = [
            ("sw_vers", "/usr/bin/sw_vers", []),
            ("uname -m", "/usr/bin/uname", ["-m"]),
            ("hw.model", "/usr/sbin/sysctl", ["-n", "hw.model"]),
            ("machdep.cpu.brand_string", "/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]),
            ("hw.memsize", "/usr/sbin/sysctl", ["-n", "hw.memsize"]),
        ]
        var out = ""
        for (label, tool, args) in commands {
            let value: String
            if let result = try? await ProcessRunner.run(tool, args), result.succeeded {
                value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                value = "unavailable"
            }
            out += "== \(label) ==\n\(value)\n\n"
        }
        return out
    }

    private static func makeDir(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw EmberError.fileSystem(path: url.path, reason: error.localizedDescription)
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url)
        } catch {
            throw EmberError.fileSystem(path: url.path, reason: error.localizedDescription)
        }
    }
}

struct Report {
    var included: [String] = []
    var missing: [String] = []
    var truncated: [String] = []
    var denied: [String] = []

    func render(maxBytes: Int) -> String {
        func section(_ title: String, _ items: [String]) -> String {
            "\(title) (\(items.count))\n" + (items.isEmpty ? "  none\n" : items.map { "  \($0)\n" }.joined()) + "\n"
        }
        return "Ember diagnostics bundle\n\n" + section("Included", included)
            + section("Missing", missing)
            + section("Truncated to last \(maxBytes) bytes", truncated)
            + section("Skipped (deny list)", denied)
    }
}

struct Collector {
    let stage: URL
    let maxBytes: Int

    func gather(
        from dir: URL, matching: (String) -> Bool, into folder: String, label: String,
        recursive: Bool, report: inout Report, reportMissing: Bool = true
    ) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            if reportMissing { report.missing.append(label) }
            return
        }
        var files: [(rel: String, url: URL)] = []
        if recursive {
            let base = dir.standardizedFileURL.path
            let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
            while let url = walker?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                files.append((String(url.standardizedFileURL.path.dropFirst(base.count + 1)), url))
            }
        } else {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                files.append((name, dir.appending(path: name)))
            }
        }
        var copied = 0
        for (rel, url) in files.sorted(by: { $0.rel < $1.rel }) where matching((rel as NSString).lastPathComponent) {
            var regular: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &regular), !regular.boolValue else { continue }
            if try copy(url, rel: rel, folder: folder, report: &report) { copied += 1 }
        }
        if copied == 0 && reportMissing { report.missing.append("\(label): no matching files") }
    }

    func gatherFile(_ url: URL, into folder: String, label: String, report: inout Report) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            report.missing.append(label)
            return
        }
        _ = try copy(url, rel: url.lastPathComponent, folder: folder, report: &report)
    }

    private func copy(_ url: URL, rel: String, folder: String, report: inout Report) throws -> Bool {
        let entry = "\(folder)/\(rel)"
        if rel.split(separator: "/").contains(where: { DiagnosticsBundle.isDenied(String($0)) }) {
            report.denied.append(entry)
            return false
        }
        let target = stage.appending(path: entry)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = Int(try handle.seekToEnd())
            let start = max(0, size - maxBytes)
            try handle.seek(toOffset: UInt64(start))
            let data = try handle.readToEnd() ?? Data()
            try data.write(to: target)
            if start > 0 { report.truncated.append(entry) }
        } catch {
            throw EmberError.fileSystem(path: url.path, reason: error.localizedDescription)
        }
        report.included.append(entry)
        return true
    }
}
