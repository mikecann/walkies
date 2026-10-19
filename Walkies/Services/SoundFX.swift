import AVFoundation

/// The celebration's sound effects, made in code rather than shipped as files: soft
/// "bloop" pops that climb a pentatonic scale as tiles turn up, a bell chime for a
/// secret, a little fanfare for the summary and a tick for counting up. Ambient, so
/// they respect the silent switch and play over a podcast rather than stopping it.
final class SoundFX {
    enum Sound: Hashable {
        /// The nth tile in a run, climbing in pitch.
        case pop(Int)
        case chime
        case fanfare
        case tick
    }

    static let shared = SoundFX()

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var ready = false

    /// Gets the engine going. Call before the first sound so there's no lag on it.
    func prepare() {
        guard !ready else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        for _ in 0..<6 {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
        }
        engine.mainMixerNode.outputVolume = 0.7
        do {
            try engine.start()
            players.forEach { $0.play() }
            ready = true
        } catch {
            ready = false
        }
    }

    func play(_ sound: Sound) {
        prepare()
        guard ready else { return }
        let buffer = buffers[sound] ?? make(sound)
        buffers[sound] = buffer
        let player = players[next]
        next = (next + 1) % players.count
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    // MARK: Making the sounds

    /// A major pentatonic scale from C5, so any run of pops sounds pleasant.
    private static let pentatonic: [Double] = [0, 2, 4, 7, 9]

    private func make(_ sound: Sound) -> AVAudioPCMBuffer {
        switch sound {
        case .pop(let n):
            let step = min(n, 14)
            let semitones = Double(step / 5) * 12 + Self.pentatonic[step % 5]
            let f = 523.25 * pow(2, semitones / 12)
            return render(seconds: 0.22) { t in
                // A quick upward bend into the note, like a bubble.
                let bend = 1 - 0.25 * exp(-t * 60)
                let phase = 2 * .pi * f * bend * t
                let envelope = min(1, t * 400) * exp(-t * 18)
                return (sin(phase) + 0.25 * sin(2 * phase)) * envelope * 0.55
            }
        case .chime:
            // C6, E6, G6, C7 in turn, each a little bell.
            let notes = [1046.5, 1318.5, 1568.0, 2093.0]
            return render(seconds: 1.6) { t in
                var sample = 0.0
                for (i, f) in notes.enumerated() {
                    let start = Double(i) * 0.09
                    guard t >= start else { continue }
                    let u = t - start
                    let bell = sin(2 * .pi * f * u) + 0.4 * sin(2 * .pi * f * 2.76 * u) * exp(-u * 6) + 0.2 * sin(2 * .pi * f * 5.4 * u) * exp(-u * 10)
                    sample += bell * min(1, u * 300) * exp(-u * 3.2) * 0.22
                }
                return sample
            }
        case .fanfare:
            // A rising C major arpeggio that lands on a held chord.
            let arpeggio = [523.25, 659.25, 783.99]
            let chord = [523.25, 659.25, 783.99, 1046.5]
            return render(seconds: 1.8) { t in
                var sample = 0.0
                for (i, f) in arpeggio.enumerated() {
                    let start = Double(i) * 0.11
                    guard t >= start, t < start + 0.3 else { continue }
                    let u = t - start
                    sample += Self.brass(f, u) * min(1, u * 200) * exp(-u * 8) * 0.3
                }
                if t >= 0.33 {
                    let u = t - 0.33
                    for f in chord { sample += Self.brass(f, u) * min(1, u * 60) * exp(-u * 1.6) * 0.14 }
                }
                return sample
            }
        case .tick:
            return render(seconds: 0.04) { t in
                sin(2 * .pi * 2400 * t) * exp(-t * 160) * 0.25
            }
        }
    }

    /// A bright, slightly buzzy tone: a few odd and even harmonics.
    private static func brass(_ f: Double, _ t: Double) -> Double {
        sin(2 * .pi * f * t) + 0.5 * sin(4 * .pi * f * t) + 0.25 * sin(6 * .pi * f * t) + 0.12 * sin(8 * .pi * f * t)
    }

    private func render(seconds: Double, _ sample: (Double) -> Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / format.sampleRate
            // A short fade at the very end so nothing clicks.
            let tail = min(1, (seconds - t) / 0.01)
            data[i] = Float(max(-1, min(1, sample(t) * tail)))
        }
        return buffer
    }
}
