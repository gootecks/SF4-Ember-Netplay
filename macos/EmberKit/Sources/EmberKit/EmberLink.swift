import Foundation

public enum EmberLink {
    public enum Kind: String, Sendable, Equatable {
        case join = "join link"
        case tournament = "tournament link"
        case room = "room link"
        case discordConnect = "discord connect link"
    }

    private static let joinMaximumLength = 64
    private static let queryMaximumLength = 256
    private static let codeAlphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    private static let hex = Set("0123456789abcdef".utf8)

    public static func isAccepted(_ url: URL) -> Bool { kind(of: url) != nil }

    public static func kind(of url: URL) -> Kind? { kind(of: url.absoluteString) }

    public static func kind(of text: String) -> Kind? {
        let bytes = Array(text.utf8)
        if isJoin(bytes) { return .join }
        guard isPlain(bytes, maximum: queryMaximumLength), !bytes.contains(UInt8(ascii: "#")) else { return nil }
        if hasQuery(bytes, "ember://tournament/open", ("bridge", "match"), bridge: isBridgeId, other: isMatchId) { return .tournament }
        if hasQuery(bytes, "ember://room/open", ("bridge", "room"), bridge: isBridgeId, other: isRoomId) { return .room }
        if isConnect(bytes) { return .discordConnect }
        return nil
    }

    private static func isPlain(_ bytes: [UInt8], maximum: Int) -> Bool {
        !bytes.isEmpty && bytes.count <= maximum
            && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7E && $0 != UInt8(ascii: "%") && $0 != UInt8(ascii: "+") }
    }

    private static func startsWithFolded(_ bytes: [UInt8], _ prefix: String) -> Bool {
        let wanted = Array(prefix.utf8)
        guard bytes.count >= wanted.count else { return false }
        for (index, expected) in wanted.enumerated() {
            var symbol = bytes[index]
            if symbol >= 0x41 && symbol <= 0x5A { symbol += 0x20 }
            if symbol != expected { return false }
        }
        return true
    }

    private static func isJoin(_ bytes: [UInt8]) -> Bool {
        let prefix = "ember://join/"
        guard !bytes.isEmpty, bytes.count <= joinMaximumLength, bytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }),
            bytes.count > prefix.utf8.count, startsWithFolded(bytes, prefix)
        else { return false }
        var rest = Array(bytes.dropFirst(prefix.utf8.count))
        if rest.last == UInt8(ascii: "/") { rest.removeLast() }
        var symbols = 0
        for byte in rest {
            if byte == UInt8(ascii: "-") { continue }
            var symbol = byte
            if symbol >= 0x61 && symbol <= 0x7A { symbol -= 0x20 }
            if symbol == UInt8(ascii: "O") { symbol = UInt8(ascii: "0") }
            if symbol == UInt8(ascii: "I") || symbol == UInt8(ascii: "L") { symbol = UInt8(ascii: "1") }
            guard codeAlphabet.contains(symbol), symbols < 12 else { return false }
            symbols += 1
        }
        return symbols == 12
    }

    private static func isPrefixedId(_ text: String, _ prefix: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 40, text.hasPrefix(prefix + "_") else { return false }
        for (offset, symbol) in bytes.dropFirst(4).enumerated() {
            if [8, 13, 18, 23].contains(offset) {
                if symbol != UInt8(ascii: "-") { return false }
                continue
            }
            guard hex.contains(symbol) else { return false }
            if offset == 14 && symbol != UInt8(ascii: "4") { return false }
            if offset == 19 && ![UInt8(ascii: "8"), UInt8(ascii: "9"), UInt8(ascii: "a"), UInt8(ascii: "b")].contains(symbol) {
                return false
            }
        }
        return true
    }

    private static func isBridgeId(_ text: String) -> Bool { isPrefixedId(text, "brg") }
    private static func isMatchId(_ text: String) -> Bool { isPrefixedId(text, "emt") }
    private static func isRoomId(_ text: String) -> Bool { text.utf8.count == 32 && text.utf8.allSatisfy { hex.contains($0) } }

    private static func queryRest(_ bytes: [UInt8], _ prefix: String) -> String? {
        guard startsWithFolded(bytes, prefix) else { return nil }
        var rest = String(decoding: bytes.dropFirst(prefix.utf8.count), as: UTF8.self)
        if rest.hasPrefix("/?") { rest.removeFirst() }
        return rest
    }

    private static func hasQuery(
        _ bytes: [UInt8], _ prefix: String, _ names: (String, String),
        bridge: (String) -> Bool, other: (String) -> Bool
    ) -> Bool {
        guard var query = queryRest(bytes, prefix), query.hasPrefix("?") else { return false }
        query.removeFirst()
        if query.hasSuffix("/") { query.removeLast() }
        let parts = query.split(separator: "&", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        var first: String?
        var second: String?
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 2, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return false }
            let name = String(pair[0]), value = String(pair[1])
            if name == names.0 && first == nil { first = value }
            else if name == names.1 && second == nil { second = value }
            else { return false }
        }
        guard let first, let second else { return false }
        return bridge(first) && other(second)
    }

    private static func isConnect(_ bytes: [UInt8]) -> Bool {
        guard var rest = queryRest(bytes, "ember://discord/connect"), rest.hasPrefix("?bridge=") else { return false }
        rest.removeFirst(8)
        if rest.hasSuffix("/") { rest.removeLast() }
        return isBridgeId(rest)
    }
}
