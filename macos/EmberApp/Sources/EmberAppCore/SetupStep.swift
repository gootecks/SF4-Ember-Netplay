import Foundation

public enum SetupStep: String, CaseIterable, Sendable, Identifiable {
    case rosetta
    case engine
    case prefix
    case steam
    case login
    case game
    case ember

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rosetta: "Rosetta 2"
        case .engine: "Wine engine"
        case .prefix: "Wine prefix"
        case .steam: "Steam"
        case .login: "Steam login"
        case .game: "Ultra Street Fighter IV"
        case .ember: "Ember"
        }
    }

    public var detail: String {
        switch self {
        case .rosetta: "The Wine engine is Intel code and needs Rosetta 2."
        case .engine: "Download and install the pinned Wine engine."
        case .prefix: "Create the Windows environment Ember runs in."
        case .steam: "Install Steam inside that environment."
        case .login: "Sign in to Steam once. Ember closes Steam afterwards."
        case .game: "Use your copy of the game, or let Steam install it."
        case .ember: "Download the Ember netplay payload."
        }
    }
}

public enum StepState: Equatable, Sendable {
    case pending
    case running
    case done
    case needsInput
    case failed(String)
}

public enum GameChoice: Equatable, Sendable {
    case existing(URL)
    case install
}

public enum SetupError: Error, Equatable, LocalizedError {
    case rosettaMissing
    case noGameChoice

    public var errorDescription: String? {
        switch self {
        case .rosettaMissing: "Rosetta 2 is not installed."
        case .noGameChoice: "Choose how to get the game first."
        }
    }
}
