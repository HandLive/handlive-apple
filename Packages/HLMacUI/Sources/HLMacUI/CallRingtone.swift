import AppKit
import Foundation

/// Plays and stops the incoming-call ringtone on the Mac; tests use a stub.
@MainActor
public protocol RingtonePlaying: AnyObject {
    var isPlaying: Bool { get }
    func start()
    func stop()
}

/// `NSSound` looping a ringtone HandLive synthesizes itself, so no third-party sound file ships with the app: a soft
/// two-note chime played twice, then a pause. The volume follows the system output volume; it stops by itself after
/// 60 s (CALL-01 field 10, API 5 logic 2).
@MainActor
public final class SystemRingtone: RingtonePlaying {
    public static let maxDuration: Duration = .seconds(60)
    public private(set) var isPlaying = false
    private var sound: NSSound?
    private var timeout: Task<Void, Never>?

    public init() {}

    public func start() {
        guard !isPlaying else { return }
        isPlaying = true
        let sound = NSSound(data: RingtoneSynthesizer.wav())
        sound?.loops = true
        sound?.play()
        self.sound = sound
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.maxDuration)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    public func stop() {
        timeout?.cancel()
        timeout = nil
        sound?.stop()
        sound = nil
        isPlaying = false
    }
}

/// The ringtone as a 16-bit mono PCM WAV file in memory.
enum RingtoneSynthesizer {
    static let sampleRate = 22_050

    /// Two notes (E5 then C5, 0.3 s each, soft attack and decay), repeated once, then 1.5 s of silence.
    static func wav() -> Data {
        var samples: [Int16] = []
        for _ in 0..<2 {
            samples += note(frequency: 659.25, seconds: 0.3) + silence(0.05)
            samples += note(frequency: 523.25, seconds: 0.3) + silence(0.25)
        }
        samples += silence(1.5)
        return header(sampleCount: samples.count) + samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func note(frequency: Double, seconds: Double) -> [Int16] {
        let count = Int(seconds * Double(sampleRate))
        return (0..<count).map { index in
            let time = Double(index) / Double(sampleRate)
            let attack = min(1, time / 0.01)
            let envelope = attack * exp(-4 * time / seconds)
            let tone = sin(2 * .pi * frequency * time) + 0.3 * sin(4 * .pi * frequency * time)
            return Int16((0.3 * envelope * tone / 1.3 * Double(Int16.max)).rounded())
        }
    }

    static func silence(_ seconds: Double) -> [Int16] {
        Array(repeating: 0, count: Int(seconds * Double(sampleRate)))
    }

    /// RIFF/WAVE header of a PCM stream of `sampleCount` 16-bit mono samples (little-endian).
    static func header(sampleCount: Int) -> Data {
        let dataBytes = UInt32(sampleCount * 2)
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF")
        append32(36 + dataBytes)
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1) // PCM
        append16(1) // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        append("data")
        append32(dataBytes)
        return data
    }
}
