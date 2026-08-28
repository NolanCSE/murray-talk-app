import XCTest
@testable import MurrayCallCore

final class EndpointerTests: XCTestCase {
    func testSpeechThenQuietMakesATurn() {
        var e = Endpointer()
        XCTAssertEqual(speak(&e, 0.05, from: 0, ms: 140), .startTurn)   // onset hold satisfied
        XCTAssertEqual(e.state, .user)
        for t in stride(from: 20.0, through: 1000, by: 20) { XCTAssertEqual(e.level(0.05, at: t), .none) }
        // quiet for 900ms
        var a: EndpointerAction = .none
        for t in stride(from: 1020.0, through: 2000, by: 20) { a = e.level(0.0, at: t); if a != .none { break } }
        XCTAssertEqual(a, .endTurn)
        XCTAssertEqual(e.state, .thinking)
    }

    func testTooShortIsDiscarded() {
        // Length is measured from the turn's start, quiet included (as the
        // page does), so the automatic path can never be under MIN_MS; a
        // quick tap on hold-to-talk can.
        var e = Endpointer()
        XCTAssertEqual(e.holdStart(at: 0), .startTurn)
        XCTAssertEqual(e.holdEnd(at: 200), .discardTurn)
        XCTAssertEqual(e.state, .listening)
    }

    func testMaxLengthCuts() {
        var e = Endpointer()
        _ = speak(&e, 0.05, from: 0, ms: 140)
        var a: EndpointerAction = .none
        var t = 160.0
        while t <= 25000 {                                    // modulated, so it is speech, until maxMs cuts it
            a = e.level(Int(t / 200) % 2 == 0 ? 0.05 : 0.0, at: t); if a != .none { break }; t += 20
        }
        XCTAssertEqual(a, .endTurn)
    }

    func testBargeInRespectsGrace() {
        var e = Endpointer()
        e.playbackStarted(at: 0)
        XCTAssertEqual(e.state, .speaking)
        XCTAssertEqual(e.level(0.08, at: 300), .none)      // echo window
        XCTAssertEqual(e.level(0.08, at: 700), .bargeIn)   // barge-in has no onset hold: the bar-less interrupt
        XCTAssertEqual(e.state, .user)
    }

    func testHoldSuspendsAutomaticEndpointing() {
        var e = Endpointer()
        XCTAssertEqual(e.holdStart(at: 0), .startTurn)
        for t in stride(from: 20.0, through: 5000, by: 20) { XCTAssertEqual(e.level(0.0, at: t), .none) }
        XCTAssertEqual(e.holdEnd(at: 5000), .endTurn)
    }

    func testMutedNeverStarts() {
        var e = Endpointer()
        XCTAssertEqual(e.setMuted(true, at: 0), .none)
        XCTAssertEqual(e.state, .muted)
        XCTAssertEqual(e.level(0.5, at: 10), .none)
        XCTAssertEqual(e.holdStart(at: 20), .startTurn)   // hold still works while muted
    }

    func testTextTurnFromListening() {
        var e = Endpointer()
        e.turnSent()                                  // a nudge, no mic involved
        XCTAssertEqual(e.state, .thinking)
        XCTAssertEqual(e.level(0.9, at: 10), .none)
        e.replyDone()
        XCTAssertEqual(e.state, .listening)
    }

    func testThinkingIgnoresLevels() {
        var e = Endpointer()
        _ = e.holdStart(at: 0); _ = e.holdEnd(at: 1000)
        XCTAssertEqual(e.state, .thinking)
        XCTAssertEqual(e.level(0.9, at: 1100), .none)
        e.replyDone()
        XCTAssertEqual(e.state, .listening)
    }
}

/// Feed a constant level every 20 ms for `ms`; returns the first non-.none action.
func speak(_ e: inout Endpointer, _ rms: Float, from t0: Double, ms: Double) -> EndpointerAction {
    var t = t0
    while t <= t0 + ms { let a = e.level(rms, at: t); if a != .none { return a }; t += 20 }
    return .none
}

