import Foundation

nonisolated struct ServerSentEvent: Sendable, Equatable {
    let event: String?
    let data: String
}

nonisolated struct ServerSentEventParser: Sendable {
    private var partialLine: [UInt8] = []
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func append(_ data: Data) -> [ServerSentEvent] {
        guard !data.isEmpty else { return [] }

        self.partialLine.append(contentsOf: data)
        var events: [ServerSentEvent] = []

        while let newline = self.partialLine.firstIndex(of: 0x0A) {
            let lineEnd = newline > self.partialLine.startIndex && self.partialLine[self.partialLine.index(before: newline)] == 0x0D
                ? self.partialLine.index(before: newline)
                : newline
            let line = String(decoding: self.partialLine[..<lineEnd], as: UTF8.self)
            self.partialLine.removeSubrange(...newline)
            if let event = self.consume(line: line) {
                events.append(event)
            }
        }

        return events
    }

    mutating func finish() -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        if !self.partialLine.isEmpty {
            let lineEnd = self.partialLine.last == 0x0D
                ? self.partialLine.index(before: self.partialLine.endIndex)
                : self.partialLine.endIndex
            let line = String(decoding: self.partialLine[..<lineEnd], as: UTF8.self)
            self.partialLine.removeAll(keepingCapacity: true)
            if let event = self.consume(line: line) {
                events.append(event)
            }
        }
        if let event = self.flushEvent() {
            events.append(event)
        }
        return events
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
