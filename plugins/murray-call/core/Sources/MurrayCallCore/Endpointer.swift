import Foundation

/// The turn-taking state machine, ported from the talk page's JS so both
/// halves behave identically. Pure: it is fed RMS levels with timestamps and
/// answers with actions; no audio, no clocks of its own.
///
/// Constants mirror server/vm/talk_page.py exactly — change them together.
public struct EndpointerConfig: Equatable {
    public var start: Float = 0.030          // RMS that begins a turn
    public var stop: Float = 0.018           // RMS below which he is quiet
    public var quietMs: Double = 1200        // that long quiet ends the turn (900 cut sentences mid-way, 2026-08-28)
    public var maxMs: Double = 20000         // a turn never runs longer
    public var minMs: Double = 600           // shorter than this is a cough
    public var bargeGraceMs: Double = 600    // ignore "speech" this soon after playback starts (echo)
    // Adaptive gate. The raw iPhone microphone (no AGC, voice processing
    // off) speaks at a fraction of the browser's auto-gained level, so a
    // fixed 0.030 only ever opened for hold-to-talk (2026-08-27). The start
    // level follows the measured quiet floor instead: floor * startRatio,
    // never below minStart, never above `start`.
    public var adaptive: Bool = true
    /// Ceiling for the adaptive gate. Was `start` (0.030): with the x4
    /// pre-gain a noisy room sat above it, the turn never ended and GO AHEAD
    /// stuck (2026-08-28). Levels are post-gain, so this is generous.
    public var maxStart: Float = 0.25
    public var minStart: Float = 0.003
    public var startRatio: Float = 2.5
    public var stopRatio: Float = 0.5       // stop = start * stopRatio
    public var tailMs: Double = 700          // after his audio stops, ignore the room's reverb this long
    /// Level barge-in needs echo cancellation; without it "speech" over his
    /// playback is his own speaker. The engine turns this off when voice
    /// processing is off. (Before 2026-08-27 the state still flipped to
    /// .user here even though the engine then ignored the action.)
    public var levelBargeIn: Bool = true
    // Speech has a shape; a passing car does not (2026-08-27, AirPods on
    // the pavement). A turn opens only after `onsetMs` continuously above
    // the gate, and a turn that ran `steadyMs` or longer without a single
    // dip below the stop level is steady noise: dropped, and the floor is
    // lifted to it so the source raises the gate instead of re-triggering.
    public var onsetMs: Double = 120
    public var bargeOnsetMs: Double = 250    // longer over his voice: a cough must not stop him
    public var steadyMs: Double = 2500
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
    private var aboveSince: Double? = nil        // onset hold
    private var dips = 0                         // times the level fell below stop then rose again, this turn
    private var below = false
    private var turnSum: Float = 0, turnSq: Float = 0, turnN: Int = 0
    /// Why the last turn was discarded, for the engine to say out loud.
    public private(set) var lastDiscard: String = ""
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
        return min(config.maxStart, max(config.minStart, floor * config.startRatio))
    }
    /// Below this he has gone quiet.
    public var stopLevel: Float {
        guard config.adaptive else { return config.stop }
        return startLevel * config.stopRatio
    }

    /// Follow the floor: quickly down, slowly up, so speech does not lift it.
    private mutating func track(_ rms: Float) {
        guard config.adaptive else { return }
        let k: Float = rms < floor ? 0.2 : 0.03
        floor += (rms - floor) * k
        floor = max(floor, 0.0005)
    }

    public init(config: EndpointerConfig = EndpointerConfig()) {
        self.config = config
    }

    /// The sensitivity setting: how far above the quiet floor speech must
    /// rise. "high" opens for a murmur across the desk; "low" wants a clear
    /// voice. Levels are post pre-gain (the engine boosts the raw mic).
    public mutating func setLevelBargeIn(_ on: Bool) { config.levelBargeIn = on }

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
        _ = openTurn(at: t)
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
            if rms <= startLevel { track(rms); aboveSince = nil; return .none }
            if aboveSince == nil { aboveSince = t }
            if t - aboveSince! < config.onsetMs { return .none }   // a click, a door: not yet a voice
            aboveSince = nil
            return openTurn(at: t)
        case .speaking:
            if hold || !config.levelBargeIn { return .none }
            // Barge-in: his voice over Murray's, but not the echo of Murray's
            // own opening, which arrives inside the grace window.
            if rms > startLevel && t - playbackBeganAt > config.bargeGraceMs {
                if aboveSince == nil { aboveSince = t }
                if t - aboveSince! < config.bargeOnsetMs { return .none }
                aboveSince = nil
                _ = openTurn(at: t)
                return .bargeIn
            }
            aboveSince = nil
            return .none
        case .user:
            if hold { return .none }
            // Shape is judged over the voiced part only: the quiet that ends
            // every turn would make a passing car look bursty.
            if rms > stopLevel { turnSum += rms; turnSq += rms * rms; turnN += 1 }
            if rms > stopLevel { quietSince = t; if below { dips += 1; below = false } }
            else { below = true }
            if t - turnBeganAt >= config.maxMs { return endTurnNow(at: t) }
            if t - quietSince >= config.quietMs { return endTurnNow(at: t) }
            return .none
        }
    }

    private mutating func openTurn(at t: Double) -> EndpointerAction {
        state = .user; turnBeganAt = t; quietSince = t
        dips = 0; below = false; turnSum = 0; turnSq = 0; turnN = 0
        return .startTurn
    }

    /// Number of syllable/word gaps seen in the current or last turn.
    public var dipsInTurn: Int { dips }
    /// Spread of the level over the turn (std / mean). Speech is bursty
    /// (≳ 0.6); a car, a fan, wind are flat (≲ 0.3).
    public var spreadInTurn: Float {
        guard turnN > 1 else { return 0 }
        let mean = turnSum / Float(turnN)
        guard mean > 0 else { return 0 }
        let variance = max(0, turnSq / Float(turnN) - mean * mean)
        return variance.squareRoot() / mean
    }
    public var steadySpread: Float = 0.35

    private mutating func endTurnNow(at t: Double) -> EndpointerAction {
        let length = t - turnBeganAt
        if length < config.minMs {
            lastDiscard = "too short"
            state = muted ? .muted : .listening
            return .discardTurn
        }
        if !hold && length >= config.steadyMs && dips == 0 && turnN > 1 && spreadInTurn < steadySpread {
            // No shape at all — flat level AND no gaps: a car, a fan, the
            // wind. (Gaps alone were not enough: a raised floor hides the
            // gaps in real speech and every turn was dropped, 2026-08-28.)
            // Lift the floor to it, but never past where the room would
            // block a raised voice.
            let mean = turnSum / Float(turnN)
            floor = min(max(floor, mean * 0.8), config.maxStart / config.startRatio)
            lastDiscard = String(format: "steady noise %.3f", mean)
            state = muted ? .muted : .listening
            return .discardTurn
        }
        lastDiscard = ""
        state = .thinking
        return .endTurn
    }
}
