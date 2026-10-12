import Foundation

public enum EmberPayloadError: Error, Equatable, LocalizedError {
    case releaseLookupFailed(String)
    case assetMissing(tag: String, asset: String)
    case digestMissing(tag: String, asset: String)
    case invalidVersion(String)
    case installDirIncomplete(String)
    case manifestMissing
    case manifestEmpty
    case manifestMismatch([String])
    case launcherMissing
    case unsafeManifestPath(String)

    public var errorDescription: String? {
        switch self {
        case .releaseLookupFailed(let reason):
            "Ember release lookup failed: \(reason)"
        case .assetMissing(let tag, let asset):
            "Ember \(tag) has no \(asset) asset"
        case .digestMissing(let tag, let asset):
            "Ember \(tag): \(asset) has no sha256 digest on GitHub; refusing to install"
        case .invalidVersion(let version):
            "invalid Ember version: \(version)"
        case .installDirIncomplete(let path):
            "\(path) exists without Launcher.exe; remove it and retry"
        case .manifestMissing:
            "MANIFEST.txt not found in the Ember archive"
        case .manifestEmpty:
            "MANIFEST.txt has no 'sha256  path' lines; format not understood"
        case .manifestMismatch(let files):
            "Ember files do not match MANIFEST.txt: " + files.prefix(20).joined(separator: ", ")
        case .launcherMissing:
            "Launcher.exe missing from the Ember package"
        case .unsafeManifestPath(let path):
            "MANIFEST.txt path escapes the package: \(path)"
        }
    }
}

public struct EmberRelease: Sendable, Equatable {
    public var version: String
    public var assetName: String
    public var url: URL
    public var sha256: String

    public init(version: String, assetName: String, url: URL, sha256: String) {
        self.version = version
        self.assetName = assetName
        self.url = url
        self.sha256 = sha256
    }

    public static func assetName(version: String) -> String {
        "sf4-ember-netplay-\(version).zip"
    }

    public init(manifest ember: EngineManifest.Ember) throws {
        guard let url = URL(string: ember.url) else {
            throw EmberError.downloadFailed(url: ember.url, reason: "invalid URL")
        }
        self.init(
            version: ember.version,
            assetName: ember.asset.isEmpty ? EmberRelease.assetName(version: ember.version) : ember.asset,
            url: url, sha256: ember.sha256)
    }
}

public protocol EmberReleaseSource: Sendable {
    func latest() async throws -> EmberRelease
    func release(version: String) async throws -> EmberRelease
}

public struct GitHubReleaseSource: EmberReleaseSource {
    public static let defaultRepo = "Confetti3/SF4-Ember-Netplay"

    public let repo: String
    public let session: URLSession
    public let pinned: EngineManifest.Ember?

    public init(repo: String = defaultRepo, session: URLSession = .shared, pinned: EngineManifest.Ember? = nil) {
        self.repo = repo
        self.session = session
        self.pinned = pinned
    }

    public func latest() async throws -> EmberRelease {
        try await fetch(path: "releases/latest")
    }

    public func release(version: String) async throws -> EmberRelease {
        let version = EmberVersion.normalized(version)
        if let pinned, pinned.version == version { return try EmberRelease(manifest: pinned) }
        return try await fetch(path: "releases/tags/v\(version)")
    }

    private struct Payload: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: String
            var digest: String?
        }
        var tag_name: String?
        var assets: [Asset]?
    }

    private func fetch(path: String) async throws -> EmberRelease {
        guard let api = URL(string: "https://api.github.com/repos/\(repo)/\(path)") else {
            throw EmberPayloadError.releaseLookupFailed("invalid repo \(repo)")
        }
        var request = URLRequest(url: api, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw EmberPayloadError.releaseLookupFailed("HTTP \(http.statusCode) from \(api.absoluteString)")
            }
            data = body
        } catch let error as EmberPayloadError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EmberPayloadError.releaseLookupFailed(error.localizedDescription)
        }
        return try Self.parse(data)
    }

    public static func parse(_ data: Data) throws -> EmberRelease {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw EmberPayloadError.releaseLookupFailed("unreadable release JSON: \(error.localizedDescription)")
        }
        guard let tag = payload.tag_name, !tag.isEmpty else {
            throw EmberPayloadError.releaseLookupFailed("release JSON has no tag_name")
        }
        let version = EmberVersion.normalized(tag)
        let name = EmberRelease.assetName(version: version)
        guard let asset = payload.assets?.first(where: { $0.name == name }),
            let url = URL(string: asset.browser_download_url)
        else {
            throw EmberPayloadError.assetMissing(tag: tag, asset: name)
        }
        var digest = asset.digest ?? ""
        if digest.hasPrefix("sha256:") { digest.removeFirst("sha256:".count) }
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
            throw EmberPayloadError.digestMissing(tag: tag, asset: name)
        }
        return EmberRelease(version: version, assetName: name, url: url, sha256: digest.lowercased())
    }
}

public enum EmberVersion {
    public static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    public static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        lhs != rhs && compare(lhs, rhs) > 0
    }

    public static func compare(_ lhs: String, _ rhs: String) -> Int {
        let a = tokens(lhs)
        let b = tokens(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : "0"
            let y = index < b.count ? b[index] : "0"
            if let nx = Int(x), let ny = Int(y) {
                if nx != ny { return nx < ny ? -1 : 1 }
            } else if x != y {
                return x < y ? -1 : 1
            }
        }
        return 0
    }

    private static func tokens(_ version: String) -> [String] {
        version.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
