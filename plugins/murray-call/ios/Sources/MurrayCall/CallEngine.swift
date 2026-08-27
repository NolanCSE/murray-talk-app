import Foundation
import AVFoundation
import MurrayCallCore

/// The whole call loop, natively: mic → endpointing → /turn → SSE → playback.
/// The page is only a view of this. Events go out through `onEvent`.
final class CallEngine: NSObject, URLSessionDataDelegate, AVAudioPlayerDelegate {
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

    private var players: [AVAudioPlayer] = []       // playing + queued, in order
    private var scheduledEnd: TimeInterval = 0      // device time the queue runs out (main thread)
    private var playbackStartedAt: Double = 0
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
        try s.setCategory(.playAndRecord, mode: .voiceChat,
                          options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker,
                                    .mixWithOthers, .duckOthers])
        try s.setPreferredSampleRate(48000)
        try s.setPreferredIOBufferDuration(0.02)
    }

    func start(callId: String) throws {
        self.callId = callId
        endpointer = Endpointer()
        turns = []
        try startInput()
        running = true
        emit("state", ["state": "listening"])
    }

    private func startInput() throws {
        let input = audio.inputNode
        try? input.setVoiceProcessingEnabled(true)      // echo cancellation
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { throw NSError(domain: "MurrayCall", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone input"]) }
        converter = AVAudioConverter(from: fmt, to: targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.consume(buf)
        }
        audio.prepare()
        try audio.start()
    }

    private func stopInput() {
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
    }

    func stop(reason: String) {
        guard running else { return }
        running = false
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

    private func consume(_ buf: AVAudioPCMBuffer) {
        guard let conv = converter, running else { return }
        let ratio = targetFormat.sampleRate / buf.format.sampleRate
        let outCap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
        let floats = UnsafeBufferPointer(start: ch, count: Int(out.frameLength))
        let rms = WAV.rms(floats)
        var ints = [Int16](repeating: 0, count: floats.count)
        for i in 0..<floats.count { ints[i] = Int16(max(-1, min(1, floats[i])) * 32767) }

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
        if levelTick % 4 == 0 { emit("level", ["rms": rms]) }   // ~4/s is plenty for a meter
    }

    private func apply(_ action: EndpointerAction) {
        switch action {
        case .none: return
        case .bargeIn:
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
            emit("state", ["state": "thinking"])
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

    private func upload(_ wav: Data) {
        var req = URLRequest(url: base.appendingPathComponent("turn"))
        req.httpMethod = "POST"
        req.setValue(callId, forHTTPHeaderField: "X-Talk-Call")
        req.setValue("audio/wav", forHTTPHeaderField: "X-Talk-Mime")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = wav
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
        lock.lock(); endpointer.replyDone(); let st = endpointer.state; lock.unlock()
        if players.isEmpty { emit("state", ["state": st.rawValue]) }
        emit("doing", ["label": ""])
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
            if type == "end_call" { emit("say", ["text": "", "why": ""]); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.drainThenStop() } }
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
    private func drainThenStop() {
        if players.isEmpty { stop(reason: "murray hung up") } else { stopAfterPlayback = true }
    }

    // MARK: playback

    private func enqueue(_ mp3: Data) {
        guard running, let p = try? AVAudioPlayer(data: mp3) else { return }
        p.delegate = self
        p.prepareToPlay()
        DispatchQueue.main.async {
            // One clock for the whole queue. Timing off "the last player, if
            // it is playing" let a third sentence start on top of the first
            // whenever the second had not begun yet (2026-08-27: he talked
            // over himself).
            let now = p.deviceCurrentTime
            let first = self.players.isEmpty
            let at = max(now + (first ? 0.12 : 0.02), self.scheduledEnd)   // LEAD_S on the first
            p.play(atTime: at)
            self.scheduledEnd = at + p.duration
            if first {
                self.playbackStartedAt = CallEngine.now()
                self.lock.lock(); self.endpointer.playbackStarted(at: self.playbackStartedAt); self.lock.unlock()
                self.emit("state", ["state": "speaking"])
            }
            self.players.append(p)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.players.removeAll { $0 === player }
            if self.players.isEmpty {
                self.scheduledEnd = 0
                self.lock.lock(); self.endpointer.playbackStopped()
                if self.turnTask == nil { self.endpointer.replyDone() }
                let st = self.endpointer.state; self.lock.unlock()
                self.emit("state", ["state": st.rawValue])
                if self.stopAfterPlayback { self.stopAfterPlayback = false; self.stop(reason: "murray hung up") }
            }
        }
    }

    private func stopPlayback() {
        DispatchQueue.main.async {
            for p in self.players { p.delegate = nil; p.stop() }
            self.players = []
            self.scheduledEnd = 0
        }
        lock.lock(); endpointer.playbackStopped(); lock.unlock()
    }

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

    @objc private func routeChanged(_ n: Notification) {
        guard running else { return }
        DispatchQueue.main.async {
            self.stopInput()
            try? self.startInput()
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
