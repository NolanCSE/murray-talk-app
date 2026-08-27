import Foundation
import Capacitor
import AVFoundation

/// window.Capacitor.Plugins.MurrayCall — the page's handle on the native call.
/// Methods: start({callkit?}), end, setMuted({on}), holdStart, holdEnd, sync.
/// Events: state {state}, heard {text, empty?}, say {text, why}, doing
/// {label}, error {where, why}, ended {reason}, level {rms}.
@objc(MurrayCallPlugin)
public class MurrayCallPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "MurrayCallPlugin"
    public let jsName = "MurrayCall"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "end", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setMuted", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "holdStart", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "holdEnd", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sync", returnType: CAPPluginReturnPromise),
    ]

    private var engine: CallEngine?
    private var callkit: CallKitBridge?
    private let recent = RingLog(capacity: 200)

    private func baseURL() -> URL? {
        // The talk URL (secret included) is the app's own server.url.
        guard let u = Bundle.main.url(forResource: "capacitor.config", withExtension: "json"),
              let d = try? Data(contentsOf: u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let s = (j["server"] as? [String: Any])?["url"] as? String,
              var url = URL(string: s) else { return nil }
        if !url.path.hasSuffix("/") { url = url.appendingPathComponent("") }
        return url
    }

    @objc func start(_ call: CAPPluginCall) {
        guard engine == nil else { call.resolve(["callId": engine!.callId, "already": true]); return }
        guard let base = baseURL() else { call.reject("no talk url in the app config"); return }
        let useCallKit = call.getBool("callkit") ?? true
        let e = CallEngine(base: base)
        e.onEvent = { [weak self] name, data in
            self?.recent.push(name, data)
            self?.notifyListeners(name, data: data)
        }
        engine = e
        let callId = "app-" + String(UUID().uuidString.lowercased().prefix(12))
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            guard granted else { call.reject("microphone permission denied"); self.engine = nil; return }
            if useCallKit {
                let ck = CallKitBridge()
                self.callkit = ck
                ck.configureSession = { try e.configureSession() }
                ck.onActivate = { [weak self] in
                    do { try e.start(callId: callId) } catch { self?.notifyListeners("error", data: ["where": "start", "why": error.localizedDescription]) }
                }
                ck.onEnded = { [weak self] in
                    e.stop(reason: "call ended")
                    self?.engine = nil; self?.callkit = nil
                }
                ck.start { err in
                    if let err = err { self.engine = nil; self.callkit = nil; call.reject("CallKit refused: \(err.localizedDescription)") }
                    else { call.resolve(["callId": callId, "callkit": true]) }
                }
            } else {
                do {
                    try e.configureSession()
                    try AVAudioSession.sharedInstance().setActive(true)
                    try e.start(callId: callId)
                    call.resolve(["callId": callId, "callkit": false])
                } catch { self.engine = nil; call.reject("could not start: \(error.localizedDescription)") }
            }
        }
    }

    @objc func end(_ call: CAPPluginCall) {
        if let ck = callkit { ck.end() }            // → onEnded → engine.stop
        else { engine?.stop(reason: "ended from the page"); engine = nil }
        call.resolve()
    }

    @objc func setMuted(_ call: CAPPluginCall) {
        engine?.setMuted(call.getBool("on") ?? false); call.resolve()
    }
    @objc func holdStart(_ call: CAPPluginCall) { engine?.holdStart(); call.resolve() }
    @objc func holdEnd(_ call: CAPPluginCall) { engine?.holdEnd(); call.resolve() }

    @objc func sync(_ call: CAPPluginCall) {
        var out: [String: Any] = engine?.snapshot() ?? ["state": "ended", "callId": "", "turns": []]
        out["recent"] = recent.all()
        call.resolve(out)
    }
}

/// The last N events, so a page that was asleep can catch up via sync().
final class RingLog {
    private var items: [[String: Any]] = []
    private let capacity: Int
    private let lock = NSLock()
    init(capacity: Int) { self.capacity = capacity }
    func push(_ name: String, _ data: [String: Any]) {
        if name == "level" { return }
        lock.lock(); items.append(["event": name, "data": data, "at": Date().timeIntervalSince1970])
        if items.count > capacity { items.removeFirst(items.count - capacity) }
        lock.unlock()
    }
    func all() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return items }
}
