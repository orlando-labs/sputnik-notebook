import AppKit
import AVFoundation
import Combine

struct NotebookAudioInput: Decodable {
    let sheet: String, id: String, name: String, revision: String
    let panels: [NotebookFigurePanel]
}

struct NotebookAudioControl: Decodable {
    let cell: String, channel: String
    let playback_revision: UInt64, seek_revision: UInt64, volume_revision: UInt64
    let playback: UInt32, position: Double, volume: Float
}

struct NotebookAudioStream: Decodable, Equatable, Identifiable {
    let id: String, caption: String
    let token: UInt64, revision: UInt64
    var offset: UInt64, frames: UInt64
    let rate: UInt32, channels: UInt32, sample_format: String
    var data: Data
    var replace: Bool
    let finished: Bool
    let position: Double, volume: Float, waveform: Bool, looped: Bool, autoplay: Bool
    var frameWidth: Int { Int(channels) * (sample_format == "s16le" ? 2 : 4) }
    var valid: Bool {
        token > 0 && revision > 0 && (8000...192000).contains(rate) && (1...2).contains(channels) &&
        ["s16le", "f32le"].contains(sample_format) && offset <= frames && frames <= UInt64((16 * 1024 * 1024 - 128) / frameWidth) &&
        data.count == Int(frames - offset) * frameWidth && (!replace || offset == 0) &&
        position.isFinite && position >= 0 && volume.isFinite && (0...1).contains(volume)
    }
    static func merge(_ previous: [Self], _ updates: [Self]) -> [Self] {
        var result = previous
        for var next in updates where next.valid {
            if let i = result.firstIndex(where: { $0.id == next.id }) {
                let old = result[i]
                if next.token == old.token && next.revision <= old.revision { continue }
                if !next.replace {
                    guard next.token == old.token, next.offset == old.frames, next.rate == old.rate,
                          next.channels == old.channels, next.sample_format == old.sample_format else { continue }
                    next.data = old.data + next.data; next.offset = 0; next.replace = true
                }
                result[i] = next
            } else if next.replace { result.append(next) }
        }
        return result
    }
    func wav() -> Data {
        var out = Data("RIFF".utf8)
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        u32(UInt32(36 + data.count)); out.append(Data("WAVEfmt ".utf8)); u32(16)
        u16(sample_format == "s16le" ? 1 : 3); u16(UInt16(channels)); u32(rate)
        u32(rate * UInt32(frameWidth)); u16(UInt16(frameWidth)); u16(sample_format == "s16le" ? 16 : 32)
        out.append(Data("data".utf8)); u32(UInt32(data.count)); out.append(data); return out
    }
}

struct NotebookAudioPayload {
    static let mime = "application/vnd.sputnik.audio"
    let format: String, data: Data
    let position: Double, volume: Float
    let waveform: Bool, loop: Bool, autoplay: Bool
    static func encode(_ data: Data, format: String) -> Data {
        var out = Data("SPKA1".utf8); out.append(1)
        var length = UInt32(format.utf8.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        for value in [0.0, 1.0] { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) } }
        out.append(Data(format.utf8)); out.append(data); return out
    }
    static func decode(_ data: Data) throws -> Self {
        func invalid() -> NSError { NSError(domain: "NotebookAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid audio display."]) }
        guard data.count >= 28, data.count <= 16 * 1024 * 1024,
              data.prefix(5) == Data("SPKA1".utf8), data[5] & 0xf8 == 0 else { throw invalid() }
        func integer(_ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | UInt64(data[offset + $1]) << (8 * $1) }
        }
        let size = Int(integer(6, 4))
        guard (1...16).contains(size), data.count > 26 + size,
              let format = String(data: data[26..<26 + size], encoding: .ascii),
              format.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) else { throw invalid() }
        let position = Double(bitPattern: integer(10, 8)), volume = Double(bitPattern: integer(18, 8))
        guard position.isFinite, position >= 0, volume.isFinite, (0...1).contains(volume) else { throw invalid() }
        return Self(format: format, data: Data(data[(26 + size)...]), position: position, volume: Float(volume),
                    waveform: data[5] & 1 != 0, loop: data[5] & 2 != 0, autoplay: data[5] & 4 != 0)
    }
}

