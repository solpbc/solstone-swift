// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case string(String)
    case int(Int)
    case double(Double)
    case array([JSONValue])
    case object([String: JSONValue])

    enum ValueError: Error, Equatable, Sendable {
        case nonFiniteDouble
    }

    init(double value: Double) throws {
        guard value.isFinite else { throw ValueError.nonFiniteDouble }
        self = .double(value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "non-finite double")
            }
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(value, EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "non-finite double"
                ))
            }
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let object):
            try container.encode(object)
        }
    }

    func foundationObject() throws -> Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .string(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            guard value.isFinite else { throw ValueError.nonFiniteDouble }
            return value
        case .array(let values):
            return try values.map { try $0.foundationObject() }
        case .object(let object):
            var bridged: [String: Any] = [:]
            for (key, value) in object {
                bridged[key] = try value.foundationObject()
            }
            return bridged
        }
    }
}
