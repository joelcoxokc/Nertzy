import AVFoundation

/// Procedurally synthesized card sounds — no audio assets required.
/// Short filtered-noise bursts (the card hitting felt) layered with a low
/// sine thump. Four random variants per sound so repeated plays feel
/// physical rather than mechanical. Uses the .ambient session category:
/// respects the silent switch and mixes with the user's own music.
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
    }

    static func play(_ kind: Kind) {
        guard ready, engine.isRunning,
              let variants = buffers[kind],
              let buffer = variants.randomElement() else { return }
        let node = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        node.scheduleBuffer(buffer, at: nil)
    }

    // MARK: - Synthesis

    private struct Spec {
        let duration: Double    // seconds
        let noiseTau: Double    // noise envelope decay
        let lowpass: Double     // one-pole coefficient, higher = brighter
        let thumpFreq: Double   // low sine "body", 0 = none
        let thumpTau: Double
        let peak: Double        // normalized output level
    }

    private static func spec(for kind: Kind) -> Spec {
        switch kind {
        case .place:
            return Spec(duration: 0.070, noiseTau: 0.013, lowpass: 0.16, thumpFreq: 175, thumpTau: 0.020, peak: 0.62)
        case .score:
            return Spec(duration: 0.080, noiseTau: 0.015, lowpass: 0.24, thumpFreq: 245, thumpTau: 0.022, peak: 0.70)
        case .flip:
            return Spec(duration: 0.040, noiseTau: 0.008, lowpass: 0.30, thumpFreq: 0, thumpTau: 1, peak: 0.34)
        case .opponent:
            return Spec(duration: 0.060, noiseTau: 0.011, lowpass: 0.14, thumpFreq: 205, thumpTau: 0.018, peak: 0.30)
        case .deal:
            return Spec(duration: 0.035, noiseTau: 0.007, lowpass: 0.28, thumpFreq: 0, thumpTau: 1, peak: 0.22)
        }
    }

    private static func synthesize(
        _ kind: Kind,
        format: AVAudioFormat,
        rng: inout SystemRandomNumberGenerator
    ) -> AVAudioPCMBuffer? {
        let base = spec(for: kind)
        let sr = format.sampleRate
        let noiseTau = base.noiseTau * Double.random(in: 0.85...1.15, using: &rng)
        let thumpFreq = base.thumpFreq * Double.random(in: 0.92...1.08, using: &rng)

        let frameCount = AVAudioFrameCount(sr * base.duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        let frames = Int(frameCount)
        var lowpassed = 0.0
        var maxAbs = 0.0001
        var raw = [Double](repeating: 0, count: frames)
        let attackFrames = max(1.0, sr * 0.0012)
        let releaseFrames = max(1.0, sr * 0.004)

        for i in 0..<frames {
            let t = Double(i) / sr
            let noise = Double.random(in: -1...1, using: &rng) * exp(-t / noiseTau)
            lowpassed += base.lowpass * (noise - lowpassed)
            var sample = lowpassed * 1.6
            if thumpFreq > 0 {
                sample += 0.9 * sin(2 * .pi * thumpFreq * t) * exp(-t / base.thumpTau)
            }
            let attack = min(1.0, Double(i) / attackFrames)
            let release = min(1.0, Double(frames - i) / releaseFrames)
            sample *= attack * release
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