final class NoiseShapeTests: XCTestCase {
    func testAClickDoesNotOpenATurn() {
        var e = Endpointer()
        XCTAssertEqual(speak(&e, 0.5, from: 0, ms: 80), .none)      // 80 ms spike
        XCTAssertEqual(e.level(0.0, at: 100), .none)
        XCTAssertEqual(e.state, .listening)
        XCTAssertEqual(speak(&e, 0.5, from: 200, ms: 140), .startTurn)
    }
    func testSteadyNoiseIsDroppedAndLiftsTheFloor() {
        var e = Endpointer()
        for t in stride(from: 0.0, through: 1000, by: 20) { _ = e.level(0.002, at: t) }
        let floorBefore = e.floor
        XCTAssertEqual(speak(&e, 0.04, from: 1100, ms: 140), .startTurn)        // a car arrives
        var a: EndpointerAction = .none
        for t in stride(from: 1260.0, through: 5000, by: 20) { a = e.level(0.04, at: t); if a != .none { break } }
        XCTAssertEqual(a, .none)                                               // still "talking" at 5 s: no quiet yet
        for t in stride(from: 5020.0, through: 6500, by: 20) { a = e.level(0.0, at: t); if a != .none { break } }
        XCTAssertEqual(a, .discardTurn)                                        // 4 s with no dips: not speech
        XCTAssertGreaterThan(e.floor, floorBefore * 5)
        XCTAssertEqual(e.state, .listening)
    }
    func testSpeechHasDipsAndIsSent() {
        var e = Endpointer()
        XCTAssertEqual(speak(&e, 0.05, from: 0, ms: 140), .startTurn)
        var a: EndpointerAction = .none
        var t = 160.0
        while t <= 3000 { a = e.level(Int(t / 300) % 2 == 0 ? 0.05 : 0.0, at: t); if a != .none { break }; t += 20 }
        XCTAssertEqual(a, .none)
        XCTAssertGreaterThan(e.dipsInTurn, 2)
        while t <= 5000 { a = e.level(0.0, at: t); if a != .none { break }; t += 20 }
        XCTAssertEqual(a, .endTurn)
    }
    func testHoldToTalkIsNeverDroppedAsNoise() {
        var e = Endpointer()
        _ = e.holdStart(at: 0)
        for t in stride(from: 20.0, through: 4000, by: 20) { _ = e.level(0.04, at: t) }
        XCTAssertEqual(e.holdEnd(at: 4000), .endTurn)
    }
}

final class HighPassTests: XCTestCase {
    private func gain(_ hz: Float) -> Float {
        var f = HighPass(cutoffHz: 250, sampleRate: 16000)
        let n = 16000
        let x = (0..<n).map { sin(2 * Float.pi * hz * Float($0) / 16000) }
        let y = f.process(x)
        let tail = Array(y[n/2...])
        return tail.withUnsafeBufferPointer { WAV.rms($0) } / Float(0.70710678)
    }
    func testRumbleIsCut() { XCTAssertLessThan(20 * log10(gain(100)), -12) }
    func testVoiceBandPasses() { XCTAssertGreaterThan(20 * log10(gain(1000)), -1) }
}

final class EchoGuardTests: XCTestCase {
    func testStreamEndingDoesNotOpenTheGateWhileAudioPlays() {
        var e = Endpointer(); e.setLevelBargeIn(false)       // no echo cancellation, as on the phone
        _ = e.holdStart(at: 0); _ = e.holdEnd(at: 1000)      // a turn was sent
        e.playbackStarted(at: 1500)                           // first clip sounds
        e.replyDone()                                         // the SSE stream is over, audio still queued
        XCTAssertEqual(e.state, .speaking)
        XCTAssertEqual(e.level(0.5, at: 3000), .none)        // his own voice, loud: ignored
        e.playbackStopped(at: 4000)
        XCTAssertEqual(e.state, .listening)
    }
    func testReverbTailAfterPlaybackIsIgnored() {
        var e = Endpointer()
        e.playbackStarted(at: 0)
        e.playbackStopped(at: 2000)
        XCTAssertEqual(e.level(0.5, at: 2300), .none)        // inside the tail
        XCTAssertEqual(speak(&e, 0.5, from: 2800, ms: 140), .startTurn)   // you, after it
    }
    func testNoBargeInWithoutEchoCancellationKeepsSpeaking() {
        var e = Endpointer(); e.setLevelBargeIn(false)
        e.playbackStarted(at: 0)
        XCTAssertEqual(e.level(0.9, at: 2000), .none)
        XCTAssertEqual(e.state, .speaking)                     // never .user from his own voice
        XCTAssertEqual(e.holdStart(at: 2100), .bargeIn)        // the bar still interrupts him
    }
    func testTextOnlyReplyStillReturnsToListening() {
        var e = Endpointer()
        e.turnSent(); e.replyDone()
        XCTAssertEqual(e.state, .listening)
    }
}

