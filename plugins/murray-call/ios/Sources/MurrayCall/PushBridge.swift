import Foundation
import PushKit
import AVFoundation

/// Phase 2: Murray rings the phone. A VoIP push arrives (even with the app
/// killed and the screen locked), iOS launches us in the background, and we
/// MUST report an incoming call to CallKit before the delegate returns —
/// that is the PushKit contract. Answering starts the same CallEngine the
/// page uses; the page adopts the live call whenever it is next opened
/// (native sync() on load).
public final class PushBridge: NSObject, PKPushRegistryDelegate {
    public static let shared = PushBridge()
    private var registry: PKPushRegistry?
    private(set) var lastToken: String = ""

    /// The one live engine, shared between an answered incoming call and
    /// the plugin (which adopts it when the page attaches).
    static var engine: CallEngine?
    static var engineEvents: ((String, [String: Any]) -> Void)?
    /// What Murray rang about — spoken as the first turn on answer.
    private var ringText: String = ""
    private var callId: String = ""

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
        ck.onEnded = { PushBridge.stopEngine(reason: "call ended") }
        ck.reportIncoming(line: text) { _ in completion() }
        // The engine exists from the ring: its own turn machinery asks the
        // opening line now and holds the audio until the session is live.
        if PushBridge.engine == nil, let base = PushBridge.baseURL() {
            let e = CallEngine(base: base)
            e.gainDb = Float(UserDefaults.standard.object(forKey: "murray.gainDb") as? Double ?? 8)
            e.onEvent = { name, data in PushBridge.engineEvents?(name, data) }
            PushBridge.engine = e
            e.preheatTurn("[Call connected: YOU rang him about: " + text
                          + " — he is picking up right now. Say why you called in one "
                          + "sentence, then wait for him.]")
        }
    }

    // MARK: the answered call

    private func answered() {
        guard let e = PushBridge.engine else { return }
        let ck = CallKitBridge.shared
        ck.configureSession = { try e.configureSession() }
        let id = callId
        ck.onActivate = {
            do { try e.start(callId: id) }
            catch { PushBridge.engineEvents?("error", ["where": "answer", "why": error.localizedDescription]) }
        }
    }

    static func stopEngine(reason: String) {
        engine?.stop(reason: reason)
        engine = nil
    }
}
