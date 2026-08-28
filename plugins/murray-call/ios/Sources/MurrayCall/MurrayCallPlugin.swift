import Foundation
import Capacitor
import AVFoundation
import AVKit
import UIKit

/// window.Capacitor.Plugins.MurrayCall — the page's handle on the native call.
/// Methods: start({callkit?}), end, setMuted({on}), holdStart, holdEnd, sync,
/// nudge({text}), setVolume({db}), diag, setRoute({speaker}).
/// Events: state {state}, heard {text, empty?}, say {text, why}, doing
/// {label}, error {where, why}, ended {reason}, level {rms, start, floor},
/// route {kind, name, speaker}.
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
        CAPPluginMethod(name: "nudge", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setVolume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "diag", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setRoute", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSensitivity", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pickRoute", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setVoiceProcessing", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setCues", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "route", returnType: CAPPluginReturnPromise),
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
        e.gainDb = Float(UserDefaults.standard.object(forKey: "murray.gainDb") as? Double ?? 8)
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
                ck.onMute = { on in e.setMuted(on) }
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
    @objc func diag(_ call: CAPPluginCall) {
        var d: [String: Any] = engine?.diagnostics() ?? ["running": false, "note": "no engine (call not started)"]
        d["permission"] = "\(AVAudioSession.sharedInstance().recordPermission.rawValue)"
        d["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        call.resolve(d)
    }
    @objc func setVolume(_ call: CAPPluginCall) {
        // dB of gain on Murray's voice: 0 = as mastered, +8 default, +16 loud.
        let db = Float(call.getDouble("db") ?? 8)
        UserDefaults.standard.set(Double(db), forKey: "murray.gainDb")
        engine?.gainDb = db
        call.resolve(["db": db])
    }
    /// setRoute({speaker: true|false}) — speaker or earpiece. Remembered
    /// for the next call; applied at once if one is running.
    @objc func setRoute(_ call: CAPPluginCall) {
        let on = call.getBool("speaker") ?? true
        if let e = engine { e.setSpeaker(on); call.resolve(e.routeInfo()) }
        else { UserDefaults.standard.set(on, forKey: "murray.speaker"); call.resolve(["kind": on ? "speaker" : "earpiece", "name": "", "speaker": on]) }
    }
    /// pickRoute() — the standard iOS audio-route sheet (iPhone / Speaker /
    /// any Bluetooth device), the same one the Phone app shows.
    private var picker: AVRoutePickerView?
    @objc func pickRoute(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let host = self.bridge?.viewController?.view else { call.reject("no view"); return }
            let p = self.picker ?? AVRoutePickerView(frame: CGRect(x: -100, y: -100, width: 44, height: 44))
            if self.picker == nil { p.alpha = 0.02; host.addSubview(p); self.picker = p }
            if let b = p.subviews.compactMap({ $0 as? UIButton }).first { b.sendActions(for: .touchUpInside); call.resolve() }
            else { call.reject("route picker has no button on this iOS") }
        }
    }
    @objc func route(_ call: CAPPluginCall) {
        call.resolve(engine?.routeInfo() ?? ["kind": "none", "name": "", "speaker": false])
    }
    /// setVoiceProcessing({on}) — Apple's echo cancellation + noise
    /// suppression on the microphone. Remembered; restarts a live mic.
    @objc func setVoiceProcessing(_ call: CAPPluginCall) {
        let on = call.getBool("on") ?? false
        if let e = engine { e.setVoiceProcessing(on) } else { UserDefaults.standard.set(on, forKey: "murray.vp") }
        call.resolve(["on": on])
    }
    /// setCues({thinkTick}) — the faint tick every 6 s while he thinks.
    @objc func setCues(_ call: CAPPluginCall) {
        let tick = call.getBool("thinkTick") ?? false
        UserDefaults.standard.set(tick, forKey: "murray.thinkTick")
        engine?.thinkTick = tick
        call.resolve(["thinkTick": tick])
    }
    /// setSensitivity({level: "low"|"normal"|"high"}) — how quietly he can
    /// be spoken to before a turn opens. Remembered; applied to a live call.
    @objc func setSensitivity(_ call: CAPPluginCall) {
        let level = call.getString("level") ?? "normal"
        if let e = engine { e.setSensitivity(level) } else { UserDefaults.standard.set(level, forKey: "murray.sensitivity") }
        call.resolve(["level": level])
    }
    @objc func nudge(_ call: CAPPluginCall) { engine?.nudge(call.getString("text") ?? ""); call.resolve() }

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
