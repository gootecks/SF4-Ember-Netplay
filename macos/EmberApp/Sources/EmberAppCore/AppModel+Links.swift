import EmberKit
import Foundation

public enum LinkResult: Equatable, Sendable {
    case refused
    case deferred
    case launched
    case failed
}

extension AppModel {
    @discardableResult
    public func handle(link url: URL) async -> LinkResult {
        guard let kind = EmberLink.kind(of: url) else {
            record("refused a link that is not a valid Ember link")
            return .refused
        }
        record("received a \(kind.rawValue)")
        if phase == .checking { await refreshSetup() }
        guard phase == .ready else {
            pendingLink = url.absoluteString
            pendingLinkKind = kind
            record("kept the \(kind.rawValue) until setup is complete")
            return .deferred
        }
        guard busy == nil else {
            notice = Notice("Ember is busy; open the link again in a moment.", isError: true)
            record("dropped the \(kind.rawValue): busy")
            return .failed
        }
        return await launch(joinLink: url.absoluteString, label: kind.rawValue) ? .launched : .failed
    }

    func launchPendingLink() async {
        guard let link = pendingLink, let url = URL(string: link), let kind = pendingLinkKind else { return }
        pendingLink = nil
        pendingLinkKind = nil
        record("using the kept \(kind.rawValue)")
        _ = await launch(joinLink: url.absoluteString, label: kind.rawValue)
    }
}
