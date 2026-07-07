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

    var body: some View {
        ZStack {
            if engine.phase == .menu {
                MenuView(engine: engine)
                    .transition(.opacity)
            } else {
                TableView(engine: engine)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: engine.phase == .menu)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-autostart") {
                engine.debugTinyNerts = args.contains("-quickround")
                engine.debugDemo = args.contains("-demo")
                if args.contains("-shortpiles") {
                    FoundationPile.completeCount = 3
                }
                engine.settings = GameSettings(
                    opponents: 2,
                    difficulty: args.contains("-frantic") ? .frantic : .classic
                )
                engine.newMatch()
            }
        }
    }
}
