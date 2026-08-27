import Foundation

/// 16-bit mono PCM to a WAV file in memory. ElevenLabs Scribe takes WAV as
/// is, so the app never needs an encoder.
public enum WAV {
    public static func encode(pcm16: [Int16], sampleRate: Int) -> Data {
        var d = Data()
        let dataBytes = UInt32(pcm16.count * 2)
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16)
        u16(1); u16(1)                                  // PCM, mono
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2))
        u16(2); u16(16)                                 // block align, bits
        d.append("data".data(using: .ascii)!); u32(dataBytes)
        pcm16.withUnsafeBufferPointer { p in
            for s in p { var x = s.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        }
        return d
    }

    /// Root-mean-square of float samples in [-1, 1] — the same number the
    /// page computes from its AnalyserNode.
    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard samples.count > 0 else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
