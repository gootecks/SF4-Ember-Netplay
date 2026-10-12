import Foundation

public enum HashStatus: Sendable, Equatable {
    case match
    case mismatch(expected: String)
    case notPinned
    case exeMissing
}

public struct LibraryGameReport: Sendable, Equatable {
    public let libraryRoot: String
    public let installDir: String
    public let appBuild: String
    public let expectedBuild: Int
    public let buildMatches: Bool
    public let exePath: String
    public let sha256: String?
    public let hash: HashStatus

    public var ok: Bool {
        guard buildMatches else { return false }
        switch hash {
        case .match, .notPinned: return true
        case .mismatch, .exeMissing: return false
        }
    }

    public var summary: String {
        var parts = ["build \(appBuild) \(buildMatches ? "MATCH" : "MISMATCH (expected \(expectedBuild))")"]
        switch hash {
        case .match: parts.append("SSFIV.exe sha256 MATCH")
        case .mismatch(let expected):
            parts.append("SSFIV.exe sha256 MISMATCH (got \(sha256 ?? "?"), expected \(expected))")
        case .notPinned: parts.append("SSFIV.exe sha256 not pinned (\(sha256 ?? "?"))")
        case .exeMissing: parts.append("SSFIV.exe missing: \(exePath)")
        }
        return "\(libraryRoot): " + parts.joined(separator: "; ")
    }
}

public struct GameCheckReport: Sendable, Equatable {
    public let libraries: [LibraryGameReport]

    public var ok: Bool { libraries.contains { $0.ok } && libraries.allSatisfy(\.ok) }
}

extension SteamController {
    public func libraryRoots() -> [String] {
        var roots = [prefixDir.appending(path: "drive_c/Program Files (x86)/Steam").path]
        if let text = try? String(contentsOf: libraryFoldersFile, encoding: .utf8) {
            for winPath in SteamVDF.libraryPaths(in: text) {
                guard let root = windowsToHost(winPath) else {
                    log("cannot map library \(winPath) (no dosdevices entry)")
                    continue
                }
                if !roots.contains(root) { roots.append(root) }
            }
        }
        return roots
    }

    public func gameCheck() throws -> GameCheckReport {
        try requirePrefix()
        guard let game = manifest.game else { throw SteamError.manifestSectionMissing("game") }
        var reports: [LibraryGameReport] = []
        for root in libraryRoots() {
            let acf = URL(filePath: root).appending(path: "steamapps/appmanifest_\(game.steamAppId).acf")
            guard let text = try? String(contentsOf: acf, encoding: .utf8) else { continue }
            let installDir = SteamVDF.value("installdir", in: text) ?? ""
            let build = SteamVDF.value("buildid", in: text) ?? ""
            let exe = URL(filePath: root).appending(path: "steamapps/common/\(installDir)/SSFIV.exe")
            let buildMatches = build == String(game.build)
            let want = game.ssfivSha256.lowercased()
            var got: String?
            let hash: HashStatus
            if !FileManager.default.fileExists(atPath: exe.path) {
                hash = .exeMissing
            } else {
                got = try Downloader.sha256(of: exe)
                if want.isEmpty {
                    hash = .notPinned
                } else {
                    hash = got == want ? .match : .mismatch(expected: want)
                }
            }
            let report = LibraryGameReport(
                libraryRoot: root, installDir: installDir, appBuild: build, expectedBuild: game.build,
                buildMatches: buildMatches, exePath: exe.path, sha256: got, hash: hash)
            log(report.summary)
            reports.append(report)
        }
        guard !reports.isEmpty else { throw SteamError.appManifestMissing(appId: game.steamAppId) }
        return GameCheckReport(libraries: reports)
    }

    @discardableResult
    public func requireGameMatch() throws -> GameCheckReport {
        let report = try gameCheck()
        guard report.ok else {
            throw SteamError.gameMismatch(report.libraries.filter { !$0.ok }.map(\.summary).joined(separator: "\n"))
        }
        return report
    }
}
