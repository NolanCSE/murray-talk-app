import Foundation
import AVFoundation
import UIKit
import MurrayCallCore

/// The whole call loop, natively: mic → endpointing → /turn → SSE → playback.
/// The page is only a view of this. Events go out through `onEvent`.
final class CallEngine: NSObject, URLSessionDataDelegate {
    struct Turn { let who: String; let text: String }

    let base: URL                                   // https://…/talk/<secret>/
    private(set) var callId = ""
    private(set) var turns: [Turn] = []
    var onEvent: ((String, [String: Any]) -> Void)?

    private let audio = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var endpointer = Endpointer()
    private var capturing = false
    private var pcm: [Int16] = []
    private var preroll: [Int16] = []               // ~200ms before detection
    private let prerollMax = 3200
    private let lock = NSLock()
    private var levelTick = 0

    private var session: URLSession!
    private var turnTask: URLSessionDataTask?
    private var sse = SSEParser()
    private var replyLine: String = ""

    // Playback: a player node through an EQ with a gain stage, on the same
    // engine as the microphone. AVAudioPlayer had no gain at all and the
    // .voiceChat session mode runs output through voice processing, which
    // is markedly quieter than media playback — "he gets too quiet,
    // especially with music on" (2026-08-27).
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 1)
    private var playbackWired = false
    private var queued = 0                          // clips scheduled and not yet finished
    private var clipFiles: [URL] = []
    private var playbackStartedAt: Double = 0
    var gainDb: Float = 8 { didSet { eq.globalGain = max(-24, min(24, gainDb)) } }
    private(set) var running = false

    init(base: URL) {
        self.base = base
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 200
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

    // MARK: session + engine

    func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        // mixWithOthers + duckOthers is the ask; under CallKit iOS may
        // still interrupt other audio like a phone call — verified on the
        // phone, not assumed.
        // .voiceChat: the mode the mic is known to work under. .videoChat was
        // tried for loudness on 2026-08-27 and the microphone stopped being
        // heard after the first playback; loudness comes from the gain stage
        // instead.
        try s.setCategory(.playAndRecord, mode: .voiceChat, options: sessionOptions())
        try s.setPreferredSampleRate(48000)
        try s.setPreferredIOBufferDuration(0.02)
    }

    // MARK: output route (SPEAKER / EARPIECE button)

    /// Speaker by default: the phone lies on the desk while he talks. Off
    /// means the earpiece, with the proximity sensor darkening the screen
    /// at the ear like the Phone app.
    var speaker: Bool = UserDefaults.standard.object(forKey: "murray.speaker") as? Bool ?? true

    private func sessionOptions() -> AVAudioSession.CategoryOptions {
        var o: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers, .duckOthers]
        if speaker { o.insert(.defaultToSpeaker) }
        return o
    }

    func setSpeaker(_ on: Bool) {
        speaker = on
        UserDefaults.standard.set(on, forKey: "murray.speaker")
        applyRoute()
    }

    /// Under CallKit the category is CallKit's and .defaultToSpeaker is
    /// ignored: his voice came out of the top receiver (2026-08-27). The
    /// port override is the one call that moves it, and it only sticks once
    /// the session is active — so it runs at start and on every toggle.
    private func applyRoute() {
        let s = AVAudioSession.sharedInstance()
        do { try s.overrideOutputAudioPort(speaker ? .speaker : .none) }
        catch {
            lastError = "route: \(error.localizedDescription)"
            emit("error", ["where": "route", "why": error.localizedDescription])
        }
        DispatchQueue.main.async { UIDevice.current.isProximityMonitoringEnabled = !self.speaker }
        emitRoute()
    }

    // MARK: microphone sensitivity

    /// The raw iPhone microphone with voice processing off is quiet: normal
    /// speech across a desk is a few thousandths of full scale, so he had
    /// to shout (2026-08-27). A fixed +12 dB pre-gain lifts it before the
    /// gate and before Scribe; the setting moves the gate itself.
    private let micGain: Float = 4.0
    var sensitivity: String = UserDefaults.standard.string(forKey: "murray.sensitivity") ?? "normal"
    func setSensitivity(_ level: String) {
        sensitivity = level
        UserDefaults.standard.set(level, forKey: "murray.sensitivity")
        lock.lock(); endpointer.tune(sensitivity: level); lock.unlock()
    }

    /// What the phone is actually playing through, for the call screen.
    func routeInfo() -> [String: Any] {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        let port = outs.first?.portType
        let kind: String
        switch port {
        case .some(.builtInSpeaker): kind = "speaker"
        case .some(.builtInReceiver): kind = "earpiece"
        case .some(.headphones), .some(.headsetMic): kind = "headphones"
        case .some(.bluetoothA2DP), .some(.bluetoothHFP), .some(.bluetoothLE): kind = "bluetooth"
        case .some(.airPlay): kind = "airplay"
        case .some(.carAudio): kind = "car"
        default: kind = outs.first.map { $0.portType.rawValue } ?? "none"
        }
        return ["kind": kind, "name": outs.first?.portName ?? "", "speaker": speaker]
    }
    private func emitRoute() { emit("route", routeInfo()) }

    func start(callId: String) throws {
        self.callId = callId
        endpointer = Endpointer()
        endpointer.tune(sensitivity: sensitivity)
        endpointer.setLevelBargeIn(vpEnabled)
        turns = []
        try startInput()
        running = true
        emit("state", ["state": "listening"])
        applyRoute()
    }

    private func startInput() throws {
        let input = audio.inputNode
        if vpEnabled { try? input.setVoiceProcessingEnabled(true) }      // echo cancellation
        else { try? input.setVoiceProcessingEnabled(false) }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { throw NSError(domain: "MurrayCall", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone input"]) }
        converter = nil                       // built from the first live buffer
        convertErrors = 0
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.consume(buf)
        }
        if !playbackWired {
            audio.attach(player); audio.attach(eq)
            eq.globalGain = gainDb
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
            audio.connect(player, to: eq, format: fmt)
            audio.connect(eq, to: audio.mainMixerNode, format: fmt)
            playbackWired = true
        }
        audio.prepare()
        try audio.start()
        // Self-heal: no buffers within 2 s means the tap is dead. Try once
        // more without voice processing, and say so.
        let mark = tapBuffers
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.running, self.tapBuffers == mark, !self.healed else { return }
            self.healed = true
            self.vpEnabled = !self.vpEnabled
            self.lock.lock(); self.endpointer.setLevelBargeIn(self.vpEnabled); self.lock.unlock()
            self.lastError = "no mic buffers in 2s (voice processing \(self.vpEnabled ? "off" : "on")); restarted with it \(self.vpEnabled ? "on" : "off")"
            self.emit("error", ["where": "microphone", "why": self.lastError])
            self.stopInput()
            do { try self.startInput() } catch { self.emit("error", ["where": "microphone", "why": "restart failed: \(error.localizedDescription)"]) }
        }
    }

    private func stopInput() {
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
    }

    func stop(reason: String) {
        guard running else { return }
        running = false
        DispatchQueue.main.async { UIDevice.current.isProximityMonitoringEnabled = false }
        endpointer.end()
        turnTask?.cancel(); turnTask = nil
        stopPlayback()
        stopInput()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        var req = URLRequest(url: base.appendingPathComponent("end"))
        req.httpMethod = "POST"; req.setValue(callId, forHTTPHeaderField: "X-Talk-Call")
        URLSession.shared.dataTask(with: req).resume()
        emit("state", ["state": "ended"])
        emit("ended", ["reason": reason])
    }

    // MARK: audio in

    private var convertErrors = 0
    private var peakRms: Float = 0            // loudest post-gain level this call, for Diagnostics
    private var tapBuffers = 0
    private var tapFormat = ""
    // Off by default since 2026-08-27: with it ON the input tap never
    // delivered a buffer on his iPhone (the 2 s self-heal fired on every
    // call); OFF it works at once. Without echo cancellation Murray's own
    // voice would read as barge-in, so level barge-in is disabled in this
    // mode — hold-to-talk still interrupts him.
    private var vpEnabled = false
    private var healed = false
    private var lastError = ""

    /// Everything the phone knows about its own microphone, for the page's
    /// Diag button. Built after three blind builds on 2026-08-27.
    func diagnostics() -> [String: Any] {
        let s = AVAudioSession.sharedInstance()
        let route = s.currentRoute
        return [
            "running": running, "engineRunning": audio.isRunning,
            "tapBuffers": tapBuffers, "tapFormat": tapFormat, "levelTicks": levelTick,
            "convertErrors": convertErrors, "voiceProcessing": vpEnabled, "healed": healed,
            "gateStart": endpointer.startLevel, "noiseFloor": endpointer.floor, "peakRms": peakRms,
            "micGain": micGain, "sensitivity": sensitivity, "speaker": speaker,
            "routeReason": lastRouteReason, "playing": endpointer.playing,
            "inputFormat": "\(audio.inputNode.outputFormat(forBus: 0))",
            "inputVP": audio.inputNode.isVoiceProcessingEnabled,
            "category": s.category.rawValue, "mode": s.mode.rawValue,
            "sampleRate": s.sampleRate, "ioBuffer": s.ioBufferDuration,
            "inputs": route.inputs.map { "\($0.portType.rawValue):\($0.portName)" },
            "outputs": route.outputs.map { "\($0.portType.rawValue):\($0.portName)" },
            "availableInputs": (s.availableInputs ?? []).map { $0.portType.rawValue },
            "recordPermission": "\(s.recordPermission.rawValue)",
            "otherAudioPlaying": s.isOtherAudioPlaying,
            "state": endpointer.state.rawValue, "capturing": capturing,
            "queued": queued, "callId": callId, "lastError": lastError,
        ]
    }

    private func consume(_ buf: AVAudioPCMBuffer) {
        tapBuffers += 1
        if tapFormat.isEmpty { tapFormat = "\(buf.format)" }
        guard running else { return }
        // The converter follows the LIVE buffer format. Voice-processing IO
        // renegotiates the microphone format once output goes live; a
        // converter built at start then rejects every buffer, silently —
        // "no audio captured (0 ms)", 2026-08-27.
        if converter == nil || converter!.inputFormat != buf.format {
            converter = AVAudioConverter(from: buf.format, to: targetFormat)
            emit("doing", ["label": String(format: "mic %.0f Hz x%d", buf.format.sampleRate, buf.format.channelCount)])
        }
        guard let conv = converter else {
            if convertErrors == 0 { emit("error", ["where": "microphone", "why": "no converter for \(buf.format)"]) }
            convertErrors += 1; return
        }
        let ratio = targetFormat.sampleRate / buf.format.sampleRate
        let outCap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else {
            if convertErrors == 0 {
                emit("error", ["where": "microphone", "why": "audio conversion failed: \(err?.localizedDescription ?? "empty output") from \(buf.format)"])
            }
            convertErrors += 1
            return
        }
        let raw = UnsafeBufferPointer(start: ch, count: Int(out.frameLength))
        var boosted = [Float](repeating: 0, count: raw.count)
        for i in 0..<raw.count { boosted[i] = max(-1, min(1, raw[i] * micGain)) }
        let rms = boosted.withUnsafeBufferPointer { WAV.rms($0) }
        peakRms = max(peakRms, rms)
        var ints = [Int16](repeating: 0, count: boosted.count)
        for i in 0..<boosted.count { ints[i] = Int16(boosted[i] * 32767) }

        lock.lock()
        if capturing {
            pcm.append(contentsOf: ints)
        } else {
            preroll.append(contentsOf: ints)
            if preroll.count > prerollMax { preroll.removeFirst(preroll.count - prerollMax) }
        }
        let action = endpointer.level(rms, at: CallEngine.now())
        lock.unlock()
        apply(action)
        levelTick += 1
        if levelTick % 4 == 0 { emit("level", ["rms": rms, "start": endpointer.startLevel, "floor": endpointer.floor, "state": endpointer.state.rawValue, "capturing": capturing, "playing": queued > 0, "taps": levelTick]) }
    }

    private func apply(_ action: EndpointerAction) {
        switch action {
        case .none: return
        case .bargeIn:
            // Level barge-in only arrives with echo cancellation on (the
            // endpointer is told); hold-to-talk barge-in arrives regardless.
            stopPlayback()
            beginCapture()
        case .startTurn:
            beginCapture()
        case .endTurn:
            finishCapture(send: true)
        case .discardTurn:
            finishCapture(send: false)
        }
    }

    private func beginCapture() {
        lock.lock()
        capturing = true
        pcm = preroll; preroll = []
        lock.unlock()
        emit("state", ["state": "user"])
    }

    private func finishCapture(send: Bool) {
        lock.lock()
        capturing = false
        let samples = pcm; pcm = []
        lock.unlock()
        if send {
            // Under 150 ms there is nothing to hear; Scribe calls that
            // "corrupted" (2026-08-27) and the real fault — a microphone
            // that stopped delivering — went unnamed.
            if samples.count < 2400 {
                emit("error", ["where": "capturing",
                               "why": "no audio captured (%d ms) — the microphone is not delivering; try End and start again".replacingOccurrences(of: "%d", with: String(samples.count / 16))])
                lock.lock(); endpointer.replyDone(); let st = endpointer.state; lock.unlock()
                emit("state", ["state": st.rawValue])
                return
            }
            emit("state", ["state": "thinking"])
            emit("doing", ["label": "sending \(samples.count / 16) ms"])
            upload(WAV.encode(pcm16: samples, sampleRate: 16000))
        } else {
            emit("state", ["state": endpointer.state.rawValue])
        }
    }

    // MARK: controls from the page

    func setMuted(_ on: Bool) {
        lock.lock(); let a = endpointer.setMuted(on, at: CallEngine.now()); lock.unlock()
        apply(a)
        emit("state", ["state": endpointer.state.rawValue])
    }
    func holdStart() {
        lock.lock(); let a = endpointer.holdStart(at: CallEngine.now()); lock.unlock()
        apply(a)
    }
    func holdEnd() {
        lock.lock(); let a = endpointer.holdEnd(at: CallEngine.now()); lock.unlock()
        apply(a)
    }

    // MARK: turn upload + SSE

    /// A text turn — no microphone, no transcript line. Used right after an
    /// approval card is decided on the page so Murray acknowledges it now.
    func nudge(_ text: String) {
        guard running, turnTask == nil else { return }
        lock.lock(); endpointer.turnSent(); lock.unlock()
        emit("state", ["state": "thinking"])
        upload(Data(text.utf8), mime: "text/plain")
    }

    private func upload(_ body: Data, mime: String = "audio/wav") {
        var req = URLRequest(url: base.appendingPathComponent("turn"))
        req.httpMethod = "POST"
        req.setValue(callId, forHTTPHeaderField: "X-Talk-Call")
        req.setValue(mime, forHTTPHeaderField: "X-Talk-Mime")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        sse = SSEParser(); replyLine = ""
        turnTask?.cancel()
        let task = session.dataTask(with: req)
        turnTask = task
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask == turnTask else { return }
        for frame in sse.feed(data) { handle(frame) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task == turnTask else { return }
        turnTask = nil
        if let e = error as NSError?, e.code != NSURLErrorCancelled {
            emit("error", ["where": "turn", "why": e.localizedDescription])
        }
        if !replyLine.isEmpty { turns.append(Turn(who: "murray", text: replyLine)); replyLine = "" }
        // The stream ending is not the audio ending: only with nothing queued
        // does the gate open here; otherwise clipDone opens it after the
        // last clip has sounded (he heard himself otherwise, 2026-08-27).
        lock.lock()
        if queued == 0 { endpointer.playbackStopped(at: CallEngine.now()) }
        endpointer.replyDone()
        let st = endpointer.state; lock.unlock()
        if queued == 0 { emit("state", ["state": st.rawValue]) }
        emit("doing", ["label": ""])
        DispatchQueue.main.async { self.maybeHangUp() }
    }

    private func handle(_ f: SSEFrame) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(f.data.utf8)) as? [String: Any] else { return }
        switch f.event {
        case "heard":
            if obj["empty"] as? Bool == true { emit("heard", ["text": "", "empty": true]); return }
            let text = obj["text"] as? String ?? ""
            turns.append(Turn(who: "you", text: text))
            emit("heard", ["text": text])
        case "say":
            let text = obj["text"] as? String ?? ""
            replyLine += (replyLine.isEmpty ? "" : " ") + text
            emit("say", ["text": text, "why": obj["why"] as? String ?? ""])
            if let b64 = obj["audio"] as? String, !b64.isEmpty, let mp3 = Data(base64Encoded: b64) {
                enqueue(mp3)
            }
        case "control":
            let type = obj["type"] as? String ?? ""
            if type == "end_call" { stopAfterPlayback = true }      // after the stream AND the audio finish
            else if type == "progress" {
                let label = (obj["label"] as? String ?? obj["tool"] as? String ?? "").replacingOccurrences(of: "_", with: " ")
                emit("doing", ["label": (obj["status"] as? String) == "completed" ? "" : label])
            } else if type == "extend", let m = obj["minutes"] {
                emit("say", ["text": "(\(m) more minutes)", "why": ""])
            }
        case "failed":
            emit("error", ["where": obj["where"] as? String ?? "?", "why": obj["why"] as? String ?? ""])
        default: break
        }
    }

    private var stopAfterPlayback = false
    private func maybeHangUp() {
        // Only once the reply stream is over AND every clip has sounded:
        // he was losing the last half-word of his goodbye (2026-08-27).
        if stopAfterPlayback && turnTask == nil && queued == 0 {
            stopAfterPlayback = false
            stop(reason: "murray hung up")
        }
    }

    // MARK: playback

    private func enqueue(_ mp3: Data) {
        guard running else { return }
        // AVAudioFile reads from disk; a clip is a few tens of KB.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murray-\(UUID().uuidString).mp3")
        do { try mp3.write(to: url) } catch { return }
        guard let file = try? AVAudioFile(forReading: url) else { try? FileManager.default.removeItem(at: url); return }
        DispatchQueue.main.async {
            if !self.audio.isRunning { try? self.audio.start() }
            let first = self.queued == 0
            self.queued += 1
            self.clipFiles.append(url)
            self.player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in
                DispatchQueue.main.async { self.clipDone(url) }
            }
            if first {
                self.playbackStartedAt = CallEngine.now()
                self.lock.lock(); self.endpointer.playbackStarted(at: self.playbackStartedAt); self.lock.unlock()
                self.emit("state", ["state": "speaking"])
                if !self.player.isPlaying { self.player.play() }
            }
        }
    }

    private func clipDone(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        clipFiles.removeAll { $0 == url }
        queued = max(0, queued - 1)
        if queued == 0 {
            // Between clips of one reply the stream is still open: stay
            // "speaking" (gate shut) — the next clip is on its way.
            guard turnTask == nil else { maybeHangUp(); return }
            lock.lock(); endpointer.playbackStopped(at: CallEngine.now()); endpointer.replyDone()
            let st = endpointer.state; lock.unlock()
            emit("state", ["state": st.rawValue])
            maybeHangUp()
        }
    }

    private func stopPlayback() {
        DispatchQueue.main.async {
            self.player.stop()                       // drops every scheduled clip
            for u in self.clipFiles { try? FileManager.default.removeItem(at: u) }
            self.clipFiles = []
            self.queued = 0
        }
        lock.lock(); endpointer.playbackStopped(at: CallEngine.now()); lock.unlock()
    }

    var isPlaying: Bool { queued > 0 }

    // MARK: interruptions

    @objc private func interrupted(_ n: Notification) {
        guard running, let info = n.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            stopInput()
            emit("state", ["state": "paused"])
        } else {
            let opts = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            _ = opts   // resume regardless: a call that stays paused is a dead call
            do {
                try? AVAudioSession.sharedInstance().setActive(true)
                try? startInput()
                emit("state", ["state": endpointer.state.rawValue])
            }
        }
    }

    private var lastRouteReason = ""
    @objc private func routeChanged(_ n: Notification) {
        guard running else { return }
        let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
        lastRouteReason = "\(reason.rawValue)"
        DispatchQueue.main.async {
            self.stopInput()
            try? self.startInput()
            // iOS (CallKit, a category change, the engine restarting) can
            // put a phone call back on the top receiver; if SPEAKER is on
            // and that happened, ask again — once per change, so an
            // override that fails cannot loop.
            let out = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType
            if self.speaker && out == .builtInReceiver && reason != .override {
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            }
            self.emitRoute()
        }
    }

    // MARK: events

    private func emit(_ name: String, _ data: [String: Any]) {
        onEvent?(name, data)
    }

    func snapshot() -> [String: Any] {
        ["state": running ? endpointer.state.rawValue : "ended", "callId": callId,
         "turns": turns.map { ["who": $0.who, "text": $0.text] }]
    }
}
