import SwiftUI

@main
struct NertzApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @State private var engine = GameEngine()
    @State private var gameCenter = GameCenterManager()
    @State private var live = LiveSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if engine.phase == .menu {
                MenuView(engine: engine, gameCenter: gameCenter, live: live)
                    .transition(.opacity)
            } else {
                TableView(engine: engine)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: engine.phase == .menu)
        .onChange(of: scenePhase) { _, newPhase in
            // Leaving the app pauses the table; the player resumes by
            // hand. The match also goes to disk, so even a swipe-kill
            // from the app switcher can be picked back up.
            if newPhase != .active {
                engine.setPaused(true)
                engine.autosave()
            } else {
                // A trip to Messages killed any pending code-table
                // request — quietly re-open the same room. Same story
                // for an in-person room's radios.
                CodeMatchmaker.rearmIfNeeded()
                live.rearmIfNeeded()
            }
        }
        .onChange(of: gameCenter.session != nil) { _, hasSession in
            // Matchmaking and the lobby keep the screen awake — a locked
            // phone suspends the app and kills the P2P handshake.
            // (TableView manages the idle timer itself during play.)
            if hasSession {
                UIApplication.shared.isIdleTimerDisabled = true
            } else if engine.phase == .menu {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            // Opted in previously — sign in at every launch. (The
            // -gameCenterOn YES launch arg flips this for dev runs.)
            if UserDefaults.standard.bool(forKey: GameCenterManager.settingKey) {
                gameCenter.authenticate()
            }
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-autostart") {
                // Dev launches never touch the record book.
                StatsStore.shared.recordingEnabled = false
                engine.debugTinyNerts = args.contains("-quickround")
                engine.debugDemo = args.contains("-demo")
                if args.contains("-shortpiles") {
                    FoundationPile.completeCount = 3
                }
                engine.settings = GameSettings(
                    opponents: args.contains("-threebots") ? 3 : 2,
                    difficulty: args.contains("-frantic") ? .frantic : .classic,
                    targetScore: args.contains("-shortmatch") ? 1 : 100
                )
                engine.newMatch()
            } else if args.contains("-autoresume") {
                // Dev: skip the CONTINUE tap (simctl can't touch the screen).
                engine.resumeSavedMatch()
            }
            if args.contains("-livedemo") {
                // Dev: a staged in-person night for screenshots — no
                // radios, no disk, and no record book unless the run is
                // deliberately exercising the recorder.
                StatsStore.shared.recordingEnabled = args.contains("-liverecordtest")
                live.debugSeedDemo()
            }
        }
    }
}
