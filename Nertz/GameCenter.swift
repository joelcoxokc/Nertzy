import SwiftUI
import GameKit
import Observation

// MARK: - Game Center (multiplayer Phase 1)

/// Authentication and matchmaking. Multiplayer is opt-in — the GAME
/// CENTER toggle on the menu — so solo players never see a sign-in
/// sheet. Once a match is found, the live table lives in `session`.
@MainActor
@Observable
final class GameCenterManager {

    /// UserDefaults key for the opt-in toggle (auth runs at launch when set).
    static let settingKey = "gameCenterOn"

    enum AuthState: Equatable {
        case off                // not attempted this launch
        case authenticating
        case authenticated
        case failed(String)
    }

    private(set) var auth: AuthState = .off
    /// The live online table, once matchmaking succeeds.
    var session: MatchSession?
    /// A friend's invite, delivered by the system — the menu presents
    /// matchmaking for it. (v1: honored from the menu only.)
    var pendingInvite: GKInvite?

    var localName: String { GKLocalPlayer.local.displayName }

    @ObservationIgnored private var inviteListener: InviteListener?

    func authenticate() {
        guard auth != .authenticated, auth != .authenticating else { return }
        auth = .authenticating
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            // GameKit calls back on the main thread, but hop to be sure —
            // and this handler can fire again later (sign-out, sign-in).
            Task { @MainActor in
                guard let self else { return }
                if let viewController {
                    Self.topViewController()?.present(viewController, animated: true)
                    return
                }
                if GKLocalPlayer.local.isAuthenticated {
                    self.auth = .authenticated
                    self.registerInviteListenerOnce()
                } else {
                    self.auth = .failed(friendlyAuthError(error))
                }
            }
        }
    }

    private func registerInviteListenerOnce() {
        guard inviteListener == nil else { return }
        let listener = InviteListener { [weak self] invite in
            self?.pendingInvite = invite
        }
        GKLocalPlayer.local.register(listener)
        inviteListener = listener
    }

    /// The view controller to hang GameKit's sheets off of.
    static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

private func friendlyAuthError(_ error: Error?) -> String {
    guard let error else { return "Game Center is unavailable" }
    let ns = error as NSError
    if ns.domain == GKErrorDomain, ns.code == GKError.notAuthenticated.rawValue {
        return "Sign in to Game Center in Settings"
    }
    return error.localizedDescription
}

/// GKLocalPlayerListener needs an NSObject; this tiny bridge keeps the
/// manager a plain @Observable class.
private final class InviteListener: NSObject, GKLocalPlayerListener {
    let onInvite: @MainActor (GKInvite) -> Void
    init(onInvite: @escaping @MainActor (GKInvite) -> Void) {
        self.onInvite = onInvite
    }
    func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        Task { @MainActor in self.onInvite(invite) }
    }
}

// MARK: - Apple's matchmaking sheet, wrapped for SwiftUI

/// Invite friends or auto-match — GKMatchmakerViewController does both.
/// `onEnd` gets nil on plain cancel, or a message on failure.
struct MatchmakerView: UIViewControllerRepresentable {
    let invite: GKInvite?
    let onMatch: (GKMatch) -> Void
    let onEnd: (String?) -> Void

    func makeUIViewController(context: Context) -> GKMatchmakerViewController {
        let vc: GKMatchmakerViewController
        if let invite, let inviteVC = GKMatchmakerViewController(invite: invite) {
            vc = inviteVC
        } else {
            let request = GKMatchRequest()
            request.minPlayers = 2
            request.maxPlayers = 4      // GKMatch's real-time cap — exactly one Nertz table
            request.defaultNumberOfPlayers = 2
            request.inviteMessage = "Nertz? First card down wins."
            vc = GKMatchmakerViewController(matchRequest: request) ?? GKMatchmakerViewController()
        }
        vc.matchmakerDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: GKMatchmakerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, GKMatchmakerViewControllerDelegate {
        let parent: MatchmakerView
        init(_ parent: MatchmakerView) { self.parent = parent }

        func matchmakerViewControllerWasCancelled(_ viewController: GKMatchmakerViewController) {
            parent.onEnd(nil)
        }
        func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFailWithError error: Error) {
            parent.onEnd(error.localizedDescription)
        }
        func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFind match: GKMatch) {
            parent.onMatch(match)
        }
    }
}
