import Foundation

public struct EmberPaths: Sendable, Equatable {
    public let root: URL

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Ember", directoryHint: .isDirectory)
    }

    public init(root: URL = EmberPaths.defaultRoot) {
        self.root = root
    }

    public var enginesDir: URL { root.appending(path: "Engine", directoryHint: .isDirectory) }
    public var prefixDir: URL { root.appending(path: "Prefix", directoryHint: .isDirectory) }
    public var cacheDir: URL { root.appending(path: "Cache", directoryHint: .isDirectory) }
    public var logsDir: URL { root.appending(path: "Logs", directoryHint: .isDirectory) }
    public var prefixMarker: URL { prefixDir.appending(path: PrefixMarker.fileName) }

    public func engineDir(_ id: String) -> URL {
        enginesDir.appending(path: id, directoryHint: .isDirectory)
    }
}
