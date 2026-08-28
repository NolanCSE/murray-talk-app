import Foundation
import CallKit
import AVFoundation

/// Makes the conversation a real iOS call: lock-screen UI, End from the
/// lock screen, and a call-priority audio session that survives the app
/// leaving the foreground. No VoIP push yet (phase 3): every call is
/// outgoing, started by the page.
final class CallKitBridge: NSObject, CXProviderDelegate {
    /// One provider for the app's lifetime: an incoming push must be
    /// reported to a provider that already exists (phase 2).
    static let shared = CallKitBridge()
    private let provider: CXProvider
    private let controller = CXCallController()
    private var uuid: UUID?
    var onActivate: (() -> Void)?
    var onEnded: (() -> Void)?
    var onAnswer: (() -> Void)?
    var configureSession: (() throws -> Void)?

    override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        cfg.includesCallsInRecents = false
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func start(completion: @escaping (Error?) -> Void) {
        let id = UUID(); uuid = id
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "Murray"))
        action.isVideo = false
        controller.request(CXTransaction(action: action)) { err in
            if err == nil {
                self.provider.reportOutgoingCall(with: id, startedConnectingAt: Date())
                self.provider.reportOutgoingCall(with: id, connectedAt: Date())
            }
            completion(err)
        }
    }

    func end() {
        guard let id = uuid else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: id))) { _ in }
    }

    /// Murray is ringing. Full-screen call UI, lock screen included.
    func reportIncoming(line: String, completion: @escaping (Error?) -> Void) {
        let id = UUID(); uuid = id
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Murray")
        update.localizedCallerName = "Murray"
        update.hasVideo = false
        provider.reportNewIncomingCall(with: id, update: update) { err in completion(err) }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        do { try configureSession?() } catch { action.fail(); return }
        onAnswer?()
        action.fulfill()
    }

    // MARK: CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        uuid = nil
        onEnded?()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        do { try configureSession?() } catch { action.fail(); return }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        onActivate?()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        uuid = nil
        onEnded?()
        action.fulfill()
    }

    /// The lock screen's / CarPlay's mute button. Was a no-op (2026-08-28).
    var onMute: ((Bool) -> Void)?
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        onMute?(action.isMuted)
        action.fulfill()
    }
}
