import Foundation

/// Second-order Butterworth high-pass for turn detection only. Road and
/// wind noise live under ~200 Hz; a voice has nearly nothing there. The
/// gate listens through this filter; Scribe still gets the whole band.
public struct HighPass {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    public init(cutoffHz: Float = 250, sampleRate: Float = 16000) {
        let w0 = 2 * Float.pi * cutoffHz / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * 0.7071)                     // Q = 1/sqrt(2)
        let a0 = 1 + alpha
        b0 = ((1 + cosw) / 2) / a0
        b1 = (-(1 + cosw)) / a0
        b2 = ((1 + cosw) / 2) / a0
        a1 = (-2 * cosw) / a0
        a2 = (1 - alpha) / a0
    }

    /// Filters a block in place-order, returning the filtered copy.
    public mutating func process(_ x: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let y = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x[i]; y2 = y1; y1 = y
            out[i] = y
        }
        return out
    }
}
