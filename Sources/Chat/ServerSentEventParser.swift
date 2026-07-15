import Foundation

nonisolated struct ServerSentEvent: Sendable, Equatable {
    let event: String?
    let data: String
}

nonisolated struct ServerSentEventParser: Sendable {
    private var buffer: [UInt8] = []
    private var scanIndex: Int = 0
    private var lineStart: Int = 0
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func append(_ data: Data) -> [ServerSentEvent] {
        guard !data.isEmpty else { return [] }

        self.buffer.append(contentsOf: data)
        var events: [ServerSentEvent] = []

        while let newline = self.nextNewline() {
            let lineEnd = newline > self.lineStart && self.buffer[newline - 1] == 0x0D
                ? newline - 1
                : newline
            let line = String(decoding: self.buffer[self.lineStart..<lineEnd], as: UTF8.self)
            self.lineStart = newline + 1
            self.scanIndex = newline + 1
            if let event = self.consume(line: line) {
                events.append(event)
            }
        }

        if self.lineStart > 0 {
            self.buffer.removeSubrange(0..<self.lineStart)
            self.scanIndex -= self.lineStart
            self.lineStart = 0
        }

        return events
    }

    mutating func finish() -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        if self.lineStart < self.buffer.endIndex {
            let lineEnd = self.buffer.last == 0x0D
                ? self.buffer.index(before: self.buffer.endIndex)
                : self.buffer.endIndex
            let line = String(decoding: self.buffer[self.lineStart..<lineEnd], as: UTF8.self)
            if let event = self.consume(line: line) {
                events.append(event)
            }
        }
        self.buffer.removeAll(keepingCapacity: true)
        self.scanIndex = 0
        self.lineStart = 0
        if let event = self.flushEvent() {
            events.append(event)
        }
        return events
    }

    private mutating func nextNewline() -> Int? {
        for index in self.scanIndex..<self.buffer.count {
            if self.buffer[index] == 0x0A {
                return index
            }
        }
        self.scanIndex = self.buffer.count
        return nil
    }

    private mutating func consume(line: String) -> ServerSentEvent? {
        guard !line.isEmpty else {
            return self.flushEvent()
        }
        guard !line.hasPrefix(":") else {
            return nil
        }

        let field: String
        let value: String
        if let separator = line.firstIndex(of: ":") {
            field = String(line[..<separator])
            var rawValue = String(line[line.index(after: separator)...])
            if rawValue.hasPrefix(" ") {
                rawValue.removeFirst()
            }
            value = rawValue
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            self.eventName = value
        case "data":
            self.dataLines.append(value)
        default:
            break
        }

        return nil
    }

    private mutating func flushEvent() -> ServerSentEvent? {
        defer {
            self.eventName = nil
            self.dataLines = []
        }

        guard !self.dataLines.isEmpty else { return nil }
        return ServerSentEvent(event: self.eventName, data: self.dataLines.joined(separator: "\n"))
    }
}
