import Darwin
import Foundation

public enum SteamError: Error, Equatable, LocalizedError {
    case manifestSectionMissing(String)
    case prefixNotBuilt(path: String)
    case steamNotInstalled(path: String)
    case steamSetupFailed(path: String)
    case loginTimeout(seconds: Int, lastState: String)
    case notLoggedOn
    case libraryNotAdopted(appId: Int)
    case invalidDriveLetter(String)
    case driveAlreadyMapped(letter: String, target: String)
    case driveLinkNotSymlink(path: String)
    case libraryNotFound(host: String)
    case libraryFoldersMalformed(path: String)
    case steamRunning
    case highballConflict(link: String, host: String)
    case appManifestMissing(appId: Int)
    case gameMismatch(String)
    case emberNotInstalled

    public var errorDescription: String? {
        switch self {
        case .manifestSectionMissing(let name):
            "manifest has no \(name) section"
        case .prefixNotBuilt(let path):
            "prefix not built at \(path); build the prefix first"
        case .steamNotInstalled(let path):
            "Steam not installed in the prefix (\(path) missing); run the Steam install first"
        case .steamSetupFailed(let path):
            "SteamSetup finished but \(path) is missing"
        case .loginTimeout(let seconds, let lastState):
            "Steam did not reach 'SetLoginState: Success' within \(seconds)s (last login state: "
                + "\(lastState.isEmpty ? "none" : lastState)); not logged in yet? run the visible Steam login"
        case .notLoggedOn:
            "Steam is not running/logged on in this prefix; start Steam first"
        case .libraryNotAdopted(let appId):
            "Steam has not adopted a library containing app \(appId) (SSFIV would boot as Arcade Edition); "
                + "kill and start Steam again"
        case .invalidDriveLetter(let letter):
            "drive letter must be a single letter A-Y other than C (got \(letter))"
        case .driveAlreadyMapped(let letter, let target):
            "\(letter): already maps to '\(target)' in this prefix"
        case .driveLinkNotSymlink(let path):
            "\(path) exists and is not a symlink"
        case .libraryNotFound(let host):
            "no 'steamapps' folder in \(host) or its subfolders; pass the directory containing the Steam library"
        case .libraryFoldersMalformed(let path):
            "\(path) has no closing brace; not modified"
        case .steamRunning:
            "our Steam is running; kill it first (libraryfolders.vdf is only edited while Steam is stopped)"
        case .highballConflict(let link, let host):
            "Highball's wineserver is running and its bottle uses the same directory (\(link) -> \(host)). "
                + "Two Steam clients must not share one library at the same time (appmanifest/lock corruption). "
                + "Quit Steam and the bottle in Highball first, then retry."
        case .appManifestMissing(let appId):
            "appmanifest_\(appId).acf not found in any library (add the library, or install the game through Steam)"
        case .gameMismatch(let detail):
            "game files do not match the pinned build: \(detail)"
        case .emberNotInstalled:
            "Ember not installed in the prefix (no C:\\sf4e-*\\Launcher.exe)"
        }
    }
}

public enum SteamStartOutcome: Sendable, Equatable {
    case alreadyReady
    case ready(afterSeconds: Double)
}

public struct SteamController: Sendable {
    public static let loginMarker = "SetLoginState: "
    public static let loginSuccess = "SetLoginState: Success"
    public static let steamExeWindowsPath = "C:\\Program Files (x86)\\Steam\\steam.exe"

    public let wine: Wine
    public let downloader: Downloader
    public let highballDir: URL
    public let readyTimeout: Double?
    public let pollInterval: Double
    public let serverAlive: @Sendable () async -> Bool
    public let highballWineserverRunning: @Sendable () async -> Bool
    public let log: @Sendable (String) -> Void

    public init(
        wine: Wine,
        downloader: Downloader? = nil,
        highballDir: URL = SteamController.defaultHighballDir,
        readyTimeout: Double? = nil,
        pollInterval: Double = 1,
        serverAlive: (@Sendable () async -> Bool)? = nil,
        highballWineserverRunning: (@Sendable () async -> Bool)? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        let prefix = wine.paths.prefixDir
        self.wine = wine
        self.downloader = downloader ?? Downloader(cacheDir: wine.paths.cacheDir, log: log)
        self.highballDir = highballDir
        self.readyTimeout = readyTimeout
        self.pollInterval = pollInterval
        self.serverAlive = serverAlive ?? { await Self.wineserverAlive(prefix: prefix) }
        self.highballWineserverRunning = highballWineserverRunning ?? { await Self.highballServerRunning() }
        self.log = log
    }

