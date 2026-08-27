import Foundation

/// The turn-taking state machine, ported from the talk page's JS so both
/// halves behave identically. Pure: it is fed RMS levels with timestamps and
/// answers with actions; no audio, no clocks of its own.
///
/// Constants mirror server/vm/talk_page.py exactly — change them together.
public struct EndpointerConfig: Equatable {
    public var start: Float = 0.030          // RMS that begins a turn
    public var stop: Float = 0.018           // RMS below which he is quiet
    public var quietMs: Double = 900         // that long quiet ends the turn
    public var maxMs: Double = 20000         // a turn never runs longer
    public var minMs: Double = 600           // shorter than this is a cough
    public var bargeGraceMs: Double = 600    // ignore "speech" this soon after playback starts (echo)
    // Adaptive gate. The raw iPhone microphone (no AGC, voice processing
    // off) speaks at a fraction of the browser's auto-gained level, so a
    // fixed 0.030 only ever opened for hold-to-talk (2026-08-27). The start
    // level follows the measured quiet floor instead: floor * startRatio,
    // never below minStart, never above `start`.
    public var adaptive: Bool = true
    public var minStart: Float = 0.003
    public var startRatio: Float = 2.5
    public var stopRatio: Float = 0.6       // stop = start * stopRatio
    public var tailMs: Double = 700          // after his audio stops, ignore the room's reverb this long
    public init() {}
}

public enum EndpointerState: String, Equatable {
    case listening, user, thinking, speaking, muted, ended
}

public enum EndpointerAction: Equatable {
    case none
    case startTurn                       // begin capturing a turn
    case endTurn                         // capture done: send it
    case discardTurn                     // too short: drop it
    case bargeIn                         // stop playback, then startTurn
}

public struct Endpointer {
    public private(set) var config: EndpointerConfig
    public private(set) var state: EndpointerState = .listening
    public private(set) var hold = false
    public private(set) var muted = false
    private var turnBeganAt: Double = 0
    private var quietSince: Double = 0
    private var playbackBeganAt: Double = 0
    /// True while his audio is coming out of the speaker. Without echo
    /// cancellation the gate must stay shut for as long as that is true —
    /// the reply stream ending is NOT the audio ending (2026-08-27: he
    /// heard himself, because replyDone() opened the gate mid-playback).
    public private(set) var playing = false
    private var quietUntil: Double = 0
    /// Quiet-room RMS, tracked while nobody is talking. Starts where the
    /// fixed thresholds were so the first second behaves as before.
    public private(set) var floor: Float = 0.030 / 3.5

    /// The level that opens a turn right now.
    public var startLevel: Float {
        guard config.adaptive else { return config.start }
        return min(config.start, max(config.minStart, floor * config.startRatio))
    }
    /// Below this he has gone quiet.
    public var stopLevel: Float {
        guard config.adaptive else { return config.stop }
        return startLevel * config.stopRatio
    }

    /// Follow the floor: quickly down, slowly up, so speech does not lift it.
    private mutating func track(_ rms: Float) {
        guard config.adaptive else { return }
        let k: Float = rms < floor ? 0.2 : 0.01
        floor += (rms - floor) * k
        floor = max(floor, 0.0005)
    }

    public init(config: EndpointerConfig = EndpointerConfig()) {
        self.config = config
    }

    /// The sensitivity setting: how far above the quiet floor speech must
    /// rise. "high" opens for a murmur across the desk; "low" wants a clear
    /// voice. Levels are post pre-gain (the engine boosts the raw mic).
    public mutating func tune(sensitivity: String) {
        switch sensitivity {
        case "high": config.minStart = 0.002; config.startRatio = 1.8
        case "low": config.minStart = 0.006; config.startRatio = 3.5
        default: config.minStart = 0.003; config.startRatio = 2.5
        }
    }

    /// External transitions the engine reports back.
    public mutating func turnSent() { if state == .user || state == .listening || state == .muted { state = .thinking } }
    public mutating func replyDone() {
        if state == .thinking || (state == .speaking && !playing) { state = muted ? .muted : .listening }
    }
    public mutating func playbackStarted(at t: Double) { playbackBeganAt = t; playing = true; if state != .user { state = .speaking } }
    public mutating func playbackStopped(at t: Double = 0) {
        playing = false
        quietUntil = t + config.tailMs
        if state == .speaking { state = muted ? .muted : .listening }
    }
    public mutating func end() { state = .ended }

    public mutating func setMuted(_ on: Bool, at t: Double) -> EndpointerAction {
        muted = on
        if on {
            if state == .user && !hold { return endTurnNow(at: t) }
            if state == .listening { state = .muted }
        } else if state == .muted {
            state = .listening
        }
        return .none
    }

    /// Hold-to-talk: the endpointer's automatic decisions are suspended.
    public mutating func holdStart(at t: Double) -> EndpointerAction {
        guard state != .ended, !hold else { return .none }
        hold = true
        let barge = state == .speaking
        state = .user; turnBeganAt = t; quietSince = t
        return barge ? .bargeIn : .startTurn
    }
    public mutating func holdEnd(at t: Double) -> EndpointerAction {
        guard hold else { return .none }
        hold = false
        return endTurnNow(at: t)
    }

    /// One RMS sample. `t` is milliseconds on any monotonic clock.
    public mutating func level(_ rms: Float, at t: Double) -> EndpointerAction {
        switch state {
        case .ended, .thinking:
            return .none
        case .muted:
            track(rms)
            return .none
        case .listening:
            if hold { return .none }
            if t < quietUntil { return .none }           // his reverb tail, not you
            if rms <= startLevel { track(rms) }
            if rms > startLevel { state = .user; turnBeganAt = t; quietSince = t; return .startTurn }
            return .none
        case .speaking:
            if hold { return .none }
            // Barge-in: his voice over Murray's, but not the echo of Murray's
            // own opening, which arrives inside the grace window.
            if rms > startLevel && t - playbackBeganAt > config.bargeGraceMs {
                state = .user; turnBeganAt = t; quietSince = t
                return .bargeIn
            }
            return .none
        case .user:
            if hold { return .none }
            if rms > stopLevel { quietSince = t }
            if t - turnBeganAt >= config.maxMs { return endTurnNow(at: t) }
            if t - quietSince >= config.quietMs { return endTurnNow(at: t) }
            return .none
        }
    }

    private mutating func endTurnNow(at t: Double) -> EndpointerAction {
        let length = t - turnBeganAt
        if length < config.minMs {
            state = muted ? .muted : .listening
            return .discardTurn
        }
        state = .thinking
        return .endTurn
    }
}
