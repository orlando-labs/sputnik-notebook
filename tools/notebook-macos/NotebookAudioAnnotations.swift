import Foundation
import AVFoundation
import Accelerate
import CoreGraphics

struct NotebookAudioAnnotations: Codable, Equatable {
    var version = 1
    let asset: String, source: String, channel: String
    let cell: UInt64
    let sample_rate: Int, channels: Int, frames: Int
    var transcript = ""
    var classes: [AudioClass] = []
    var segments: [Segment] = []
    typealias AudioClass = NotebookAnnotationClass
    typealias Attribute = NotebookAnnotationAttribute
    struct Segment: Codable, Identifiable, Equatable {
        var id = UUID().uuidString
        var title = ""
        var start_frame: Int, end_frame: Int
        var low_hz: Double? = nil, high_hz: Double? = nil
        var classes: [String] = []
        var attributes: [String: [String: NotebookTableValue]] = [:]
        var transcript = ""
    }
    func matches(_ data: Data) -> Bool { asset == notebookAssetID(data) }
    mutating func normalizeClasses() {
        for index in segments.indices {
            segments[index].classes.removeAll { key in !classes.contains { $0.id == key } }
            segments[index].attributes = notebookAnnotationAttributes(classes: segments[index].classes, values: segments[index].attributes, definitions: classes)
        }
    }
}

struct NotebookAudioAnnotationDraft {
    private(set) var value: NotebookAudioAnnotations
    private(set) var undo: [NotebookAudioAnnotations] = []
    private(set) var redo: [NotebookAudioAnnotations] = []
    mutating func replace(_ next: NotebookAudioAnnotations) {
        guard value != next else { return }
        undo.append(value)
        // Bound history by encoded size as well as edit count.
        while undo.count > 30 || (undo.count > 1 && undo.reduce(0, { $0 + ((try? JSONEncoder().encode($1).count) ?? 0) }) > 8 * 1024 * 1024) { undo.removeFirst() }
        value = next; redo = []
    }
    mutating func undoEdit() { guard let previous = undo.popLast() else { return }; redo.append(value); value = previous }
    mutating func redoEdit() { guard let next = redo.popLast() else { return }; undo.append(value); value = next }
}

struct NotebookAudioViewport: Equatable {
    var start: Int, end: Int
    var low: Double, high: Double
    var length: Int { max(1, end - start) }
    func zoom(_ scale: Double, frames: Int, anchor: Double = 0.5) -> Self {
        let count = min(frames, max(1, Int((Double(length) / scale).rounded())))
        let first = min(frames - count, max(0, start + Int(Double(length - count) * anchor)))
        return .init(start: first, end: first + count, low: low, high: high)
    }
    func panned(_ delta: Int, frames: Int) -> Self {
        let first = max(0, min(frames - length, start + delta))
        return .init(start: first, end: first + length, low: low, high: high)
    }
    func segment(from a: CGPoint, to b: CGPoint, size: CGSize, spectral: Bool) -> NotebookAudioAnnotations.Segment? {
        guard size.width > 0, size.height > 0 else { return nil }
        func frame(_ x: Double) -> Int { min(end, max(start, start + Int((x / size.width * Double(length)).rounded()))) }
        let first = min(frame(a.x), frame(b.x)), last = max(frame(a.x), frame(b.x))
        guard first < last else { return nil }
        var segment = NotebookAudioAnnotations.Segment(start_frame: first, end_frame: last)
        if spectral {
            func hz(_ y: Double) -> Double { max(low, min(high, high - y / size.height * (high - low))) }
            segment.low_hz = min(hz(a.y), hz(b.y)); segment.high_hz = max(hz(a.y), hz(b.y))
            guard segment.low_hz! < segment.high_hz! else { return nil }
        }
        return segment
    }
}