    public static var defaultHighballDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Highball", directoryHint: .isDirectory)
    }

    public var paths: EmberPaths { wine.paths }
    public var manifest: EngineManifest { wine.manifest }
    public var prefixDir: URL { paths.prefixDir }
    public var steamDir: URL {
        prefixDir.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
    }
    public var steamExe: URL { steamDir.appending(path: "steam.exe") }
    public var loginLog: URL { steamDir.appending(path: "logs/steamui_login.txt") }
    public var libraryFoldersFile: URL { steamDir.appending(path: "steamapps/libraryfolders.vdf") }

    func steamSection() throws -> EngineManifest.Steam {
        guard let steam = manifest.steam else { throw SteamError.manifestSectionMissing("steam") }
        return steam
    }

    func requirePrefix() throws {
        guard FileManager.default.fileExists(atPath: paths.prefixMarker.path) else {
            throw SteamError.prefixNotBuilt(path: prefixDir.path)
        }
    }

    func requireSteamExe() throws {
        guard FileManager.default.fileExists(atPath: steamExe.path) else {
            throw SteamError.steamNotInstalled(path: steamExe.path)
        }
    }

    func logFile(_ name: String) -> URL {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return paths.logsDir.appending(path: "\(fmt.string(from: Date()))-\(name).log")
    }

    public static func wineserverAlive(prefix: URL) async -> Bool {
        var info = stat()
        guard stat(prefix.path, &info) == 0 else { return false }
        let id = String(format: "%x-%x", UInt64(bitPattern: Int64(info.st_dev)), UInt64(info.st_ino))
        let lock = "/tmp/.wine-\(getuid())/server-\(id)/lock"
        guard FileManager.default.fileExists(atPath: lock) else { return false }
        guard let result = try? await ProcessRunner.run("/usr/sbin/lsof", ["-t", lock]) else { return false }
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func highballServerRunning() async -> Bool {
        guard
            let result = try? await ProcessRunner.run(
                "/usr/bin/pgrep", ["-f", "Highball/engines/.*/wineserver"])
        else { return false }
        return result.succeeded
    }

    public func tasklist() async throws -> [String] {
        guard await serverAlive() else { return [] }
        let result = try await wine.run(["tasklist"], check: false)
        return result.stdout.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    public func hasProcess(_ name: String) async throws -> Bool {
        try await tasklist().contains { $0.range(of: name, options: .caseInsensitive) != nil }
    }

    public func isRunning() async throws -> Bool {
        try await hasProcess("steam.exe")
    }

    public func loginLogSize() -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: loginLog.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    public func loginState(since offset: UInt64 = 0) -> String {
        guard let data = try? Data(contentsOf: loginLog, options: .mappedIfSafe) else { return "" }
        let start = offset <= UInt64(data.count) ? Int(offset) : 0
        let text = String(decoding: data[(data.startIndex + start)...], as: UTF8.self)
        let last = text.components(separatedBy: .newlines).last { $0.contains(Self.loginMarker) }
        return last ?? ""
    }

    public func isLoggedOn(since offset: UInt64 = 0) -> Bool {
        loginState(since: offset).contains(Self.loginSuccess)
    }

    @discardableResult
    public func install() async throws -> Bool {
        let steam = try steamSection()
        try requirePrefix()
        if FileManager.default.fileExists(atPath: steamExe.path) {
            log("Steam already installed: \(steamDir.path) (nothing to do)")
            return false
        }
        guard let url = URL(string: steam.setupUrl) else {
            throw EmberError.downloadFailed(url: steam.setupUrl, reason: "invalid URL")
        }
        let file = try await downloader.fetch(url: url, sha256: steam.sha256)
        log("running SteamSetup.exe \(steam.installArgs.joined(separator: " "))")
        try await wine.run([file.path] + steam.installArgs)
        try await wine.waitWineserver()
        guard FileManager.default.fileExists(atPath: steamExe.path) else {
            throw SteamError.steamSetupFailed(path: steamExe.path)
        }
        log("Steam installed: \(steamDir.path)")
        return true
    }

    func spawnSteam(_ args: [String]) throws {
        log("starting Steam: steam.exe \(args.joined(separator: " "))")
        try wine.spawn(
            [Self.steamExeWindowsPath] + args, logFile: logFile("steam"), currentDirectory: steamDir)
    }

    @discardableResult
    public func login() async throws -> Bool {
        try requirePrefix()
        try requireSteamExe()
        if try await isRunning() {
            log("Steam is already running in this prefix (nothing to do)")
            return false
        }
        try spawnSteam([])
        log("Steam window should appear shortly; log in once (Steam Guard if asked), tick 'Remember my password'.")
        return true
    }

    @discardableResult
    public func startHidden() async throws -> SteamStartOutcome {
        let steam = try steamSection()
        try requirePrefix()
        try requireSteamExe()
        let running = try await isRunning()
        if running && isLoggedOn() {
            log("Steam already running and logged on (nothing to do)")
            return .alreadyReady
        }
        var offset: UInt64 = 0
        if running {
            log("Steam running but not logged on; waiting")
        } else {
            offset = loginLogSize()
            try spawnSteam(steam.hiddenArgs)
        }
        let timeout = readyTimeout ?? Double(steam.readyTimeoutSeconds)
        let begin = Date()
        while true {
            if isLoggedOn(since: offset) {
                let elapsed = Date().timeIntervalSince(begin)
                log("Steam logged on after \(Int(elapsed))s")
                return .ready(afterSeconds: elapsed)
            }
            if Date().timeIntervalSince(begin) >= timeout { break }
            try await Task.sleep(for: .seconds(pollInterval))
            if offset > loginLogSize() { offset = 0 }
        }
        throw SteamError.loginTimeout(seconds: Int(timeout.rounded(.up)), lastState: loginState(since: offset))
    }

    public func requireLoggedOn() async throws {
        guard try await isRunning(), isLoggedOn() else { throw SteamError.notLoggedOn }
    }

    public func kill() async {
        guard FileManager.default.fileExists(atPath: prefixDir.path) else {
            log("no prefix at \(prefixDir.path) (nothing to do)")
            return
        }
        guard await serverAlive() else {
            log("no wineserver for this prefix (nothing to do)")
            return
        }
        log("wineserver -k for \(prefixDir.path)")
        await wine.killServer()
        try? await wine.waitWineserver()
    }
}
