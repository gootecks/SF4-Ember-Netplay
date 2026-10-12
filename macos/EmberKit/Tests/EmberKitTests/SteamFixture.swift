import Foundation

@testable import EmberKit

struct SteamFixture {
    static let ssfivBytes = "fake-ssfiv-exe"

    let dir: URL
    let paths: EmberPaths
    let manifest: EngineManifest
    let setupSHA: String

    var engineDir: URL { paths.engineDir(manifest.id) }
    var callsLog: URL { engineDir.appending(path: "calls.log") }
    var tasklistFile: URL { engineDir.appending(path: "tasklist.txt") }
    var steamDir: URL { paths.prefixDir.appending(path: "drive_c/Program Files (x86)/Steam") }
    var loginLog: URL { steamDir.appending(path: "logs/steamui_login.txt") }
    var vdf: URL { steamDir.appending(path: "steamapps/libraryfolders.vdf") }
    var hostLibrary: URL { dir.appending(path: "hostlib") }

    static func make(ssfivSHA: String? = nil, build: Int = 834219) throws -> SteamFixture {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "emberkit-steam-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        let paths = EmberPaths(root: dir.appending(path: "root"))
        let id = "fake-engine"
        let engine = paths.engineDir(id)
        let dxvk = engine.appending(path: "renderers/d9vk/wine/i386-windows")
        try fm.createDirectory(at: engine.appending(path: "bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dxvk, withIntermediateDirectories: true)
        try "dll".write(to: dxvk.appending(path: "d3d9.dll"), atomically: true, encoding: .utf8)
        let wine = """
            #!/bin/sh
            D="$(dirname "$0")/.."
            echo "wine $* | cwd=$(pwd) hud=$DXVK_HUD" >> "$D/calls.log"
            if [ "$1" = tasklist ]; then cat "$D/tasklist.txt" 2>/dev/null; fi
            case "$1" in
              *SteamSetup.exe)
                mkdir -p "$WINEPREFIX/drive_c/Program Files (x86)/Steam"
                echo exe > "$WINEPREFIX/drive_c/Program Files (x86)/Steam/steam.exe";;
            esac
            exit 0
            """
        let server = "#!/bin/sh\necho \"wineserver $*\" >> \"$(dirname \"$0\")/../calls.log\"\nexit 0\n"
        try wine.write(to: engine.appending(path: "bin/wine"), atomically: true, encoding: .utf8)
        try server.write(to: engine.appending(path: "bin/wineserver"), atomically: true, encoding: .utf8)
        for name in ["wine", "wineserver"] {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.appending(path: "bin/\(name)").path)
        }
        try fm.createDirectory(at: paths.prefixDir.appending(path: "drive_c"), withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.prefixDir.appending(path: "dosdevices"), withIntermediateDirectories: true)
        try "renderer=dxvk\nengine=\(id)\ncreated=now\n".write(
            to: paths.prefixMarker, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: paths.cacheDir, withIntermediateDirectories: true)
        let setup = paths.cacheDir.appending(path: "SteamSetup.exe")
        try "setup".write(to: setup, atomically: true, encoding: .utf8)
        let setupSHA = try Downloader.sha256(of: setup)

        let ssfivFile = dir.appending(path: "ssfiv.bin")
        try ssfivBytes.write(to: ssfivFile, atomically: true, encoding: .utf8)
        let ssfivActual = try Downloader.sha256(of: ssfivFile)
        let json = """
            {
              "schemaVersion": 1, "id": "\(id)",
              "engine": {"wine": "bin/wine", "wineserver": "bin/wineserver", "wineboot": null,
                         "dxvkDllPathPrepend": "renderers/d9vk/wine"},
              "components": [],
              "prefix": {"windowsVersion": "win10", "dllOverrides": {}, "registry": []},
              "steam": {"setupUrl": "https://example.invalid/SteamSetup.exe", "sha256": "\(setupSHA)",
                        "installArgs": ["/S"], "hiddenArgs": ["-silent", "-no-browser"], "readyTimeoutSeconds": 1},
              "game": {"steamAppId": 45760, "build": \(build), "ssfivSha256": "\(ssfivSHA ?? ssfivActual)"}
            }
            """
        return SteamFixture(
            dir: dir, paths: paths, manifest: try EngineManifest.decode(Data(json.utf8)), setupSHA: setupSHA)
    }

    func controller(
        alive: Bool = true, highball: Bool = false, timeout: Double? = 0.4, poll: Double = 0.05,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> SteamController {
        SteamController(
            wine: Wine(manifest: manifest, paths: paths, baseEnvironment: ["PATH": "/usr/bin:/bin"]),
            highballDir: dir.appending(path: "Highball"),
            readyTimeout: timeout, pollInterval: poll,
            serverAlive: { alive }, highballWineserverRunning: { highball }, log: log)
    }

    func writeLoginLog(_ text: String, append: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: loginLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        if append, let handle = try? FileHandle(forWritingTo: loginLog) {
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try text.write(to: loginLog, atomically: true, encoding: .utf8)
        }
    }

    func installSteamExe() throws {
        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
        try "exe".write(to: steamDir.appending(path: "steam.exe"), atomically: true, encoding: .utf8)
    }

    func setTasklist(_ text: String) throws {
        try text.write(to: tasklistFile, atomically: true, encoding: .utf8)
    }

    func makeGameLibrary(build: Int = 834219, exe: String = ssfivBytes) throws {
        let common = hostLibrary.appending(path: "steamapps/common/Super Street Fighter IV - Arcade Edition")
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        try exe.write(to: common.appending(path: "SSFIV.exe"), atomically: true, encoding: .utf8)
        let acf = """
            "AppState"
            {
            \t"appid"\t\t"45760"
            \t"installdir"\t\t"Super Street Fighter IV - Arcade Edition"
            \t"buildid"\t\t"\(build)"
            }
            """
        try acf.write(
            to: hostLibrary.appending(path: "steamapps/appmanifest_45760.acf"), atomically: true, encoding: .utf8)
    }

    func makeEmber(_ name: String, release: String? = nil) throws {
        let d = paths.prefixDir.appending(path: "drive_c/\(name)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "x".write(to: d.appending(path: "Launcher.exe"), atomically: true, encoding: .utf8)
        if let release { try "Release: \(release)\r\n".write(to: d.appending(path: "BUILD_INFO.txt"), atomically: true, encoding: .utf8) }
    }

    func calls() -> String { (try? String(contentsOf: callsLog, encoding: .utf8)) ?? "" }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}