final class AdaptiveGateTests: XCTestCase {
    func testQuietRoomLowersTheStartLevel() {
        var e = Endpointer()
        XCTAssertLessThanOrEqual(e.startLevel, 0.030)               // never above the old fixed gate
        XCTAssertGreaterThan(e.startLevel, 0.015)                   // and not yet lowered: no quiet measured
        // a quiet phone at arm's length: RMS 0.002 for two seconds
        for t in stride(from: 0.0, through: 2000, by: 20) { XCTAssertEqual(e.level(0.002, at: t), .none) }
        XCTAssertLessThan(e.startLevel, 0.010)
        // soft speech the old gate never opened for
        XCTAssertEqual(speak(&e, 0.015, from: 2020, ms: 140), .startTurn)
        XCTAssertEqual(e.state, .user)
    }
    func testSensitivityMovesTheGate() {
        var hi = Endpointer(), lo = Endpointer()
        hi.tune(sensitivity: "high"); lo.tune(sensitivity: "low")
        for t in stride(from: 0.0, through: 2000, by: 20) { _ = hi.level(0.002, at: t); _ = lo.level(0.002, at: t) }
        XCTAssertLessThan(hi.startLevel, lo.startLevel)
        XCTAssertEqual(speak(&hi, 0.005, from: 2020, ms: 140), .startTurn)   // a murmur opens HIGH
        XCTAssertEqual(speak(&lo, 0.005, from: 2020, ms: 140), .none)        // but not LOW
    }
    func testSpeechDoesNotLiftTheFloor() {
        var e = Endpointer()
        for t in stride(from: 0.0, through: 2000, by: 20) { _ = e.level(0.002, at: t) }
        let before = e.floor
        _ = speak(&e, 0.05, from: 2020, ms: 140)                     // turn opens; .user ignores tracking
        for t in stride(from: 2180.0, through: 3000, by: 20) { _ = e.level(0.05, at: t) }
        XCTAssertEqual(e.floor, before)
    }
    func testNoisyRoomRaisesItButNeverAboveTheOldGate() {
        var e = Endpointer()
        for t in stride(from: 0.0, through: 20000, by: 20) { _ = e.level(0.02, at: t) }
        XCTAssertEqual(e.startLevel, 0.030, accuracy: 1e-6)
        XCTAssertEqual(e.state, .listening)
    }
    func testFixedModeIsTheOldBehaviour() {
        var c = EndpointerConfig(); c.adaptive = false
        var e = Endpointer(config: c)
        for t in stride(from: 0.0, through: 2000, by: 20) { _ = e.level(0.002, at: t) }
        XCTAssertEqual(speak(&e, 0.015, from: 2020, ms: 140), .none)
        XCTAssertEqual(speak(&e, 0.031, from: 2200, ms: 140), .startTurn)
    }
}

final class SSEParserTests: XCTestCase {
    func testFramesSplitAcrossChunks() {
        var p = SSEParser()
        XCTAssertEqual(p.feed(Data("event: heard\ndata: {\"te".utf8)), [])
        let got = p.feed(Data("xt\": \"hi\"}\n\nevent: say\ndata: {\"a\":1}\n\n".utf8))
        XCTAssertEqual(got, [SSEFrame(event: "heard", data: "{\"text\": \"hi\"}"),
                             SSEFrame(event: "say", data: "{\"a\":1}")])
    }
    func testMultiLineDataJoins() {
        var p = SSEParser()
        let got = p.feed(Data("data: ab\ndata: cd\n\n".utf8))
        XCTAssertEqual(got, [SSEFrame(event: "message", data: "abcd")])
    }
    func testEmptyDataIsNoFrame() {
        var p = SSEParser()
        XCTAssertEqual(p.feed(Data(": keepalive\n\n".utf8)), [])
    }
}

final class WAVTests: XCTestCase {
    func testHeader() {
        let d = WAV.encode(pcm16: [0, 1000, -1000], sampleRate: 16000)
        XCTAssertEqual(d.count, 44 + 6)
        XCTAssertEqual(String(decoding: d[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: d[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(d[22], 1)                      // mono
        XCTAssertEqual(Int(d[24]) | Int(d[25]) << 8, 16000 & 0xffff)
        XCTAssertEqual(d[34], 16)                     // bits
        XCTAssertEqual(Int(d[40]) | Int(d[41]) << 8, 6) // data bytes
        XCTAssertEqual(d[46], 0xE8); XCTAssertEqual(d[47], 0x03)   // 1000 LE
    }
    func testRMS() {
        let s: [Float] = [0.5, -0.5, 0.5, -0.5]
        s.withUnsafeBufferPointer { XCTAssertEqual(WAV.rms($0), 0.5, accuracy: 1e-6) }
    }
}
