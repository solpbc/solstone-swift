// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation
import os
import XCTest

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
    authProvider: @escaping @Sendable (TransferManifest) async throws -> String = { _ in "test-transfer-key" },
    endpointResolver: any TransferEndpointResolver = TransferCutoverEndpointResolver(),
    clock: any TransferClock = LiveTransferClock(),
    diagnosticsSink: @escaping TransferDiagnosticSink = { _ in },
    maxConcurrent: Int = 3,
    bodyBuilder: @escaping TransferBodyBuilder = DefaultTransferBodyBuilder.build
) -> (
    engine: TransferEngine,
    mirror: TransferStatusMirror,
    enqueuer: ObserverAudioTransferEnqueuer,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder
) {
    let mirror = TransferStatusMirror()
    let transport = sessionConfiguration.map {
        TransferTransport(sessionConfiguration: $0, authProvider: authProvider)
    } ?? TransferTransport(authProvider: authProvider)
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
        OmiUploaderHolder(transferEngine: engine, mirror: mirror),
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
    func multipartMeta(in body: Data) throws -> [String: Any] {
        let meta = try XCTUnwrap(self.multipartValue(named: "meta", in: body))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(meta.utf8)) as? [String: Any])
    }

    @nonobjc
    func multipartMeta(in body: String) throws -> [String: Any] {
        let value = try self.multipartValue(named: "meta", in: body)
        let object = try JSONSerialization.jsonObject(with: Data(value.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }
}

@MainActor
func makeTransferTestRegistration(
    streamType: String,
    version: String,
    key: String,
    prefix: String,
    localPort: Int = 7071
) -> ObserverRegistration {
    let keyBox = OSAllocatedUnfairLock<String?>(initialState: key)
    let prefixBox = OSAllocatedUnfairLock<String?>(initialState: prefix)
    let registration = ObserverRegistration(
        hostname: "test-device",
        version: version,
        streamType: streamType,
        session: URLSession(configuration: .ephemeral),
        retryDelays: [0],
        sleep: { _ in },
        loadKey: { keyBox.withLock { $0 } },
        saveKey: { value in keyBox.withLock { $0 = value } },
        deleteKey: { keyBox.withLock { $0 = nil } },
        loadPrefix: { prefixBox.withLock { $0 } },
        savePrefix: { value in prefixBox.withLock { $0 = value } },
        deletePrefix: { prefixBox.withLock { $0 = nil } }
    )
    registration.activeLocalPort = localPort
    return registration
}
