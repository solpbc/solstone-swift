// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Crypto
import Foundation
import os
import XCTest

nonisolated func transferTestMatchingReceipt(
    body: Data,
    contentType: String? = nil,
    status: String = "ok"
) -> Data {
    guard let contentType else {
        return Data(#"{"status":"\#(status)"}"#.utf8)
    }
    guard let boundaryMatch = contentType.range(of: "boundary=") else {
        return Data(#"{"status":"\#(status)"}"#.utf8)
    }
    var boundaryStr = String(contentType[boundaryMatch.upperBound...])
    if boundaryStr.hasPrefix("\"") && boundaryStr.hasSuffix("\"") {
        boundaryStr = String(boundaryStr.dropFirst().dropLast())
    }
    if let semi = boundaryStr.firstIndex(of: ";") {
        boundaryStr = String(boundaryStr[..<semi])
    }
    let boundary = Data(("--" + boundaryStr).utf8)
    let crlf = Data("\r\n".utf8)
    let headerSep = Data("\r\n\r\n".utf8)

    var fileDescriptors: [[String: Any]] = []

    var cursor = body.startIndex
    var parts: [Data] = []
    while let range = body[cursor...].range(of: boundary) {
        if cursor != range.lowerBound {
            parts.append(body[cursor..<range.lowerBound])
        }
        cursor = range.upperBound
    }

    for rawPart in parts {
        var part = rawPart
        if part.starts(with: crlf) {
            part = part.dropFirst(crlf.count)
        }
        let dashCrlf = Data("--\r\n".utf8)
        let dashes = Data("--".utf8)
        if part.count >= dashCrlf.count, part.suffix(dashCrlf.count) == dashCrlf {
            part = part.dropLast(dashCrlf.count)
        } else if part.count >= dashes.count, part.suffix(dashes.count) == dashes {
            part = part.dropLast(dashes.count)
        }
        if part.count >= crlf.count, part.suffix(crlf.count) == crlf {
            part = part.dropLast(crlf.count)
        }
        guard !part.isEmpty, part != dashes else { continue }
        guard let sepRange = part.range(of: headerSep) else { continue }
        let headerData = part[..<sepRange.lowerBound]
        var content = part[sepRange.upperBound...]
        if content.count >= crlf.count, content.suffix(crlf.count) == crlf {
            content = content.dropLast(crlf.count)
        }
        let headerStr = String(decoding: headerData, as: UTF8.self)
        guard headerStr.contains("name=\"files\"") || headerStr.contains("name=\"\(ObserverServerURL.filesFieldName)\"") else {
            continue
        }
        guard let fnMatch = headerStr.range(of: #"filename="([^"]+)""#, options: .regularExpression) else {
            continue
        }
        let fnFull = String(headerStr[fnMatch])
        let filename = fnFull.replacingOccurrences(of: "filename=\"", with: "").replacingOccurrences(of: "\"", with: "")

        let size = content.count
        var hasher = Crypto.SHA256()
        hasher.update(data: content)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        fileDescriptors.append([
            "submitted": filename,
            "size": size,
            "sha256": digest,
            "disposition": "written",
        ])
    }

    let payload: [String: Any] = [
        "status": status,
        "file_descriptors": fileDescriptors,
    ]
    return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(#"{"status":"\#(status)"}"#.utf8)
}

nonisolated struct TransferCutoverEndpointResolver: TransferEndpointResolver {
    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        .unavailable("waiting")
    }
}

@MainActor
func makeTransferCutoverHarness(
    rootURL: URL,
    fileSystem: (any TransferFileSystem)? = nil,
    sessionConfiguration: URLSessionConfiguration? = nil,
    endpointResolver: any TransferEndpointResolver = TransferCutoverEndpointResolver(),
    clock: any TransferClock = LiveTransferClock(),
    diagnosticsSink: @escaping TransferDiagnosticSink = { _ in },
    maxConcurrent: Int = 3,
    bodyBuilder: @escaping TransferBodyBuilder = DefaultTransferBodyBuilder.build
) -> (
    engine: TransferEngine,
    mirror: TransferStatusMirror,
    enqueuer: ObserverAudioTransferEnqueuer,
    watch: WatchUploaderHolder
) {
    let mirror = TransferStatusMirror()
    let transport = sessionConfiguration.map {
        TransferTransport(sessionConfiguration: $0)
    } ?? TransferTransport()
    let engine = TransferEngine(
        spool: TransferSpool(rootURL: rootURL, fileSystem: fileSystem ?? FoundationTransferFileSystem()),
        transport: transport,
        endpointResolver: endpointResolver,
        clock: clock,
        diagnosticsSink: diagnosticsSink,
        statusMirror: mirror,
        maxConcurrent: maxConcurrent,
        bodyBuilder: bodyBuilder
    )
    let enqueuer = ObserverAudioTransferEnqueuer(engine: engine)
    return (
        engine,
        mirror,
        enqueuer,
        WatchUploaderHolder(transferEngine: engine, mirror: mirror)
    )
}

func makeTransferTestURLSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TransferURLProtocol.self]
    return configuration
}

