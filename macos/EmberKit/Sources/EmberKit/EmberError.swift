import Foundation

public enum EmberError: Error, Equatable, LocalizedError {
    case manifestUnreadable(String)
    case launchFailed(tool: String, reason: String)
    case toolFailed(tool: String, status: Int32, stderr: String)
    case invalidChecksum(name: String)
    case downloadFailed(url: String, reason: String)
    case sha256Mismatch(url: String, expected: String, actual: String)
    case unsupportedArchiveFormat(String)
    case invalidInstallTarget(String)
    case pathTraversal(from: String, to: String)
    case installSourceMissing(String)
    case engineDirIncomplete(path: String, missing: String)
    case engineNotInstalled(path: String)
    case engineBinaryMissing(String)
    case dxvkMissing(path: String)
    case prefixRendererMismatch(existing: String, requested: String, path: String)
    case prefixIncomplete(path: String)
    case fileSystem(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .manifestUnreadable(let reason):
            "engine manifest unreadable: \(reason)"
        case .launchFailed(let tool, let reason):
            "could not launch \(tool): \(reason)"
        case .toolFailed(let tool, let status, let stderr):
            "\(tool) exited with status \(status)" + (stderr.isEmpty ? "" : ": \(stderr)")
        case .invalidChecksum(let name):
            "manifest sha256 for \(name) is missing or not 64 hex characters"
        case .downloadFailed(let url, let reason):
            "download failed: \(url) (\(reason))"
        case .sha256Mismatch(let url, let expected, let actual):
            "SHA-256 mismatch for \(url)\n  expected: \(expected)\n  actual:   \(actual)\n"
                + "The upstream file changed. Review it, then update the manifest sha256 deliberately."
        case .unsupportedArchiveFormat(let format):
            "unsupported archive format: \(format)"
        case .invalidInstallTarget(let target):
            "install target must start with engine: or prefix: (got \(target))"
        case .pathTraversal(let from, let to):
            "refusing path traversal in install step: \(from) -> \(to)"
        case .installSourceMissing(let path):
            "install source missing in archive: \(path)"
        case .engineDirIncomplete(let path, let missing):
            "\(path) exists but has no \(missing); remove it and retry"
        case .engineNotInstalled(let path):
            "engine not installed (\(path)); run the engine install first"
        case .engineBinaryMissing(let path):
            "engine binary missing or not executable: \(path)"
        case .dxvkMissing(let path):
            "DXVK d3d9.dll missing under \(path); reinstall the engine"
        case .prefixRendererMismatch(let existing, let requested, let path):
            "prefix already built with renderer=\(existing); delete \(path) to rebuild with \(requested)"
        case .prefixIncomplete(let path):
            "\(path) exists without a completed-build marker; remove it and retry"
        case .fileSystem(let path, let reason):
            "file system error at \(path): \(reason)"
        }
    }
}
