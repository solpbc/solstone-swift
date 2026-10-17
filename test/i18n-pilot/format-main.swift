// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
let bundle = Bundle(path:"DerivedData/Build/Products/Debug-iphonesimulator/solstone-swift.app")!
let count = 10000
let raw = bundle.localizedString(forKey:"ios.sourceSync.finishSyncingCardBody", value:nil, table:"Pilot")
print("raw:",raw)
print("format current:", String(format:raw,locale:Locale(identifier:"en_US"),count))
print("format nil:", String(format:raw,count))
print("format POSIX:",String(format:raw,locale:Locale(identifier:"en_US_POSIX"),count))
let explicit = LocalizedStringResource("ios.sourceSync.finishSyncingCardBody",defaultValue:"\(count, specifier: "%lld") segments haven't landed yet. tap to keep this syncing in the background after you switch away from the solstone app.",table:"Pilot",locale:Locale(identifier:"en_US"),bundle:.atURL(bundle.bundleURL))
print("explicit:",String(localized:explicit))
let styled = LocalizedStringResource("ios.sourceSync.finishSyncingCardBody",defaultValue:"\(count, format: .number.grouping(.never)) segments haven't landed yet. tap to keep this syncing in the background after you switch away from the solstone app.",table:"Pilot",locale:Locale(identifier:"en_US"),bundle:.atURL(bundle.bundleURL))
print("styled:",String(localized:styled))
