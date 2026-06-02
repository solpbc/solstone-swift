// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ImageIO
import os
import SwiftUI
import UIKit

private let onThisPhoneLog = Logger(subsystem: "app.solstone.swift", category: "on-this-phone")

struct OnThisPhonePreview: View {
    let item: OnThisPhoneItem

    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 120)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: self.symbolName)
                        .font(.title2)
                    Text(self.item.filename ?? SourceVocabulary.notProvided)
                        .font(.subheadline)
                        .lineLimit(2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: self.item.rawFileURL) {
            self.thumbnail = await Self.thumbnail(for: self.item)
        }
    }
}

private extension OnThisPhonePreview {
    var symbolName: String {
        guard let contentType = self.item.contentType?.lowercased() else {
            return "doc"
        }
        if contentType == "com.adobe.pdf" || contentType == "application/pdf" {
            return "doc.richtext"
        }
        if contentType.contains("audio") || contentType == "public.mpeg-4-audio" || contentType == "com.apple.m4a-audio" {
            return "waveform"
        }
        if Self.isImageContentType(contentType) {
            return "photo"
        }
        return "doc"
    }

    static func thumbnail(for item: OnThisPhoneItem) async -> UIImage? {
        guard let rawFileURL = item.rawFileURL,
              let contentType = item.contentType?.lowercased(),
              self.isImageContentType(contentType)
        else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithURL(rawFileURL as CFURL, nil) else {
            onThisPhoneLog.debug("on-this-phone thumbnail unavailable: image source failed")
            return nil
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            onThisPhoneLog.debug("on-this-phone thumbnail unavailable: downsample failed")
            return nil
        }
        return UIImage(cgImage: image)
    }

    static func isImageContentType(_ contentType: String) -> Bool {
        switch contentType {
        case "public.jpeg", "public.jpg", "image/jpeg",
             "public.png", "image/png",
             "public.heic", "public.heif", "image/heic", "image/heif",
             "com.compuserve.gif", "image/gif",
             "org.webmproject.webp", "public.webp", "image/webp",
             "public.tiff", "image/tiff":
            true
        default:
            false
        }
    }
}
