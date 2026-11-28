// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import ImageIO

/// Image pixel inspection, on-device PNG conversion for convertible formats,
/// and deterministic screenshot proof checks for folder images.
nonisolated enum FoldersImageSupport {
    /// Read image dimensions without decoding full pixel buffers.
    static func pixelCount(in data: Data) -> UInt64? {
        guard let (width, height) = ScreenshotsWire.pixels(in: data),
              width > 0, height > 0
        else { return nil }
        return UInt64(width) * UInt64(height)
    }

    /// Read image dimensions directly from a file URL without loading pixel data.
    static func pixelCount(at url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return UInt64(width) * UInt64(height)
    }

    /// Convert a convertible image (`heic`, `heif`, `tif`, `tiff`, `gif`, `bmp`) to PNG,
    /// preserving metadata and enforcing `maxPixels` and `maxBytes`.
    static func convertToPNG(
        _ data: Data,
        maxPixels: UInt64 = FolderConstants.maxImagePixels,
        maxBytes: UInt64 = FolderConstants.maxContentBytes
    ) -> Data? {
        guard let px = Self.pixelCount(in: data), px <= maxPixels else {
            return nil
        }
        guard let png = ScreenshotsWire.pngKeepingMetadata(data),
              UInt64(png.count) <= maxBytes
        else {
            return nil
        }
        return png
    }

    /// Deterministic screenshot proof for an image file stored inside a folder.
    /// Matches Apple/PNG screenshot metadata markers without guessing from generic filenames.
    static func isScreenshotImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return false
        }
        return Self.hasScreenshotMetadata(props)
    }

    static func isScreenshotImage(data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return false
        }
        return Self.hasScreenshotMetadata(props)
    }

    static func hasScreenshotMetadata(_ props: [CFString: Any]) -> Bool {
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let comment = exif[kCGImagePropertyExifUserComment] as? String,
               comment.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("screenshot") == .orderedSame
            {
                return true
            }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let software = tiff[kCGImagePropertyTIFFSoftware] as? String
        {
            let lower = software.lowercased()
            if lower.contains("screenshot") || lower.contains("screencapture") {
                return true
            }
        }
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            if let software = png[kCGImagePropertyPNGSoftware] as? String {
                let lower = software.lowercased()
                if lower.contains("screenshot") || lower.contains("screencapture") {
                    return true
                }
            }
            if let desc = png[kCGImagePropertyPNGDescription] as? String,
               desc.lowercased().contains("screenshot")
            {
                return true
            }
        }
        return false
    }
}
