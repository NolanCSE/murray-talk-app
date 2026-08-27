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

    public init(config: EndpointerConfig = EndpointerConfig()) {
        self.config = config
    }

    /// External transitions the engine reports back.
    public mutating func turnSent() { if state == .user { state = .thinking } }
    public mutating func replyDone() { if state == .thinking || state == .speaking { state = muted ? .muted : .listening } }
    public mutating func playbackStarted(at t: Double) { playbackBeganAt = t; if state != .user { state = .speaking } }
    public mutating func playbackStopped() { if state == .speaking { state = .listening } }
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
            return .none
        case .listening:
            if hold { return .none }
            if rms > config.start { state = .user; turnBeganAt = t; quietSince = t; return .startTurn }
            return .none
        case .speaking:
            if hold { return .none }
            // Barge-in: his voice over Murray's, but not the echo of Murray's
            // own opening, which arrives inside the grace window.
            if rms > config.start && t - playbackBeganAt > config.bargeGraceMs {
                state = .user; turnBeganAt = t; quietSince = t
                return .bargeIn
            }
            return .none
        case .user:
            if hold { return .none }
            if rms > config.stop { quietSince = t }
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
