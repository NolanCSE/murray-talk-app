import Foundation
import PushKit
import AVFoundation

/// Phase 2: Murray rings the phone. A VoIP push arrives (even with the app
/// killed and the screen locked), iOS launches us in the background, and we
/// MUST report an incoming call to CallKit before the delegate returns —
/// that is the PushKit contract. Answering starts the same CallEngine the
/// page uses; the page adopts the live call whenever it is next opened
/// (native sync() on load).
public final class PushBridge: NSObject, PKPushRegistryDelegate, URLSessionDataDelegate {
    public static let shared = PushBridge()
    private var registry: PKPushRegistry?
    private(set) var lastToken: String = ""

    /// The one live engine, shared between an answered incoming call and
    /// the plugin (which adopts it when the page attaches).
    static var engine: CallEngine?
    static var engineEvents: ((String, [String: Any]) -> Void)?
    /// What Murray rang about — spoken as the first turn on answer.
    private var ringText: String = ""
    // The preheat: his opening line is requested the moment the push
    // arrives, so the audio is ready (or already streaming) when Nolan
    // answers — he used to pick up to silence (2026-08-28).
    private var callId: String = ""
    private var preheatSession: URLSession?
    private var preheatBuf = Data()
    private var pendingClips: [Data] = []
    private var liveEngine: CallEngine?
    private let clipLock = NSLock()

    public func activate() {
        guard registry == nil else { return }
        let r = PKPushRegistry(queue: .main)
        r.delegate = self
        r.desiredPushTypes = [.voIP]
        registry = r
    }

    static func baseURL() -> URL? {
        guard let u = Bundle.main.url(forResource: "capacitor.config", withExtension: "json"),
              let d = try? Data(contentsOf: u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let s = (j["server"] as? [String: Any])?["url"] as? String,
              var url = URL(string: s) else { return nil }
        if !url.path.hasSuffix("/") { url = url.appendingPathComponent("") }
        return url
    }

    // MARK: PKPushRegistryDelegate

    public func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        let token = credentials.token.map { String(format: "%02x", $0) }.joined()
        lastToken = token
        guard let base = PushBridge.baseURL() else { return }
        var req = URLRequest(url: base.appendingPathComponent("push/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token, "kind": "voip"])
        URLSession.shared.dataTask(with: req).resume()
    }

    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        lastToken = ""
    }

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        let text = payload.dictionaryPayload["text"] as? String ?? "Murray is calling."
        ringText = text
        callId = "ring-" + String(UUID().uuidString.lowercased().prefix(12))
        let ck = CallKitBridge.shared
        ck.onAnswer = { [weak self] in self?.answered() }
        ck.onEnded = { [weak self] in
            self?.preheatSession?.invalidateAndCancel(); self?.preheatSession = nil
            self?.clipLock.lock(); self?.pendingClips = []; self?.liveEngine = nil; self?.clipLock.unlock()
            PushBridge.stopEngine(reason: "call ended")
        }
        ck.reportIncoming(line: text) { _ in completion() }
        preheat(text)
    }

    // MARK: the preheat

    private func preheat(_ text: String) {
        guard let base = PushBridge.baseURL() else { return }
        preheatBuf = Data(); pendingClips = []
        var req = URLRequest(url: base.appendingPathComponent("turn"))
        req.httpMethod = "POST"
        req.setValue(callId, forHTTPHeaderField: "X-Talk-Call")
        req.setValue("text/plain", forHTTPHeaderField: "X-Talk-Mime")
        req.httpBody = Data(("[Call connected: YOU rang him about: " + text
                             + " — he is picking up right now. Say why you called in one "
                             + "sentence, then wait for him.]").utf8)
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        preheatSession = s
        s.dataTask(with: req).resume()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        preheatBuf.append(data)
        while let r = preheatBuf.range(of: Data("\n\n".utf8)) {
            let frame = String(decoding: preheatBuf.subdata(in: preheatBuf.startIndex..<r.lowerBound), as: UTF8.self)
            preheatBuf.removeSubrange(preheatBuf.startIndex..<r.upperBound)
            for line in frame.split(separator: "\n") where line.hasPrefix("data:") {
                guard let obj = try? JSONSerialization.jsonObject(
                    with: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)) as? [String: Any]
                else { continue }
                if let t = obj["text"] as? String, !t.isEmpty {
                    PushBridge.engineEvents?("say", ["text": t, "why": ""])
                }
                if let b64 = obj["audio"] as? String, !b64.isEmpty, let mp3 = Data(base64Encoded: b64) {
                    clipLock.lock()
                    if let e = liveEngine { clipLock.unlock(); e.playExternal(mp3) }
                    else { pendingClips.append(mp3); clipLock.unlock() }
                }
            }
        }
    }

    // MARK: the answered call

    private func answered() {
        guard PushBridge.engine == nil, let base = PushBridge.baseURL() else { return }
        let e = CallEngine(base: base)
        e.gainDb = Float(UserDefaults.standard.object(forKey: "murray.gainDb") as? Double ?? 8)
        e.onEvent = { name, data in PushBridge.engineEvents?(name, data) }
        PushBridge.engine = e
        let ck = CallKitBridge.shared
        ck.configureSession = { try e.configureSession() }
        let id = callId
        ck.onActivate = { [weak self] in
            do {
                try e.start(callId: id)
                // The preheat asked the question while the phone rang; hand
                // its audio (buffered or still arriving) straight to the
                // engine so he speaks the moment the line is up.
                if let self = self {
                    self.clipLock.lock()
                    let ready = self.pendingClips; self.pendingClips = []; self.liveEngine = e
                    self.clipLock.unlock()
                    for c in ready { e.playExternal(c) }
                }
            } catch {
                PushBridge.engineEvents?("error", ["where": "answer", "why": error.localizedDescription])
            }
        }
    }

    static func stopEngine(reason: String) {
        engine?.stop(reason: reason)
        engine = nil
    }
}
