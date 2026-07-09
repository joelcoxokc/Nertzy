import AVFoundation
import UIKit

/// Procedurally synthesized card sounds — no audio assets required.
/// Each sound is a bright band-passed "snap" (the card flexing as it's
/// slapped down) followed by a softer brush of noise (settling onto the
/// felt), with only a whisper of low body — papery, not thumpy. Four
/// random variants per sound so repeated plays feel physical rather than
/// mechanical. Uses the .ambient session category: respects the silent
/// switch and mixes with the user's own music.
@MainActor
enum Sound {

    enum Kind: CaseIterable {
        case place      // your card lands on a work pile
        case score      // your card lands on a foundation
        case flip       // stock cards turning onto the waste
        case opponent   // an opponent's card lands on the table
        case deal       // cards dealt at round start
    }

    private static let engine = AVAudioEngine()
    private static var players: [AVAudioPlayerNode] = []
    private static var buffers: [Kind: [AVAudioPCMBuffer]] = [:]
    private static var nextPlayer = 0
    private static var ready = false

    static func start() {
        guard !ready else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return }
        for _ in 0..<6 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            players.append(node)
        }
        engine.mainMixerNode.outputVolume = 0.9

        var rng = SystemRandomNumberGenerator()
        for kind in Kind.allCases {
            buffers[kind] = (0..<4).compactMap { _ in
                synthesize(kind, format: format, rng: &rng)
            }
        }
        do {
            try engine.start()
        } catch {
            return
        }
        players.forEach { $0.play() }
        ready = true
        installRecoveryObservers()
    }

    static func play(_ kind: Kind) {
        guard ready else { return }
        // Self-heal: a phone call or Siri stops the engine, and iOS won't
        // restart it for us. Revive it on the next play if needed.
        if !engine.isRunning { recover() }
        guard engine.isRunning,
              let variants = buffers[kind],
              let buffer = variants.randomElement() else { return }
        let node = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        node.scheduleBuffer(buffer, at: nil)
    }

    // MARK: - Interruption recovery

    /// Phone calls, Siri, and route changes (AirPods in/out) stop the
    /// engine. Restart it when the interruption ends, when the app returns
    /// to the foreground, and lazily from play() as a last resort.
    private static func recover() {
        guard ready, !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try engine.start()
        } catch {
            return
        }
        players.forEach { $0.play() }
    }

    private static func installRecoveryObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in Sound.recover() }
        }
        center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { _ in
            Task { @MainActor in Sound.recover() }
        }
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in Sound.recover() }
        }
    }

    // MARK: - Synthesis

    private struct Spec {
        let duration: Double    // seconds
        let snapTau: Double     // the snap's decay — shorter = crisper
        let hpFreq: Double      // band-pass low edge (Hz): cuts the boom
        let lpFreq: Double      // band-pass high edge (Hz): cuts the hiss
        let ticks: Int          // extra micro-snaps (several cards at once)
        let tickGap: Double     // seconds between micro-snaps
        let settleGain: Double  // the softer felt-brush after the snap
        let settleTau: Double
        let bodyFreq: Double    // faint knock of the table, 0 = none
        let bodyGain: Double
        let peak: Double        // normalized output level
    }

    private static func spec(for kind: Kind) -> Spec {
        switch kind {
        case .place:
            return Spec(duration: 0.085, snapTau: 0.0042, hpFreq: 1300, lpFreq: 6200,
                        ticks: 1, tickGap: 0, settleGain: 0.50, settleTau: 0.016,
                        bodyFreq: 290, bodyGain: 0.22, peak: 0.60)
        case .score:
            return Spec(duration: 0.090, snapTau: 0.0048, hpFreq: 1500, lpFreq: 7800,
                        ticks: 1, tickGap: 0, settleGain: 0.45, settleTau: 0.018,
                        bodyFreq: 330, bodyGain: 0.20, peak: 0.72)
        case .flip:
            // Three cards riffle past: three quick ticks, no table knock.
            return Spec(duration: 0.110, snapTau: 0.0030, hpFreq: 1700, lpFreq: 7500,
                        ticks: 3, tickGap: 0.024, settleGain: 0.30, settleTau: 0.012,
                        bodyFreq: 0, bodyGain: 0, peak: 0.42)
        case .opponent:
            return Spec(duration: 0.075, snapTau: 0.0040, hpFreq: 900, lpFreq: 4200,
                        ticks: 1, tickGap: 0, settleGain: 0.50, settleTau: 0.014,
                        bodyFreq: 260, bodyGain: 0.16, peak: 0.30)
        case .deal:
            return Spec(duration: 0.045, snapTau: 0.0026, hpFreq: 1500, lpFreq: 7000,
                        ticks: 1, tickGap: 0, settleGain: 0.25, settleTau: 0.009,
                        bodyFreq: 0, bodyGain: 0, peak: 0.24)
        }
    }

    private static func synthesize(
        _ kind: Kind,
        format: AVAudioFormat,
        rng: inout SystemRandomNumberGenerator
    ) -> AVAudioPCMBuffer? {
        let base = spec(for: kind)
        let sr = format.sampleRate
        let snapTau = base.snapTau * Double.random(in: 0.80...1.25, using: &rng)
        let tickGap = base.tickGap * Double.random(in: 0.85...1.20, using: &rng)
        let hpFreq = base.hpFreq * Double.random(in: 0.85...1.15, using: &rng)
        let lpFreq = base.lpFreq * Double.random(in: 0.85...1.15, using: &rng)
        let bodyFreq = base.bodyFreq * Double.random(in: 0.90...1.10, using: &rng)

        let frameCount = AVAudioFrameCount(sr * base.duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        let frames = Int(frameCount)
        let kLP = 1 - exp(-2 * .pi * lpFreq / sr)
        let kHP = 1 - exp(-2 * .pi * hpFreq / sr)
        // The settle starts just after the last tick's snap.
        let settleStart = Double(base.ticks - 1) * tickGap + 0.006
        var lp = 0.0
        var hpTrack = 0.0
        var maxAbs = 0.0001
        var raw = [Double](repeating: 0, count: frames)
        let releaseFrames = max(1.0, sr * 0.004)

        for i in 0..<frames {
            let t = Double(i) / sr
            // Snap envelope(s): each card edge is its own tiny transient.
            var env = 0.0
            for k in 0..<base.ticks {
                let dt = t - Double(k) * tickGap
                if dt >= 0 { env += exp(-dt / snapTau) * pow(0.7, Double(k)) }
            }
            // The card settling onto the felt — softer and a touch longer.
            if base.settleGain > 0, t >= settleStart {
                env += base.settleGain * exp(-(t - settleStart) / base.settleTau)
            }
            let excite = Double.random(in: -1...1, using: &rng) * env
            // Band-pass: keep the papery snap, drop the boom and the fizz.
            lp += kLP * (excite - lp)
            hpTrack += kHP * (lp - hpTrack)
            var sample = lp - hpTrack
            if bodyFreq > 0 {
                sample += base.bodyGain * sin(2 * .pi * bodyFreq * t) * exp(-t / 0.011)
            }
            sample *= min(1.0, Double(frames - i) / releaseFrames)
            raw[i] = sample
            maxAbs = max(maxAbs, abs(sample))
        }
        let gain = base.peak / maxAbs
        for i in 0..<frames {
            data[i] = Float(raw[i] * gain)
        }
        return buffer
    }
}