func makeTransferTestSidecar(
    sessionID: UUID,
    chunkIndex: Int,
    startedAt: Date,
    durationS: TimeInterval = 0.2,
    mode: ObserverMode = .meeting,
    locationJSONL: Data? = nil
) -> ChunkSidecar {
    ChunkSidecar(
        segment: ObserverSegmentNaming.segmentString(for: startedAt, durationSeconds: durationS),
        day: ObserverSegmentNaming.dayString(for: startedAt),
        chunkIndex: chunkIndex,
        startedAt: startedAt,
        durationS: durationS,
        sessionID: sessionID,
        mode: mode,
        locationJSONL: locationJSONL
    )
}

func writeTransferTestSidecar(_ sidecar: ChunkSidecar, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(sidecar).write(to: url, options: .atomic)
}

func writeTransferTestAudio(
    at url: URL,
    seconds: TimeInterval = 0.2,
    sampleRate: Double = 16_000
) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(max(1, Int((seconds * sampleRate).rounded())))
        ),
        let channel = buffer.int16ChannelData?[0]
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    let frameCount = Int(buffer.frameCapacity)
    for index in 0..<frameCount {
        channel[index] = Int16(index % 128)
    }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ],
        commonFormat: .pcmFormatInt16,
        interleaved: false
    )
    try file.write(from: buffer)
    file.close()
}

func transferTestPathExists(containing needle: String, under root: URL) -> Bool {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        return false
    }
    for case let url as URL in enumerator where url.path.contains(needle) {
        return true
    }
    return false
}

final class QuarantineMoveFailingFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.path.contains("TransferQuarantine") {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

func transferTestWaitFor(
    _ label: String,
    timeout: Duration = .seconds(3),
    condition: @escaping @Sendable () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Timed out waiting for \(label)", file: file, line: line)
}

func transferTestResponse(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

func transferTestBoundaryItemID(from request: URLRequest) -> UUID? {
    guard let contentType = request.value(forHTTPHeaderField: "Content-Type"),
          let range = contentType.range(of: "boundary=Boundary-")
    else {
        return nil
    }
    return UUID(uuidString: String(contentType[range.upperBound...]))
}

extension XCTestCase {
    @nonobjc
    func assertNoSourceCodeRemovesTransferQuarantine() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url)
            for line in text.split(separator: "\n") where line.contains("quarantine") || line.contains("TransferQuarantine") {
                XCTAssertFalse(line.contains("removeItem"), "\(url.lastPathComponent): \(line)")
            }
        }
    }

    @nonobjc
    func multipartValue(named name: String, in body: Data) -> String? {
        let string = String(decoding: body, as: UTF8.self)
        guard let headerRange = string.range(of: #"Content-Disposition: form-data; name="\#(name)""#),
              let separator = string[headerRange.upperBound...].range(of: "\r\n\r\n")
        else { return nil }
        let valueStart = separator.upperBound
        guard let valueEnd = string[valueStart...].range(of: "\r\n--")?.lowerBound else { return nil }
        return String(string[valueStart..<valueEnd])
    }

    @nonobjc
    func multipartValue(named name: String, in body: String) throws -> String {
        let marker = "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        let start = try XCTUnwrap(body.range(of: marker))
        let rest = body[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\r\n--"))
        return String(rest[..<end.lowerBound])
    }

    @nonobjc
    func multipartEnvelope(in body: Data) throws -> [String: Any] {
        let envelope = try XCTUnwrap(self.multipartValue(named: "envelope", in: body))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
    }

    @nonobjc
    func multipartEnvelope(in body: String) throws -> [String: Any] {
        let value = try self.multipartValue(named: "envelope", in: body)
        let object = try JSONSerialization.jsonObject(with: Data(value.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }
}

nonisolated func makeTransferTestWatchManifest(itemID: UUID = UUID(), sidecar: ChunkSidecar) -> TransferManifest {
    ObserverAudioTransferEnqueuer.makeWatchManifest(itemID: itemID, sidecar: sidecar, hasLocation: false)
}
