import XCTest

@testable import EmberKit

final class EmberLinkTests: XCTestCase {
    private let bridge = "brg_0dbc0598-2312-4ce3-9df8-e160330565e6"
    private let match = "emt_6f1c0d2a-6a9c-4f30-9c5e-0d8f4f0b9a12"
    private let room = "0123456789abcdef0123456789abcdef"

    private func kind(_ text: String) -> EmberLink.Kind? { EmberLink.kind(of: text) }

    func testJoinAccepted() {
        for text in ["ember://join/7K3M-0X1R-T9PZ", "EMBER://JOIN/7k3m-0x1r-t9pz/", "ember://join/7K3M0X1RT9PZ",
            "ember://join/7K3M-OXIR-T9PZ"] {
            XCTAssertEqual(kind(text), .join, text)
        }
        XCTAssertTrue(EmberLink.isAccepted(URL(string: "ember://join/7K3M-0X1R-T9PZ")!))
    }

    func testJoinRefused() {
        let refused = [
            "", "ember://join/", "ember://join", "ember:join/7K3M-0X1R-T9PZ", "ember:/join/7K3M-0X1R-T9PZ",
            "ember://tournament/7K3M-0X1R-T9PZ", "ember://join/7K3M-0X1R-T9PZ//", "ember://join/7K3M-0X1R-T9PZ?x=1",
            "ember://join/7K3M-0X1R-T9PZ#7K3M", "ember://join/7K3M%2D0X1R-T9PZ", "ember://user@join/7K3M-0X1R-T9PZ",
            "ember://join:80/7K3M-0X1R-T9PZ", "ember://join/../7K3M-0X1R-T9PZ", "ember://join/7K3M-0X1R-T9PZ extra",
            "\"ember://join/7K3M-0X1R-T9PZ\"", "https://embernetplay.link/j#7K3M-0X1R-T9PZ",
            "ember://join/7K3M-0X1R-T9P\u{E9}", "ember://join/7K3M-0X1R-T9PZ\n", "emberx://join/7K3M-0X1R-T9PZ",
            "ember://join/7K3M-0X1R-T9PU", "ember://join/7K3M-0X1R-T9P", "ember://join/7K3M-0X1R-T9PZZ",
            "ember://join/" + String(repeating: "-", count: 52) + "7K3M0X1RT9PZ",
        ]
        for text in refused { XCTAssertNil(kind(text), text) }
        XCTAssertNil(kind("ember://join/7K3M-0X1R-\u{0}T9PZ"))
    }

    func testTournamentAccepted() {
        let link = "ember://tournament/open?bridge=\(bridge)&match=\(match)"
        XCTAssertEqual(kind(link), .tournament)
        XCTAssertEqual(kind("ember://tournament/open?match=\(match)&bridge=\(bridge)"), .tournament)
        XCTAssertEqual(kind("EMBER://TOURNAMENT/OPEN/?bridge=\(bridge)&match=\(match)/"), .tournament)
    }

    func testTournamentRefused() {
        let link = "ember://tournament/open?bridge=\(bridge)&match=\(match)"
        let refused = [
            "ember://tournament/open", "ember://tournament/open?", "ember://tournament/open?bridge=\(bridge)",
            link + "&extra=1", link + "&match=\(match)", "ember://tournament/open?bridge=\(bridge)&bridge=\(bridge)",
            link + "#x", "ember://tournament/open?bridge=\(bridge)&match=\(match.dropLast())",
            "ember://tournament/open?bridge=\(bridge)&match=\(bridge)",
            "ember://tournament/open?bridge=\(bridge)&match=emt%5F6f1c0d2a-6a9c-4f30-9c5e-0d8f4f0b9a12",
            "ember://tournament/open?bridge=BRG_0DBC0598-2312-4CE3-9DF8-E160330565E6&match=\(match)",
            "ember://tournament/open?bridge=brg_0dbc0598-2312-3ce3-9df8-e160330565e6&match=\(match)",
            "ember://tournament/join?bridge=\(bridge)&match=\(match)",
            "ember://user@tournament/open?bridge=\(bridge)&match=\(match)", link + " ", link + "\n",
            "ember://tournament/open?bridge=\(bridge)&&match=\(match)",
            "ember://tournament/open?bridge==\(bridge)&match=\(match)",
            "ember://tournament/open?bridge=\(bridge)&handoff=\(match)", link + String(repeating: "A", count: 200),
        ]
        for text in refused { XCTAssertNil(kind(text), text) }
    }