struct NotebookDecodedAudio {
    let url: URL, duration: Double, rate: Double, channels: Int, peaks: [Float]
    static func prepare(_ payload: NotebookAudioPayload, waveform: Bool) throws -> Self {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(payload.format)
        do {
            try payload.data.write(to: url, options: .atomic)
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let rate = file.processingFormat.sampleRate, channels = Int(file.processingFormat.channelCount), frames = file.length
            guard rate.isFinite, rate > 0, (1...2).contains(channels), frames > 0,
                  frames <= Int64(32 * 1024 * 1024 / (channels * 4)) else {
                throw NSError(domain: "NotebookAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio exceeds the 32 MiB decoded mono/stereo limit."])
            }
            let duration = Double(frames) / rate
            guard payload.position <= duration else {
                throw NSError(domain: "NotebookAudio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Player position exceeds the track duration."])
            }
            var peaks = [Float](repeating: 0, count: waveform ? min(2048, Int(frames)) : 0)
            if waveform, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) {
                var offset: Int64 = 0
                while offset < frames {
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(min(16384, frames - offset)))
                    guard buffer.frameLength > 0, let samples = buffer.floatChannelData else { break }
                    for i in 0..<Int(buffer.frameLength) {
                        let bucket = min(peaks.count - 1, Int((offset + Int64(i)) * Int64(peaks.count) / frames))
                        for channel in 0..<channels {
                            let sample = samples[channel][i]
                            guard sample.isFinite else { throw NSError(domain: "NotebookAudio", code: 4, userInfo: [NSLocalizedDescriptionKey: "Audio contains non-finite samples."]) }
                            peaks[bucket] = max(peaks[bucket], min(1, abs(sample)))
                        }
                    }
                    offset += Int64(buffer.frameLength)
                }
            }
            return Self(url: url, duration: duration, rate: rate, channels: channels, peaks: peaks)
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
}

final class NotebookAudioController: ObservableObject {
    @Published var error: String?
    @Published var position = 0.0
    @Published var playing = false
    @Published var duration = 0.0
    @Published var volume: Float = 1
    @Published var peaks: [Float] = []
    @Published var loading = false
    private(set) var payload: NotebookAudioPayload?
    private(set) var asset: NotebookDecodedAudio?
    private var player: AVAudioPlayer?
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private(set) var stream: NotebookAudioStream?
    private var streamBase = 0.0
    @Published var buffering = false
    var canPlay: Bool { player != nil || stream != nil }

    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var source: Data?
    private var waveformPrepared = false
    private var pendingControls: [NotebookAudioControl] = []
    private var appliedPlayback: UInt64 = 0, appliedSeek: UInt64 = 0, appliedVolume: UInt64 = 0
    func apply(_ control: NotebookAudioControl) {
        pendingControls.append(control)
        if pendingControls.count > 128 { pendingControls.removeFirst(pendingControls.count - 128) }
        applyPendingControls()
    }
    private func applyPendingControls() {
        guard canPlay, !loading else { return }
        var actions: [(UInt64, () -> Void)] = []
        for c in pendingControls {
            if c.seek_revision > appliedSeek {
                actions.append((c.seek_revision, { [weak self] in
                    guard let self else { return }; self.appliedSeek = c.seek_revision
                    if c.position <= self.duration { self.seek(c.position) }
                    else { self.error = "Player seek exceeds the available audio range." }
                }))
            }
            if c.volume_revision > appliedVolume {
                actions.append((c.volume_revision, { [weak self] in self?.appliedVolume = c.volume_revision; self?.setVolume(c.volume) }))
            }
            if c.playback_revision > appliedPlayback {
                actions.append((c.playback_revision, { [weak self] in
                    guard let self else { return }; self.appliedPlayback = c.playback_revision
                    if c.playback == 1 { self.play() } else if c.playback == 2 { self.pause() } else if c.playback == 3 { self.stop(); self.seek(0) }
                }))
            }
        }
        pendingControls.removeAll()
        for action in actions.sorted(by: { $0.0 < $1.0 }) { action.1() }
    }
    var onPlay: (() -> Void)?

