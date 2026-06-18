import Foundation

nonisolated struct ServerSentEvent: Sendable, Equatable {
    let event: String?
    let data: String
}

nonisolated struct ServerSentEventParser: Sendable {
    private var partialLine = ""
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func append(_ data: Data) -> [ServerSentEvent] {
        guard !data.isEmpty else { return [] }

        self.partialLine += String(decoding: data, as: UTF8.self)
        var events: [ServerSentEvent] = []

        while let newline = self.partialLine.firstIndex(of: "\n") {
            var line = String(self.partialLine[..<newline])
            self.partialLine.removeSubrange(...newline)
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            if let event = self.consume(line: line) {
                events.append(event)
            }
        }

        return events
    }

    mutating func finish() -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        if !self.partialLine.isEmpty {
            var line = self.partialLine
            self.partialLine = ""
            if line.hasSuffix("\r") {
                line.removeLast()
            }
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
