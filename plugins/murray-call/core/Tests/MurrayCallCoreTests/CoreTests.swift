import XCTest
@testable import MurrayCallCore

final class EndpointerTests: XCTestCase {
    func testSpeechThenQuietMakesATurn() {
        var e = Endpointer()
        XCTAssertEqual(e.level(0.05, at: 0), .startTurn)
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
        _ = e.level(0.05, at: 0)
        var a: EndpointerAction = .none
        for t in stride(from: 20.0, through: 25000, by: 20) { a = e.level(0.05, at: t); if a != .none { break } }
        XCTAssertEqual(a, .endTurn)
    }

    func testBargeInRespectsGrace() {
        var e = Endpointer()
        e.playbackStarted(at: 0)
        XCTAssertEqual(e.state, .speaking)
        XCTAssertEqual(e.level(0.08, at: 300), .none)      // echo window
        XCTAssertEqual(e.level(0.08, at: 700), .bargeIn)
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

final class AdaptiveGateTests: XCTestCase {
    func testQuietRoomLowersTheStartLevel() {
        var e = Endpointer()
        XCTAssertEqual(e.startLevel, 0.030, accuracy: 1e-6)        // begins where the fixed gate was
        // a quiet phone at arm's length: RMS 0.002 for two seconds
        for t in stride(from: 0.0, through: 2000, by: 20) { XCTAssertEqual(e.level(0.002, at: t), .none) }
        XCTAssertLessThan(e.startLevel, 0.010)
        // soft speech the old gate never opened for
        XCTAssertEqual(e.level(0.015, at: 2020), .startTurn)
        XCTAssertEqual(e.state, .user)
    }
    func testSpeechDoesNotLiftTheFloor() {
        var e = Endpointer()
        for t in stride(from: 0.0, through: 2000, by: 20) { _ = e.level(0.002, at: t) }
        let before = e.floor
        _ = e.level(0.05, at: 2020)                                  // turn opens; .user ignores tracking
        for t in stride(from: 2040.0, through: 4000, by: 20) { _ = e.level(0.05, at: t) }
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
        XCTAssertEqual(e.level(0.015, at: 2020), .none)
        XCTAssertEqual(e.level(0.031, at: 2040), .startTurn)
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