    func load(_ next: NotebookAudioStream, waveform override: Bool?) {
        guard next.valid, next.replace else { error = "Invalid or incomplete PCM stream."; return }
        if let old = stream, old.token == next.token, old.revision >= next.revision {
            if override ?? next.waveform, peaks.isEmpty { updateStreamPeaks(next) }
            applyPendingControls(); return
        }
        do {
            let same = stream?.token == next.token
            let previousFrames = same ? stream!.frames : 0
            if !same {
                let pending = pendingControls; close(); pendingControls = pending; error = nil; generation = UUID()
                let engine = AVAudioEngine(), node = AVAudioPlayerNode()
                let format = AVAudioFormat(standardFormatWithSampleRate: Double(next.rate), channels: AVAudioChannelCount(next.channels))!
                engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
                engine.prepare(); try engine.start()
                self.engine = engine; self.node = node; volume = next.volume; node.volume = next.volume
                position = min(next.position, Double(next.frames) / Double(next.rate)); streamBase = position
            }
            guard next.frames >= previousFrames else { throw NSError(domain: "NotebookAudio", code: 5, userInfo: [NSLocalizedDescriptionKey: "PCM stream moved backwards."]) }
            stream = next; duration = Double(next.frames) / Double(next.rate)
            if override ?? next.waveform { updateStreamPeaks(next) }
            let newFrames = Int(next.frames - previousFrames)
            if newFrames > 0 {
                if !same || buffering { rescheduleStream(from: position) }
                else { scheduleStream(next, from: Int(previousFrames), count: newFrames) }
            }
            if !same && next.autoplay { play() }
            else if same && playing { node?.play(); buffering = position >= duration && !next.finished }
            loading = false; applyPendingControls()
        } catch { self.error = error.localizedDescription; playing = false; loading = false }
    }
    private func updateStreamPeaks(_ value: NotebookAudioStream) {
        let frames = Int(value.frames), width = value.frameWidth, samples = value.sample_format == "s16le" ? 2 : 4
        var result = [Float](repeating: 0, count: min(2048, frames))
        guard frames > 0 else { peaks = []; return }
        for frame in 0..<frames {
            let bucket = frame * result.count / frames
            for channel in 0..<Int(value.channels) {
                let at = frame * width + channel * samples
                result[bucket] = max(result[bucket], min(1, abs(pcmSample(value.data, at: at, width: samples))))
            }
        }
        peaks = result
    }
    private func pcmSample(_ data: Data, at: Int, width: Int) -> Float {
        if width == 2 { return Float(Int16(bitPattern: UInt16(data[at]) | UInt16(data[at + 1]) << 8)) / 32768 }
        let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[at + $1]) << (8 * $1) }
        return Float(bitPattern: bits)
    }
    private func scheduleStream(_ value: NotebookAudioStream, from: Int, count: Int) {
        guard let node, let format = AVAudioFormat(standardFormatWithSampleRate: Double(value.rate), channels: AVAudioChannelCount(value.channels)) else { return }
        let width = value.sample_format == "s16le" ? 2 : 4
        var offset = from, remaining = count
        while remaining > 0 {
            let frames = min(16384, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let samples = buffer.floatChannelData else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            for f in 0..<frames { for c in 0..<Int(value.channels) {
                let sample = pcmSample(value.data, at: ((offset + f) * Int(value.channels) + c) * width, width: width)
                guard sample.isFinite else { error = "PCM contains non-finite samples."; stop(); return }
                samples[c][f] = sample
            } }
            node.scheduleBuffer(buffer); offset += frames; remaining -= frames
        }
    }
    private func rescheduleStream(from seconds: Double) {
        guard let stream, let node else { return }
        node.stop(); streamBase = seconds
        let start = min(Int(stream.frames), Int(seconds * Double(stream.rate)))
        scheduleStream(stream, from: start, count: Int(stream.frames) - start)
        buffering = start == Int(stream.frames) && !stream.finished
        if playing { node.play() }
    }
    func load(_ panel: NotebookFigurePanel, waveform override: Bool?) {
        if source == panel.data {
            if (override ?? payload?.waveform ?? true), !waveformPrepared, let payload {
                waveformPrepared = true
                let current = generation
                Task { @MainActor [weak self] in
                    do {
                        let extra = try await Task.detached { try NotebookDecodedAudio.prepare(payload, waveform: true) }.value
                        defer { try? FileManager.default.removeItem(at: extra.url) }
                        if let self, self.generation == current { self.peaks = extra.peaks }
                    } catch { if let self, self.generation == current { self.error = error.localizedDescription } }
                }
            }
            return
        }
        guard source != panel.data || ((override ?? payload?.waveform ?? true) && !waveformPrepared) else { return }
        let previousPosition = position, wasPlaying = playing, same = source == panel.data
        if stream != nil { close() }
        source = panel.data; generation = UUID(); let current = generation
        task?.cancel(); stop(); cleanup(); error = nil; loading = true
        do {
            let payload = try NotebookAudioPayload.decode(panel.data); self.payload = payload
            let waveform = override ?? payload.waveform; waveformPrepared = waveform
            task = Task { @MainActor [weak self] in
                do {
                    let asset = try await Task.detached { try NotebookDecodedAudio.prepare(payload, waveform: waveform) }.value
                    guard let self, self.generation == current, !Task.isCancelled else { try? FileManager.default.removeItem(at: asset.url); return }
                    let player = try AVAudioPlayer(contentsOf: asset.url)
                    player.volume = payload.volume; player.numberOfLoops = payload.loop ? -1 : 0
                    player.currentTime = same ? previousPosition : payload.position
                    self.asset = asset; self.player = player; self.duration = asset.duration
                    self.position = player.currentTime; self.volume = payload.volume; self.peaks = asset.peaks; self.loading = false
                    if (same && wasPlaying) || (!same && payload.autoplay) { self.play() }
                    self.applyPendingControls()
                } catch { guard let self, self.generation == current else { return }; self.error = error.localizedDescription; self.loading = false }
            }
        } catch { self.error = error.localizedDescription; loading = false }
    }
    func play() {
        onPlay?()
        if let stream, let node {
            if position >= duration && stream.finished { position = 0 }
            playing = true; rescheduleStream(from: position); node.play(); return
        }
        guard let player else { return }
        if position >= duration { player.currentTime = 0; position = 0 }
        player.prepareToPlay()
        playing = player.play(); if !playing { error = "System audio output could not start." }
    }
    func pause() { tick(); player?.pause(); node?.pause(); playing = false; buffering = false }
    func stop() { player?.stop(); node?.stop(); playing = false; buffering = false }
    func seek(_ value: Double) { guard value.isFinite, value >= 0, value <= duration else { return }; player?.currentTime = value; position = value; if stream != nil { rescheduleStream(from: value) } }
    func setVolume(_ value: Float) { volume = value; player?.volume = value; node?.volume = value }
    func tick() {
        if let stream, let node, playing {
            if let time = node.lastRenderTime, let clock = node.playerTime(forNodeTime: time) {
                position = min(duration, streamBase + Double(clock.sampleTime) / clock.sampleRate)
            }
            buffering = position >= duration && !stream.finished
            if position >= duration && stream.finished {
                if stream.looped && duration > 0 { position = 0; rescheduleStream(from: 0) }
                else { node.pause(); playing = false }
            }
        } else if let player { position = player.currentTime; playing = player.isPlaying }
    }
    func close() { generation = UUID(); task?.cancel(); stop(); cleanup(); source = nil; stream = nil; node = nil; engine?.stop(); engine = nil; payload = nil; pendingControls.removeAll() }
    private func cleanup() { player = nil; if let asset { try? FileManager.default.removeItem(at: asset.url) }; asset = nil; peaks = [] }
    deinit { task?.cancel(); node?.stop(); engine?.stop(); player?.stop(); if let asset { try? FileManager.default.removeItem(at: asset.url) } }

    func save(original: Bool) {
        if let stream {
            let panel = NSSavePanel(); panel.nameFieldStringValue = "audio.wav"
            if panel.runModal() == .OK, let url = panel.url {
                do { try stream.wav().write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
            }
            return
        }
        guard let payload, let asset else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = original ? "audio.\(payload.format)" : "audio.wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if original { try payload.data.write(to: url, options: .atomic) }
            else {
                let input = try AVAudioFile(forReading: asset.url, commonFormat: .pcmFormatFloat32, interleaved: false)
                let output = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: asset.rate, AVNumberOfChannelsKey: asset.channels,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false],
                    commonFormat: .pcmFormatFloat32, interleaved: false)
                let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16384)!
                while input.framePosition < input.length { try input.read(into: buffer); if buffer.frameLength == 0 { break }; try output.write(from: buffer) }
            }
        } catch { self.error = error.localizedDescription }
    }
}

