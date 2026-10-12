import Foundation

public enum SteamVDF {
    public static let defaultSteamLibraryPath = "C:\\Program Files (x86)\\Steam"

    private static let pathLine = try! NSRegularExpression(pattern: #"^\s*"path"\s+"(.*)"\s*$"#)
    private static let indexLine = try! NSRegularExpression(pattern: #"^\s*"([0-9]+)"\s*$"#)
    private static let closingLine = try! NSRegularExpression(pattern: #"^[ \t]*\}[ \t\r]*$"#)

    private static func firstCapture(_ regex: NSRegularExpression, in line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges > 1,
            let r = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[r])
    }

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    public static func escape(_ windowsPath: String) -> String {
        windowsPath.replacingOccurrences(of: "\\", with: "\\\\")
    }

    public static func libraryPaths(in text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            firstCapture(pathLine, in: line)?.replacingOccurrences(of: "\\\\", with: "\\")
        }
    }

    public static func containsApp(_ appId: Int, in text: String) -> Bool {
        text.contains("\"\(appId)\"")
    }

    public static func value(_ key: String, in acf: String) -> String? {
        let pattern = "^\\s*\"\(NSRegularExpression.escapedPattern(for: key))\"\\s+\"([^\"]*)\".*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for line in acf.components(separatedBy: "\n") {
            if let v = firstCapture(regex, in: line) { return v }
        }
        return nil
    }

    static func block(index: Int, escapedPath: String) -> String {
        "\t\"\(index)\"\n\t{\n\t\t\"path\"\t\t\"\(escapedPath)\"\n\t\t\"label\"\t\t\"\"\n"
            + "\t\t\"contentid\"\t\t\"0\"\n\t\t\"totalsize\"\t\t\"0\"\n\t\t\"apps\"\n\t\t{\n\t\t}\n\t}"
    }

    static func normalized(_ windowsPath: String) -> String {
        var p = windowsPath.lowercased()
        if p.hasSuffix("\\") { p.removeLast() }
        return p
    }

    public static func newLibraryFolders(adding windowsPath: String) -> String {
        "\"libraryfolders\"\n{\n"
            + block(index: 0, escapedPath: escape(defaultSteamLibraryPath)) + "\n"
            + block(index: 1, escapedPath: escape(windowsPath)) + "\n}\n"
    }

    public static func adding(windowsPath: String, to text: String) throws -> (text: String, index: Int)? {
        let want = normalized(windowsPath)
        if libraryPaths(in: text).contains(where: { normalized($0) == want }) { return nil }
        var lines = text.components(separatedBy: "\n")
        let next = (lines.compactMap { firstCapture(indexLine, in: $0).flatMap(Int.init) }.max() ?? -1) + 1
        guard let last = lines.lastIndex(where: { matches(closingLine, $0) }) else {
            throw SteamError.libraryFoldersMalformed(path: "libraryfolders.vdf")
        }
        lines.insert(block(index: next, escapedPath: escape(windowsPath)), at: last)
        return (lines.joined(separator: "\n"), next)
    }
}

public enum LibraryOutcome: Sendable, Equatable {
    case created(windowsPath: String)
    case registered(windowsPath: String, index: Int)
    case alreadyRegistered(windowsPath: String)
}

extension SteamController {
    var appId: Int { manifest.game?.steamAppId ?? 45760 }

