import AVFoundation
import UIKit

/// Real card foley played back as samples — no synthesis. Every action makes
/// the same single soft "tick": one real card tap — the most compact tap in
/// Kenney's CC0 "Casino Audio" pack, gently low-passed and normalized — with
/// three subtle pitch variants so repeats don't feel mechanical. Tapping your
/// own stock/waste deck is silent. Six voices allow rapid overlapping plays
/// (dealing). Uses the .ambient session category: respects the silent switch
/// and mixes with the user's own music.
@MainActor
enum Sound {

    enum Kind: CaseIterable {
        case place      // your card lands on a work pile
        case score      // your card lands on a foundation
        case flip       // stock cards turning onto the waste
        case opponent   // an opponent's card lands on the table
        case deal       // cards dealt at round start
    }

    /// The sample variants and playback level for each event. Tune softness
    /// here: swap the file sets (place/shove/slide) or nudge the volumes.
    private static func config(_ kind: Kind) -> (files: [String], volume: Float) {
        switch kind {
        case .place:    return (["card-tick-1", "card-tick-2", "card-tick-3"], 0.55)
        case .score:    return (["card-tick-1", "card-tick-2", "card-tick-3"], 0.55)
        case .flip:     return ([], 0.0)   // tapping your stock/waste deck is silent
        case .opponent: return (["card-tick-1", "card-tick-2", "card-tick-3"], 0.40)
        case .deal:     return (["card-tick-1", "card-tick-2", "card-tick-3"], 0.35)
        }
    }

    private static var engine = AVAudioEngine()
    private static var players: [AVAudioPlayerNode] = []
    private static var buffers: [String: AVAudioPCMBuffer] = [:]
    private static var nextPlayer = 0
    private static var ready = false
    // An interruption (phone call, alarm, Siri) leaves the engine in a state
    // where `isRunning` can read true yet no audio renders — so that flag alone
    // can't be trusted. This latches "the graph is dead, rebuild it" until a
    // rebuild actually succeeds.
    private static var needsRestart = false

    static func start() {
        guard !ready else { return }
        loadBuffers()
        guard buildEngine() else { return }
        ready = true
        installRecoveryObservers()
    }

    /// Load every referenced sample once. They're all the same format (mono
    /// 44.1k) and stay valid across engine rebuilds, so this runs a single time.
    private static func loadBuffers() {
        guard buffers.isEmpty else { return }
        let names = Set(Kind.allCases.flatMap { config($0).files })
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "caf"),
                  let file = try? AVAudioFile(forReading: url) else { continue }
            let fmt = file.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt,
                                                frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil else { continue }
            buffers[name] = buffer
        }
    }

    /// Build a FRESH engine + player nodes and start playback. After an
    /// interruption (phone call, alarm, Siri) the old engine's route to the
    /// hardware output can be dead even though `isRunning` reads true and
    /// start() throws nothing — restarting that same object stays silent. Only
    /// a brand-new AVAudioEngine reconnects to the hardware. Buffers are
    /// format-only data, so they're reused. Returns whether audio came up live.
    private static func buildEngine() -> Bool {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)

        guard let format = buffers.values.first?.format else { return false }

        let fresh = AVAudioEngine()
        var newPlayers: [AVAudioPlayerNode] = []
        for _ in 0..<6 {                       // six voices for overlapping plays
            let node = AVAudioPlayerNode()
            fresh.attach(node)
            fresh.connect(node, to: fresh.mainMixerNode, format: format)
            newPlayers.append(node)
        }
        fresh.mainMixerNode.outputVolume = 0.8

        do {
            try fresh.start()
        } catch {
            return false
        }
        newPlayers.forEach { $0.play() }
        engine = fresh
        players = newPlayers
        nextPlayer = 0
        return true
    }

    /// Called when the player resumes a paused game — a guaranteed-foreground,
    /// interruption-is-over moment, and so the most reliable place to revive
    /// audio a phone call, alarm, or Siri tore down. Forces a rebuild
    /// regardless of whether the system interruption notifications fired.
    static func resume() {
        guard ready else { return }
        needsRestart = true
        recover()
    }

    static func play(_ kind: Kind) {
        guard ready else { return }
        // Self-heal: an interruption tears the engine down and iOS won't
        // rebuild it for us. Revive it on the next play if needed.
        if needsRestart || !engine.isRunning { recover() }
        guard engine.isRunning else { return }
        let cfg = config(kind)
        guard let name = cfg.files.randomElement(), let buffer = buffers[name] else { return }
        let node = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        node.volume = cfg.volume
        node.scheduleBuffer(buffer, at: nil)
    }

    // MARK: - Interruption recovery

    /// Rebuild the engine after an interruption (phone call, alarm, Siri) or
    /// route change. Triggered when the interruption ends, when the player
    /// resumes a paused game, when the app returns to the foreground, and
    /// lazily from play() as a last resort.
    private static func recover() {
        guard ready, needsRestart || !engine.isRunning else { return }
        // Tear the old engine down and build a brand-new one. A bare stop/start
        // of the same object comes back isRunning=true yet silent — the
        // interruption severed its hardware output route and only a fresh
        // engine reconnects. If the build fails (interruption still active),
        // stay latched and retry on interruption-ended / resume() / next play().
        engine.stop()
        if buildEngine() { needsRestart = false }
    }

    private static func installRecoveryObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                switch type {
                case .began:
                    // Graph is dead now even though isRunning may still read
                    // true; latch a rebuild for when the interruption ends.
                    Sound.needsRestart = true
                case .ended:
                    Sound.recover()
                @unknown default:
                    break
                }
            }
        }
        center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil, queue: .main
        ) { _ in
            // Route changes (AirPods in/out) can stop the engine. Don't force a
            // rebuild here — recover() only acts if it actually went down, or
            // the fresh engine's own config-change would loop us. object: nil
            // because the engine instance changes on every rebuild.
            Task { @MainActor in Sound.recover() }
        }
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            // Backstop: if .ended never arrived (app was backgrounded for the
            // whole call), recover on the way back in.
            Task { @MainActor in Sound.recover() }
        }
    }
}
