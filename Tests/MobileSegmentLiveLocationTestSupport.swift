// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

@MainActor
struct MobileSegmentLiveLocationTestSupport {
    let clock: MockObserverClock

    func writeActiveLocation(
        segmentID: UUID,
        store: MobileSegmentStore,
        sources: Set<MobileSegmentSource> = [.location],
        startedAt: Date? = nil
    ) throws -> URL {
        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt ?? self.clock.now().addingTimeInterval(-300),
            openedWithSources: sources,
            activeSourceSetVersion: 1
        )
        return try store.createActive(manifest: manifest)
    }

    func writeActiveLocationPart(
        segmentID: UUID,
        store: MobileSegmentStore,
        tier: LocationTier = .balanced,
        accuracy: LocationAccuracy = .full,
        gap: Bool = false,
        fixes: [LocationFix]? = nil,
        visits: [LocationVisit] = [],
        appendTornFix: Bool = false
    ) throws -> URL {
        let startedAt = self.clock.now().addingTimeInterval(-300)
        let directory = try self.writeActiveLocation(segmentID: segmentID, store: store, startedAt: startedAt)
        try self.writeLocationPart(
            segmentID: segmentID,
            store: store,
            directory: directory,
            startedAt: startedAt,
            tier: tier,
            accuracy: accuracy,
            gap: gap,
            fixes: fixes ?? [self.locationFix(at: startedAt.addingTimeInterval(60))],
            visits: visits,
            appendTornFix: appendTornFix
        )
        return directory
    }

    func writeLocationPart(
        segmentID: UUID,
        store: MobileSegmentStore,
        directory: URL,
        startedAt: Date,
        tier: LocationTier = .balanced,
        accuracy: LocationAccuracy = .full,
        gap: Bool = false,
        fixes: [LocationFix],
        visits: [LocationVisit] = [],
        appendTornFix: Bool = false
    ) throws {
        let partURL = store.locationPartURL(in: directory)
        try store.appendData(
            try MobileSegmentLocationWriter.liveStateLine(
                segmentID: segmentID,
                segmentStart: startedAt,
                tier: tier,
                accuracy: accuracy,
                gap: gap,
                recordedAt: startedAt
            ),
            to: partURL
        )
        for fix in fixes {
            try store.appendData(try MobileSegmentLocationWriter.liveFixLine(fix), to: partURL)
        }
        for visit in visits {
            try store.appendData(try MobileSegmentLocationWriter.liveVisitLine(visit), to: partURL)
        }
        if appendTornFix {
            let torn = String(
                decoding: try MobileSegmentLocationWriter.liveFixLine(
                    self.locationFix(at: startedAt.addingTimeInterval(120))
                ),
                as: UTF8.self
            ).dropLast(12)
            try store.appendData(Data(torn.utf8), to: partURL)
        }
    }

    func writeLocationLiveness(
        segmentID: UUID,
        store: MobileSegmentStore,
        lastSeenAt: Date,
        fixCount: Int = 1,
        visitCount: Int = 0,
        gap: Bool = false
    ) throws {
        let directory = store.segmentDirectoryURL(.active, segmentID: segmentID)
        try self.writeLocationLiveness(
            segmentID: segmentID,
            store: store,
            directory: directory,
            lastSeenAt: lastSeenAt,
            fixCount: fixCount,
            visitCount: visitCount,
            gap: gap
        )
    }

    func writeLocationLiveness(
        segmentID: UUID,
        store: MobileSegmentStore,
        directory: URL,
        lastSeenAt: Date,
        fixCount: Int = 1,
        visitCount: Int = 0,
        gap: Bool = false
    ) throws {
        let liveness = MobileSegmentLocationSegmentLiveness(
            segmentID: segmentID,
            sourceSetVersion: 1,
            lastSeenAt: lastSeenAt,
            fixCount: fixCount,
            visitCount: visitCount,
            gap: gap
        )
        let data = try MobileSegmentLocationWriter.encoder().encode(liveness)
        try store.writeData(data, to: store.locationLivenessURL(in: directory))
    }

    func locationFix(at date: Date, lat: Double = 37.3349) -> LocationFix {
        LocationFix(
            t: date,
            lat: lat,
            lon: -122.0090,
            hAcc: 12,
            alt: nil,
            vAcc: nil,
            speed: nil,
            course: nil,
            stationary: false
        )
    }

    func locationVisit(arrival: Date, departure: Date?) -> LocationVisit {
        LocationVisit(
            arrival: arrival,
            departure: departure,
            lat: 37.3349,
            lon: -122.0090,
            hAcc: 24
        )
    }
}