    func testRoomAccepted() {
        XCTAssertEqual(kind("ember://room/open?bridge=\(bridge)&room=\(room)"), .room)
        XCTAssertEqual(kind("ember://room/open?room=\(room)&bridge=\(bridge)"), .room)
        XCTAssertEqual(kind("EMBER://ROOM/OPEN/?bridge=\(bridge)&room=\(room)/"), .room)
        XCTAssertEqual(kind("Ember://Room/Open?bridge=\(bridge)&room=\(room)"), .room)
    }

    func testRoomRefused() {
        let link = "ember://room/open?bridge=\(bridge)&room=\(room)"
        let refused = [
            "ember://room/open", "ember://room/open?", "ember://room/open?bridge=\(bridge)", "ember://room/open?room=\(room)",
            link + "&extra=1", link + "&room=\(room)", "ember://room/open?room=\(room)&room=\(room)", link + "#x",
            link + " ", link + "\n", " " + link, "ember://room/open?bridge=\(bridge)&room=\(room.dropLast())",
            link + "0", "ember://room/open?bridge=\(bridge)&room=0123456789ABCDEF0123456789ABCDEF",
            "ember://room/open?bridge=\(bridge)&room=0123456789abcdef0123456789abcdeg",
            "ember://room/open?bridge=\(bridge)&room=\(bridge)", "ember://room/open?bridge=\(bridge)&room=\(match)",
            "ember://room/open?bridge=\(bridge)&room=0123456789abcdef0123456789abcde%66",
            "ember://room/open?bridge=\(match)&room=\(room)", "ember://room/open?bridge=\(bridge)&match=\(room)",
            "ember://room/open?Bridge=\(bridge)&room=\(room)", "ember://room/open?bridge=\(bridge)&room=",
            "ember://room/join?bridge=\(bridge)&room=\(room)", "ember://room/openx?bridge=\(bridge)&room=\(room)",
            "ember://user@room/open?bridge=\(bridge)&room=\(room)", "ember://room:80/open?bridge=\(bridge)&room=\(room)",
            "ember://room/open/../open?bridge=\(bridge)&room=\(room)", "ember:room/open?bridge=\(bridge)&room=\(room)",
            "ember://tournament/open?bridge=\(bridge)&room=\(room)", link + String(repeating: "A", count: 200),
        ]
        for text in refused { XCTAssertNil(kind(text), text) }
    }

    func testConnect() {
        let link = "ember://discord/connect?bridge=\(bridge)"
        XCTAssertEqual(kind(link), .discordConnect)
        XCTAssertEqual(kind("EMBER://DISCORD/CONNECT/?bridge=\(bridge)/"), .discordConnect)
        let refused = [
            "ember://discord/connect", "ember://discord/connect?", "ember://discord/connect?bridge=",
            link + "&extra=1", link + "&bridge=\(bridge)", link + "#x", link + " ", link + "\n",
            "ember://discord/connect?bridge=\(bridge.dropLast())", "ember://discord/connect?bridge=\(match)",
            "ember://discord/connect?bridge=BRG_0DBC0598-2312-4CE3-9DF8-E160330565E6",
            "ember://discord/connect?bridge=brg%5F0dbc0598-2312-4ce3-9df8-e160330565e6",
            "ember://discord/connect?Bridge=\(bridge)", "ember://discord/connect?match=\(bridge)",
            "ember://discord/connectx?bridge=\(bridge)", "ember://discord/remove?bridge=\(bridge)",
            "ember://user@discord/connect?bridge=\(bridge)", "ember://tournament/open?bridge=\(bridge)",
            "https://embernetplay.link/start#\(bridge)", link + String(repeating: "A", count: 200),
        ]
        for text in refused { XCTAssertNil(kind(text), text) }
    }

    func testKindsAreLogSafe() {
        XCTAssertEqual(EmberLink.Kind.join.rawValue, "join link")
    }
}
