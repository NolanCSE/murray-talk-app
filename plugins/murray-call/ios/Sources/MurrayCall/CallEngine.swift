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
    private let fxPlayer = AVAudioPlayerNode()      // cue tones, through the same gain stage
    private let eq = AVAudioUnitEQ(numberOfBands: 1)
    private var fxFormat: AVAudioFormat?
    private var detect = HighPass()                 // the gate listens above ~250 Hz
    /// Faint tick every 6 s while he is still thinking — a Settings toggle.
    var thinkTick: Bool = UserDefaults.standard.bool(forKey: "murray.thinkTick")
    private var tickTimer: Timer?
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

    /// The phone decides, like the Phone app: headphones or Bluetooth win
    /// whenever they are connected; the route picker (the standard iOS
    /// sheet) changes it. The one thing Murray does on his own is swap the
    /// top receiver for the loudspeaker — a phone on the desk, not at the
    /// ear — and only when nothing external is attached. Forcing .speaker
    /// unconditionally broke headphones (2026-08-27).
    var speaker: Bool { AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType == .builtInSpeaker }

    private func sessionOptions() -> AVAudioSession.CategoryOptions {
        [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers, .duckOthers]
    }

    /// Explicit choice from the page's fallback: speaker on/off. The picker
    /// is the normal way; this stays for a page without it.
    func setSpeaker(_ on: Bool) {
        let s = AVAudioSession.sharedInstance()
        do { try s.overrideOutputAudioPort(on ? .speaker : .none) }
        catch { emit("error", ["where": "route", "why": error.localizedDescription]) }
        emitRoute()
    }

    /// Receiver → loudspeaker, nothing else touched.
    private func applyRoute() {
        let s = AVAudioSession.sharedInstance()
        if s.currentRoute.outputs.first?.portType == .builtInReceiver {
            try? s.overrideOutputAudioPort(.speaker)
        }
        DispatchQueue.main.async { UIDevice.current.isProximityMonitoringEnabled = self.routeInfo()["kind"] as? String == "earpiece" }
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
    private func emitRoute() {
        // Cutting in by voice is safe with echo cancellation, or when his
        // voice is in your ear (headphones/Bluetooth) rather than in the
        // room with the microphone.
        lock.lock(); endpointer.setLevelBargeIn(bargeInSafe); lock.unlock()
        emit("route", routeInfo())
    }
    private var bargeInSafe: Bool {
        if vpEnabled { return true }
        let out = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType
        switch out {
        case .some(.builtInSpeaker), .some(.builtInReceiver), .none: return false
        default: return true
        }
    }

    func start(callId: String) throws {
        self.callId = callId
        let carryTurn = preheating && turnTask != nil
        endpointer = Endpointer()
        endpointer.tune(sensitivity: sensitivity)
        endpointer.setLevelBargeIn(bargeInSafe)
        if carryTurn { endpointer.turnSent() }         // the opening line is owed: stay in thinking
        turns = []
        try startInput()
        running = true
        emit("state", ["state": carryTurn ? "thinking" : "listening"])
        preheating = false
        lock.lock(); let held = preStartClips; preStartClips = []; lock.unlock()
        for c in held { enqueue(c) }
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
            audio.attach(player); audio.attach(fxPlayer); audio.attach(eq)
            eq.globalGain = gainDb
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
            fxFormat = fmt
            audio.connect(player, to: eq, format: fmt)
            // The EQ has one input bus; a second source on it throws at
            // engine start (build 33 crashed on every call). Cues go to the
            // mixer and carry the gain in their amplitude instead.
            audio.connect(fxPlayer, to: audio.mainMixerNode, format: fmt)
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
            self.lock.lock(); self.endpointer.setLevelBargeIn(self.bargeInSafe); self.lock.unlock()
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
        stopTicks()
        // Tell the server the call is over — the page does this itself, but a
        // CallKit hang-up (lock screen, ring call) never reached it and the
        // line stayed open server-side (2026-08-28).
        var endReq = URLRequest(url: base.appendingPathComponent("end"))
        endReq.httpMethod = "POST"
        endReq.setValue(callId, forHTTPHeaderField: "X-Talk-Call")
        URLSession.shared.dataTask(with: endReq).resume()
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
    private var vpEnabled = UserDefaults.standard.bool(forKey: "murray.vp")
    private var healed = false

    /// Settings › Echo cancellation: Apple's voice processing (echo cancel
    /// + noise suppression). Off by default — on 2026-08-27 it delivered no
    /// mic buffers on his phone; that may have been the converter bug since
    /// fixed, so it is a live toggle with Diagnostics to judge it by.
    func setVoiceProcessing(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "murray.vp")
        vpEnabled = on
        healed = false
        lock.lock(); endpointer.setLevelBargeIn(bargeInSafe); lock.unlock()
        guard running else { return }
        DispatchQueue.main.async {
            self.stopInput()
            do { try self.startInput() } catch { self.emit("error", ["where": "microphone", "why": "restart failed: \(error.localizedDescription)"]) }
        }
    }
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
            "thinkTick": thinkTick, "workSound": workSound, "dips": endpointer.dipsInTurn, "spread": endpointer.spreadInTurn, "muted": endpointer.muted,
            "lastDiscard": endpointer.lastDiscard, "bargeIn": bargeInSafe,
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
        // The gate hears through a high-pass: road and wind noise sit under
        // 250 Hz, a voice does not. Scribe gets the whole band.
        let shaped = detect.process(boosted)
        let rms = shaped.withUnsafeBufferPointer { WAV.rms($0) }
        peakRms = max(peakRms, rms)
        var ints = [Int16](repeating: 0, count: boosted.count)
        for i in 0..<boosted.count { ints[i] = Int16(boosted[i] * 32767) }

        lock.lock()
        // A hard mute: nothing of his is kept while muted — not in the
        // turn, not in the preroll. The level still feeds the gate so the
        // floor keeps tracking the room.
        if endpointer.muted {
            if capturing { pcm.append(contentsOf: [Int16](repeating: 0, count: ints.count)) }
            preroll.removeAll(keepingCapacity: true)
        } else if capturing {
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
            // Stop the clip AND the stream: clips kept arriving after the
            // interrupt and he carried on regardless (2026-08-28).
            stopPlayback()
            turnTask?.cancel(); turnTask = nil
            stopTicks()
            if !replyLine.isEmpty { turns.append(Turn(who: "murray", text: replyLine + " —")); replyLine = "" }
            emit("doing", ["label": ""])
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
                cue(.notHeard)
                lock.lock(); endpointer.replyDone(); let st = endpointer.state; lock.unlock()
                emit("state", ["state": st.rawValue])
                return
            }
            emit("state", ["state": "thinking"])
            emit("doing", ["label": "sending \(samples.count / 16) ms"])
            cue(.sent)
            upload(WAV.encode(pcm16: samples, sampleRate: 16000))
        } else {
            // Never drop a turn silently: say why on the screen, and sound
            // the not-heard cue for a real turn that was judged noise.
            lock.lock(); let why = endpointer.lastDiscard; let st = endpointer.state; lock.unlock()
            if why.hasPrefix("steady") { emit("doing", ["label": "dropped: " + why]); cue(.notHeard) }
            emit("state", ["state": st.rawValue])
        }
    }

    // MARK: controls from the page

    func setMuted(_ on: Bool) {
        lock.lock(); let a = endpointer.setMuted(on, at: CallEngine.now()); lock.unlock()
        apply(a)
        emit("muted", ["on": on])                    // the page's button follows this, whoever pressed it
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
        // Where he is: what his voice is coming out of, and whether the
        // screen is anything he can look at. The server turns this into
        // one sentence of situated context (2026-08-28).
        let r = routeInfo()
        let routeStr = "\(r["kind"] as? String ?? "")" + ":" + (r["name"] as? String ?? "")
        req.setValue(String(routeStr.prefix(60)), forHTTPHeaderField: "X-Talk-Route")
        req.setValue(screenState(), forHTTPHeaderField: "X-Talk-Screen")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        sse = SSEParser(); replyLine = ""; sawHeard = false
        streamActivityAt = CallEngine.now()
        startWatchdog()
        startTicks()
        turnTask?.cancel()
        let task = session.dataTask(with: req)
        turnTask = task
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask == turnTask else { return }
        streamActivityAt = CallEngine.now()
        for frame in sse.feed(data) { handle(frame) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task == turnTask else { return }
        turnTask = nil
        stopTicks()
        if let e = error as NSError?, e.code != NSURLErrorCancelled {
            emit("error", ["where": "turn", "why": e.localizedDescription])
        }
        if !replyLine.isEmpty { turns.append(Turn(who: "murray", text: replyLine)); replyLine = "" }
        else if error == nil && !sawHeard { emit("error", ["where": "turn", "why": "the server answered with nothing — no transcript, no reply"]) }
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
            sawHeard = true
            if obj["empty"] as? Bool == true { emit("heard", ["text": "", "empty": true]); cue(.notHeard); stopTicks(); return }
            let text = obj["text"] as? String ?? ""
            turns.append(Turn(who: "you", text: text))
            emit("heard", ["text": text])
        case "say":
            let text = obj["text"] as? String ?? ""
            replyLine += (replyLine.isEmpty ? "" : " ") + text
            emit("say", ["text": text, "why": obj["why"] as? String ?? ""])
            if let b64 = obj["audio"] as? String, !b64.isEmpty, let mp3 = Data(base64Encoded: b64) {
                stopTicks()
                stopWorking()
                enqueue(mp3)
            }
        case "control":
            let type = obj["type"] as? String ?? ""
            if type == "end_call" { stopAfterPlayback = true }      // after the stream AND the audio finish
            else if type == "progress" {
                let label = (obj["label"] as? String ?? obj["tool"] as? String ?? "").replacingOccurrences(of: "_", with: " ")
                let done = (obj["status"] as? String) == "completed"
                emit("doing", ["label": done ? "" : label])
                if done || label.isEmpty { stopWorking() } else if queued == 0 { startWorking() }
            } else if type == "extend", let m = obj["minutes"] {
                emit("say", ["text": "(\(m) more minutes)", "why": ""])
            }
        case "failed":
            emit("error", ["where": obj["where"] as? String ?? "?", "why": obj["why"] as? String ?? ""])
        default: break
        }
    }

    private var stopAfterPlayback = false
    private var sawHeard = false
    private var streamActivityAt: Double = 0
    private var watchdog: Timer?

    /// "Thinking forever" is a dead stream, not thinking. If the reply
    /// stream goes silent for 60 s, kill it, say so, reopen the line.
    private func startWatchdog() {
        DispatchQueue.main.async {
            self.watchdog?.invalidate()
            self.watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                guard self.turnTask != nil else { self.watchdog?.invalidate(); self.watchdog = nil; return }
                if CallEngine.now() - self.streamActivityAt > 60_000 {
                    self.turnTask?.cancel(); self.turnTask = nil
                    self.stopTicks()
                    self.emit("error", ["where": "turn", "why": "the server went quiet for a minute — the line is open again, say it again"])
                    self.lock.lock(); self.endpointer.replyDone(); let st = self.endpointer.state; self.lock.unlock()
                    self.emit("state", ["state": st.rawValue])
                    self.watchdog?.invalidate(); self.watchdog = nil
                }
            }
        }
    }
    private func maybeHangUp() {
        // Only once the reply stream is over AND every clip has sounded:
        // he was losing the last half-word of his goodbye (2026-08-27).
        if stopAfterPlayback && turnTask == nil && queued == 0 {
            stopAfterPlayback = false
            stop(reason: "murray hung up")
        }
    }

    // MARK: playback

    /// The ring preheat: ask the opening-line turn NOW (the phone is still
    /// ringing) through the engine's own stream, so the ordinary turn
    /// rules apply — no second stream to collide with his first words
    /// (2026-08-28: answered fast, spoke, and the two turns fought).
    private(set) var preheating = false
    func preheatTurn(_ text: String) {
        guard !running, turnTask == nil else { return }
        preheating = true
        lock.lock(); endpointer.turnSent(); lock.unlock()
        upload(Data(text.utf8), mime: "text/plain")
    }

    private var preStartClips: [Data] = []

    private func enqueue(_ mp3: Data) {
        guard running else {
            // The ring preheat streams his opening line before the audio
            // session exists; hold it and play the moment the call is up.
            if preheating { lock.lock(); preStartClips.append(mp3); lock.unlock() }
            return
        }
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
            let s = AVAudioSession.sharedInstance()
            let out = s.currentRoute.outputs.first?.portType
            switch reason {
            case .newDeviceAvailable:
                // Headphones or Bluetooth arrived: drop any override so they take over.
                try? s.overrideOutputAudioPort(.none)
            case .oldDeviceUnavailable, .categoryChange, .routeConfigurationChange:
                // Back on the phone itself: receiver → loudspeaker, once per change.
                if out == .builtInReceiver { try? s.overrideOutputAudioPort(.speaker) }
            default: break                                   // .override is the user's choice: keep it
            }
            let kind = self.routeInfo()["kind"] as? String
            UIDevice.current.isProximityMonitoringEnabled = kind == "earpiece"
            self.emitRoute()
        }
    }

    /// locked | background | foreground, read on the main thread (a turn
    /// starts off it). Locked is background with protected data gone.
    private func screenState() -> String {
        var out = "foreground"
        let work = {
            let app = UIApplication.shared
            if app.applicationState == .active { out = "foreground" }
            else if !app.isProtectedDataAvailable { out = "locked" }
            else { out = "background" }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return out
    }

    // MARK: cues — "I heard you", "I didn't", "still thinking"
    // Synthesised on the engine so they sound with the screen locked.

    enum Cue { case sent, notHeard, tick, working }
    /// Soft pulse while a tool runs — Settings toggle, default on.
    var workSound: Bool = UserDefaults.standard.object(forKey: "murray.workSound") as? Bool ?? true
    private var workTimer: Timer?

    private func tone(_ steps: [(hz: Float, ms: Int)], db: Float) -> AVAudioPCMBuffer? {
        guard let fmt = fxFormat else { return nil }
        let sr = Float(fmt.sampleRate)
        let total = steps.reduce(0) { $0 + Int(sr * Float($1.ms) / 1000) }
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total)) else { return nil }
        buf.frameLength = AVAudioFrameCount(total)
        let amp = powf(10, (db + max(-24, min(24, gainDb))) / 20)
        var i = 0
        for s in steps {
            let n = Int(sr * Float(s.ms) / 1000)
            let ramp = max(1, Int(sr * 0.005))
            for k in 0..<n {
                let env = min(1, Float(min(k, n - 1 - k)) / Float(ramp))
                let v = s.hz > 0 ? sinf(2 * .pi * s.hz * Float(k) / sr) * amp * env : 0
                for ch in 0..<Int(fmt.channelCount) { buf.floatChannelData?[ch][i] = v }
                i += 1
            }
        }
        return buf
    }

    func cue(_ c: Cue) {
        let buf: AVAudioPCMBuffer?
        switch c {
        case .sent:     buf = tone([(880, 60), (1320, 60)], db: -16)
        case .notHeard: buf = tone([(330, 80), (0, 60), (330, 80)], db: -14)
        case .tick:     buf = tone([(660, 30)], db: -24)
        case .working:  buf = tone([(196, 40), (0, 30), (220, 40)], db: -30)
        }
        guard let b = buf else { return }
        DispatchQueue.main.async {
            guard self.running else { return }
            if !self.audio.isRunning { try? self.audio.start() }
            self.fxPlayer.scheduleBuffer(b, completionHandler: nil)
            if !self.fxPlayer.isPlaying { self.fxPlayer.play() }
        }
    }

    /// A tool is running: the room should not go dead. Starts on a
    /// non-empty `doing` label while thinking; stops on the first clip, on
    /// the label clearing, on any state change, on stop.
    private func startWorking() {
        guard workSound else { return }
        DispatchQueue.main.async {
            if self.workTimer != nil { return }
            self.cue(.working)
            self.workTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self = self, self.running, self.turnTask != nil, self.queued == 0 else { self?.stopWorking(); return }
                self.cue(.working)
            }
        }
    }
    private func stopWorking() { DispatchQueue.main.async { self.workTimer?.invalidate(); self.workTimer = nil } }

    private func startTicks() {
        stopTicks()
        guard thinkTick else { return }
        DispatchQueue.main.async {
            self.tickTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
                guard let self = self, self.running, self.turnTask != nil, self.queued == 0 else { return }
                self.cue(.tick)
            }
        }
    }
    private func stopTicks() { stopWorking(); DispatchQueue.main.async { self.tickTimer?.invalidate(); self.tickTimer = nil } }

    // MARK: events

    private func emit(_ name: String, _ data: [String: Any]) {
        onEvent?(name, data)
    }

    func snapshot() -> [String: Any] {
        ["state": running ? endpointer.state.rawValue : "ended", "callId": callId,
         "turns": turns.map { ["who": $0.who, "text": $0.text] }]
    }
}