    static func resolveLink(_ link: URL) -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        let url =
            target.hasPrefix("/")
            ? URL(filePath: target) : link.deletingLastPathComponent().appending(path: target)
        let resolved = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return resolved.path
    }

    func windowsToHost(_ windowsPath: String) -> String? {
        guard windowsPath.count >= 2, windowsPath[windowsPath.index(after: windowsPath.startIndex)] == ":" else {
            return nil
        }
        let letter = windowsPath.prefix(1).lowercased()
        let rest = windowsPath.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
        let base: String
        if letter == "c" {
            base = prefixDir.appending(path: "drive_c").path
        } else {
            guard let resolved = Self.resolveLink(prefixDir.appending(path: "dosdevices/\(letter):")) else {
                return nil
            }
            base = resolved
        }
        return base + rest
    }

    func highballConflict(host: String) async -> String? {
        guard await highballWineserverRunning() else { return nil }
        let fm = FileManager.default
        let bottles = highballDir.appending(path: "bottles", directoryHint: .isDirectory)
        for bottle in (try? fm.contentsOfDirectory(atPath: bottles.path))?.sorted() ?? [] {
            let dos = bottles.appending(path: "\(bottle)/dosdevices", directoryHint: .isDirectory)
            for entry in (try? fm.contentsOfDirectory(atPath: dos.path))?.sorted() ?? [] {
                let link = dos.appending(path: entry)
                if let target = Self.resolveLink(link), target == host { return link.path }
            }
        }
        return nil
    }

    func libraryRelativePath(host: URL) -> String? {
        let fm = FileManager.default
        func isDir(_ url: URL) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
        }
        if isDir(host.appending(path: "steamapps")) { return "." }
        var best: String?
        for name in ((try? fm.contentsOfDirectory(atPath: host.path)) ?? []).sorted() {
            let child = host.appending(path: name, directoryHint: .isDirectory)
            guard isDir(child.appending(path: "steamapps")) else { continue }
            if best == nil { best = name }
            if fm.fileExists(atPath: child.appending(path: "steamapps/appmanifest_\(appId).acf").path) {
                best = name
                break
            }
        }
        return best
    }

    @discardableResult
    public func addLibrary(host: URL, letter: String = "E") async throws -> LibraryOutcome {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: host.path, isDirectory: &isDir), isDir.boolValue else {
            throw SteamError.libraryNotFound(host: host.path)
        }
        let hostPath = host.resolvingSymlinksInPath().path
        let lower = letter.lowercased()
        guard lower.count == 1, let ch = lower.first, ("a"..."y").contains(ch), lower != "c" else {
            throw SteamError.invalidDriveLetter(letter)
        }
        let upper = lower.uppercased()
        try requirePrefix()
        if let hit = await highballConflict(host: hostPath) {
            throw SteamError.highballConflict(link: hit, host: hostPath)
        }
        if try await isRunning() { throw SteamError.steamRunning }

        let dos = prefixDir.appending(path: "dosdevices", directoryHint: .isDirectory)
        let link = dos.appending(path: "\(lower):")
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
            let current = Self.resolveLink(link) ?? ""
            guard current == hostPath else { throw SteamError.driveAlreadyMapped(letter: upper, target: current) }
            log("\(upper): -> \(hostPath) already mapped")
        } else {
            guard !fm.fileExists(atPath: link.path) else { throw SteamError.driveLinkNotSymlink(path: link.path) }
            try fm.createDirectory(at: dos, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: hostPath)
            log("mapped \(upper): -> \(hostPath)")
        }

        guard let rel = libraryRelativePath(host: URL(filePath: hostPath, directoryHint: .isDirectory)) else {
            throw SteamError.libraryNotFound(host: hostPath)
        }
        let windowsPath = rel == "." ? "\(upper):\\" : "\(upper):\\" + rel.replacingOccurrences(of: "/", with: "\\")
        let vdf = libraryFoldersFile
        try fm.createDirectory(at: vdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.fileExists(atPath: vdf.path) else {
            try SteamVDF.newLibraryFolders(adding: windowsPath).write(to: vdf, atomically: true, encoding: .utf8)
            log("created \(vdf.path) with library \(windowsPath)")
            return .created(windowsPath: windowsPath)
        }
        let text = try String(contentsOf: vdf, encoding: .utf8)
        let updated: (text: String, index: Int)?
        do {
            updated = try SteamVDF.adding(windowsPath: windowsPath, to: text)
        } catch {
            throw SteamError.libraryFoldersMalformed(path: vdf.path)
        }
        guard let updated else {
            log("library \(windowsPath) already registered in libraryfolders.vdf (nothing to do)")
            return .alreadyRegistered(windowsPath: windowsPath)
        }
        let backup = vdf.appendingPathExtension("m0bak")
        if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: vdf, to: backup) }
        try updated.text.write(to: vdf, atomically: true, encoding: .utf8)
        log("registered library \(windowsPath) (backup: \(backup.path))")
        return .registered(windowsPath: windowsPath, index: updated.index)
    }
}
