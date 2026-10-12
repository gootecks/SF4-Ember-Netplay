import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

public struct EngineManifest: Codable, Sendable, Equatable {
    public struct Engine: Codable, Sendable, Equatable {
        public var wine: String
        public var wineserver: String
        public var wineboot: String?
        public var dxvkDllPathPrepend: String
    }

    public struct InstallStep: Codable, Sendable, Equatable {
        public var from: String
        public var to: String
    }

    public struct Component: Codable, Sendable, Equatable {
        public var name: String
        public var version: String?
        public var license: String?
        public var url: String
        public var sha256: String
        public var format: String
        public var install: [InstallStep]?
    }

    public struct RegistryEntry: Codable, Sendable, Equatable {
        public var key: String
        public var name: String?
        public var type: String
        public var data: String
    }

    public struct Prefix: Codable, Sendable, Equatable {
        public var windowsVersion: String?
        public var dllOverrides: [String: String]?
        public var env: [String: String]?
        public var registry: [RegistryEntry]?
    }

    public struct Fallback: Codable, Sendable, Equatable {
        public var renderer: String?
        public var dllOverrides: [String: String]?
        public var env: [String: String]?
        public var notes: String?
    }

    public struct Steam: Codable, Sendable, Equatable {
        public var setupUrl: String
        public var sha256: String
        public var installArgs: [String]
        public var hiddenArgs: [String]
        public var readyTimeoutSeconds: Int
    }

    public struct Ember: Codable, Sendable, Equatable {
        public var version: String
        public var repo: String
        public var asset: String
        public var url: String
        public var sha256: String
    }

    public struct Game: Codable, Sendable, Equatable {
        public var steamAppId: Int
        public var build: Int
        public var ssfivSha256: String
    }

    public var schemaVersion: Int
    public var id: String
    public var reference: JSONValue?
    public var engine: Engine
    public var components: [Component]
    public var prefix: Prefix
    public var fallback: Fallback?
    public var steam: Steam?
    public var ember: Ember?
    public var game: Game?

    public static let bundledResourceName = "m0-manifest-1.1.2-r23"

    public static func bundled() throws -> EngineManifest {
        guard let url = Bundle.module.url(forResource: bundledResourceName, withExtension: "json") else {
            throw EmberError.manifestUnreadable("bundled \(bundledResourceName).json not found")
        }
        return try load(from: url)
    }

    public static func load(from url: URL) throws -> EngineManifest {
        do {
            return try decode(Data(contentsOf: url))
        } catch let error as EmberError {
            throw error
        } catch {
            throw EmberError.manifestUnreadable("\(url.path): \(error.localizedDescription)")
        }
    }

    public static func decode(_ data: Data) throws -> EngineManifest {
        do {
            return try JSONDecoder().decode(EngineManifest.self, from: data)
        } catch {
            throw EmberError.manifestUnreadable(String(describing: error))
        }
    }
}
