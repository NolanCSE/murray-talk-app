import Foundation

/// Incremental parser for the talk server's event stream: frames separated
/// by a blank line, each with `event: name` and one or more `data:` lines.
/// Feed it bytes as they arrive; it hands back complete frames only.
public struct SSEFrame: Equatable {
    public let event: String
    public let data: String
    public init(event: String, data: String) { self.event = event; self.data = data }
}

public struct SSEParser {
    private var buffer = ""

    public init() {}

    public mutating func feed(_ chunk: Data) -> [SSEFrame] {
        buffer += String(decoding: chunk, as: UTF8.self)
        var out: [SSEFrame] = []
        while let cut = buffer.range(of: "\n\n") {
            let raw = String(buffer[buffer.startIndex..<cut.lowerBound])
            buffer = String(buffer[cut.upperBound...])
            var event = "message", data = ""
            for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("event: ") { event = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
                else if line.hasPrefix("event:") { event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                else if line.hasPrefix("data: ") { data += String(line.dropFirst(6)) }
                else if line.hasPrefix("data:") { data += String(line.dropFirst(5)) }
            }
            if !data.isEmpty { out.append(SSEFrame(event: event, data: data)) }
        }
        return out
    }
}