struct NotebookAudioAnalysis {
    let rate: Int
    let samples: [[Float]]
    var frames: Int { samples.first?.count ?? 0 }
    var channels: Int { samples.count }
    var duration: Double { Double(frames) / Double(rate) }
    static func decode(_ payload: NotebookAudioPayload) throws -> Self {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(payload.format)
        defer { try? FileManager.default.removeItem(at: url) }
        try payload.data.write(to: url, options: .atomic)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate, channels = Int(file.processingFormat.channelCount), length = file.length
        guard rate >= 8000, rate <= 192000, rate.rounded() == rate, (1...2).contains(channels), length > 0,
              length <= Int64((16 * 1024 * 1024 - 64) / (channels * 4)) else { throw failure("Annotation audio requires mono/stereo, 8–192 kHz, at most 16 MiB decoded PCM.") }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else { throw failure("Cannot allocate audio decode buffer.") }
        var samples = [[Float]](repeating: [], count: channels)
        for index in samples.indices { samples[index].reserveCapacity(Int(length)) }
        while samples[0].count < length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(16384, Int(length) - samples[0].count)))
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { throw failure("Audio ended before its declared frame count.") }
            for channel in 0..<channels {
                let incoming = UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength))
                guard incoming.allSatisfy(\.isFinite) else { throw failure("Audio contains non-finite samples.") }
                samples[channel].append(contentsOf: incoming)
            }
        }
        return .init(rate: Int(rate), samples: samples)
    }
    func channel(_ index: Int) -> [Float] {
        if samples.indices.contains(index) { return samples[index] }
        guard samples.count == 2 else { return samples[0] }
        return zip(samples[0], samples[1]).map { ($0 + $1) / 2 }
    }
    static func failure(_ text: String) -> NSError { .init(domain: "NotebookAudioAnnotations", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

struct NotebookAudioRender {
    struct Peak { let minimum: Float, maximum: Float }
    let waveform: [Peak]
    let spectrogram: CGImage?
    static func waveform(_ samples: [Float], viewport: NotebookAudioViewport, width: Int) -> [Peak] {
        let count = min(viewport.length, max(1, width))
        return (0..<count).map { index in
            let first = viewport.start + index * viewport.length / count
            let last = max(first + 1, viewport.start + (index + 1) * viewport.length / count)
            var minimum = Float.infinity, maximum = -Float.infinity
            for value in samples[first..<min(samples.count, last)] { minimum = min(minimum, value); maximum = max(maximum, value) }
            return Peak(minimum: minimum.isFinite ? minimum : 0, maximum: maximum.isFinite ? maximum : 0)
        }
    }
    static func fftDB(_ samples: [Float], center: Int, size: Int, setup: FFTSetup) -> [Float] {
        let half = size / 2
        var real = [Float](repeating: 0, count: half), imaginary = real
        var weight: Float = 0
        for index in 0..<size {
            let window = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(size)))
            weight += window
            let source = center - half + index
            let value = samples.indices.contains(source) ? samples[source] * window : 0
            if index % 2 == 0 { real[index / 2] = value } else { imaginary[index / 2] = value }
        }
        return real.withUnsafeMutableBufferPointer { r in imaginary.withUnsafeMutableBufferPointer { i in
            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
            vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(size))), FFTDirection(FFT_FORWARD))
            var db = [Float](repeating: -120, count: half + 1)
            for bin in 0...half {
                let power: Float
                if bin == 0 { power = abs(r[0]) / (2 * weight) }
                else if bin == half { power = abs(i[0]) / (2 * weight) }
                else { power = hypot(r[bin], i[bin]) / weight }
                db[bin] = max(-120, min(0, 20 * log10(max(0.000001, power))))
            }
            return db
        } }
    }
    static func build(samples: [Float], rate: Int, viewport: NotebookAudioViewport, fftSize: Int, spectral: Bool, floorDB: Double, width: Int = 1100) throws -> Self {
        let waveform = waveform(samples, viewport: viewport, width: width)
        guard spectral else { return .init(waveform: waveform, spectrogram: nil) }
        guard [256, 512, 1024, 2048, 4096].contains(fftSize), let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize))), FFTRadix(kFFTRadix2)) else { throw NotebookAudioAnalysis.failure("Cannot create system FFT.") }
        defer { vDSP_destroy_fftsetup(setup) }
        let columns = max(1, min(1400, width)), rows = min(768, fftSize / 2 + 1)
        var rgba = [UInt8](repeating: 255, count: columns * rows * 4)
        for x in 0..<columns {
            if x % 32 == 0 { try Task.checkCancellation() }
            let center = viewport.start + Int((Double(x) + 0.5) / Double(columns) * Double(viewport.length))
            let db = fftDB(samples, center: center, size: fftSize, setup: setup)
            for y in 0..<rows {
                let frequency = viewport.high - (Double(y) + 0.5) / Double(rows) * (viewport.high - viewport.low)
                let bin = max(0, min(db.count - 1, Int((frequency * Double(fftSize) / Double(rate)).rounded())))
                let color = NotebookPlasma.rgb(Double((db[bin] - Float(floorDB)) / Float(-floorDB)))
                let offset = (y * columns + x) * 4
                rgba[offset] = color.0; rgba[offset + 1] = color.1; rgba[offset + 2] = color.2
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData), let image = CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw NotebookAudioAnalysis.failure("Cannot render spectrogram.") }
        return .init(waveform: waveform, spectrogram: image)
    }
}
