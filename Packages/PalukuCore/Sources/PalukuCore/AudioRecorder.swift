@preconcurrency import AVFoundation
import Foundation

/// Microphone capture → 16 kHz mono Float32 samples (Whisper's input format).
public final class AudioRecorder: @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    public private(set) var isRecording = false
    /// 0…1 loudness, called ~20×/s on the audio thread.
    public var onLevel: (@Sendable (Float) -> Void)?

    public init() {}

    public var duration: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / Self.sampleRate
    }

    public func start() throws {
        guard !isRecording else { return }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw LLMError(message: "No microphone available (check System Settings › Privacy › Microphone)")
        }
        converter = AVAudioConverter(from: format, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops and returns everything captured.
    @discardableResult
    public func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock()
        defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        if let onLevel, !chunk.isEmpty {
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
            onLevel(min(1, rms * 12))
        }
    }
}

/// Lowers system output volume while recording, restores afterwards.
/// ponytail: uses AppleScript volume; per-app ducking needs a HAL plug-in.
public enum Ducker {
    nonisolated(unsafe) private static var saved: Int?

    public static func duck() {
        guard saved == nil, let v = run("output volume of (get volume settings)").flatMap({ Int($0) }), v > 15 else { return }
        saved = v
        _ = run("set volume output volume \(max(5, v / 4))")
    }

    public static func restore() {
        guard let v = saved else { return }
        saved = nil
        _ = run("set volume output volume \(v)")
    }

    private static func run(_ source: String) -> String? {
        var err: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue
    }
}
