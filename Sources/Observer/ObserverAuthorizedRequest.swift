// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum ObserverAuthorizedRequest {
    static func make(url: URL, handle: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(handle)", forHTTPHeaderField: "Authorization")
        return request
    }
}
