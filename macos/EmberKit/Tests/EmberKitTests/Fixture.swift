import Foundation

@testable import EmberKit

struct Fixture {
    let dir: URL
    let paths: EmberPaths
    let archive: URL
    let archiveSHA: String
    let manifest: EngineManifest

    var callsLog: URL { paths.engineDir(manifest.id).appending(path: "calls.log") }

    static func make(sha256Override: String? = nil) throws -> Fixture {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "emberkit-\(UUID().uuidString)", directoryHint: .isDirectory)
        let src = dir.appending(path: "src/bundle", directoryHint: .isDirectory)
        let bin = src.appending(path: "bin")
        let dxvk = src.appending(path: "renderers/d9vk/wine/i386-windows")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: dxvk, withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appending(path: "home"), withIntermediateDirectories: true)
        try "dll".write(to: dxvk.appending(path: "d3d9.dll"), atomically: true, encoding: .utf8)
        let wineScript = """
            #!/bin/sh
            log="$(dirname "$0")/../calls.log"
            echo "wine $* | prefix=$WINEPREFIX msync=$WINEMSYNC dllpath=$WINEDLLPATH_PREPEND overrides=$WINEDLLOVERRIDES" >> "$log"
            if [ "$1" = wineboot ]; then mkdir -p "$WINEPREFIX/drive_c"; fi
            exit 0
            """
        let serverScript = """
            #!/bin/sh
            echo "wineserver $*" >> "$(dirname "$0")/../calls.log"
            exit 0
            """
        try wineScript.write(to: bin.appending(path: "wine"), atomically: true, encoding: .utf8)
        try serverScript.write(to: bin.appending(path: "wineserver"), atomically: true, encoding: .utf8)
        for name in ["wine", "wineserver"] {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: name).path)
        }
        let archive = dir.appending(path: "fake-engine.tar.gz")
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", dir.appending(path: "src").path, "bundle"]
        try tar.run()
        tar.waitUntilExit()
        let sha = try Downloader.sha256(of: archive)
        let json = """
            {
              "schemaVersion": 1,
              "id": "fake-engine",
              "engine": {"wine": "bin/wine", "wineserver": "bin/wineserver", "wineboot": null,
                         "dxvkDllPathPrepend": "renderers/d9vk/wine"},
              "components": [{
                "name": "fake", "url": "\(archive.absoluteString)", "sha256": "\(sha256Override ?? sha)",
                "format": "tar.gz", "install": [{"from": "bundle", "to": "engine:."}]
              }],
              "prefix": {
                "windowsVersion": "win10",
                "dllOverrides": {"winemenubuilder.exe": "d"},
                "env": {"WINEMSYNC": "1"},
                "registry": [
                  {"key": "HKCU\\\\Software\\\\Wine\\\\Mac Driver", "name": "LeftCommandIsCtrl", "type": "REG_SZ", "data": "y"},
                  {"key": "HKCU\\\\Software\\\\Wine\\\\X", "type": "REG_SZ", "data": "z"}
                ]
              }
            }
            """
        let manifest = try EngineManifest.decode(Data(json.utf8))
        return Fixture(
            dir: dir, paths: EmberPaths(root: dir.appending(path: "root")),
            archive: archive, archiveSHA: sha, manifest: manifest)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}