final class NotebookAudioSession {
    private var players: [String: NotebookAudioController] = [:]
    private var pending: [(String, NotebookAudioControl)] = []
    func apply(_ controls: [NotebookAudioControl], tab: String) {
        for c in controls {
            let prefix = tab + ":" + c.cell + ":"
            let key = prefix + c.channel
            pending.append((key, c))
            let matching = c.channel.isEmpty ? players.filter { $0.key.hasPrefix(prefix) }.map(\.value) : players[key].map { [$0] } ?? []
            if matching.count == 1 { matching[0].apply(c) }
            else if matching.count > 1 { for player in matching { player.error = "Select an audio channel in the component designer before sending commands." } }
        }
        if pending.count > 128 { pending.removeFirst(pending.count - 128) }
    }
    func controller(_ key: String) -> NotebookAudioController {
        if let current = players[key] { return current }
        if players.count >= 64, let oldest = players.keys.sorted().first { players.removeValue(forKey: oldest)?.close() }
        let value = NotebookAudioController()
        value.onPlay = { [weak self, weak value] in for other in self?.players.values ?? Dictionary<String, NotebookAudioController>().values where other !== value { other.pause() } }
        players[key] = value
        for (target, control) in pending where target == key || (control.channel.isEmpty && key.hasPrefix(target)) { value.apply(control) }
        return value
    }
    func close() { for player in players.values { player.close() }; players.removeAll(); pending.removeAll() }
}
