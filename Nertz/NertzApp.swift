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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if engine.phase == .menu {
                MenuView(engine: engine, gameCenter: gameCenter)
                    .transition(.opacity)
            } else {
                TableView(engine: engine)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: engine.phase == .menu)
        .onChange(of: scenePhase) { _, newPhase in
            // Leaving the app pauses the table; the player resumes by hand.
            if newPhase != .active {
                engine.setPaused(true)
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
                    difficulty: args.contains("-frantic") ? .frantic : .classic
                )
                engine.newMatch()
            }
        }
    }
}
