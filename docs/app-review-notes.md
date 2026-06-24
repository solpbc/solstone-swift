# App Review Notes

## Watch Companion

The watch companion is an owner-started observer. During a session the owner starts from the watch UI, it captures audio and location on the watch, then hands those files to the paired iPhone for the owner's private journal.

The watch target declares `UIBackgroundModes` with exactly `audio` and `location` so an owner-started session can continue briefly in the background. These sessions are not always-on, do not auto-start, and are foreground-armed by the owner before background execution is possible.

Location authorization on the watch is When In Use only. The watch target declares `NSLocationWhenInUseUsageDescription` and does not declare `NSLocationAlwaysAndWhenInUseUsageDescription`.

System indicators stay visible. Audio capture uses `AVAudioRecorder`, so the watchOS recording indicator remains system-driven. Location sets `allowsBackgroundLocationUpdates = true` only during an active owner session and resets it to `false` on stop. There is no `showsBackgroundLocationIndicator` usage; that API does not exist on watchOS.

The app has no analytics, telemetry, or crash reporting anywhere. This is reflected in `Watch/PrivacyInfo.xcprivacy`: `NSPrivacyTracking` is `false`, `NSPrivacyTrackingDomains` is empty, and `NSPrivacyCollectedDataTypes` is empty.

The watch relays only to the paired iPhone over WatchConnectivity. There is no direct watch-to-cloud path. Nothing is shared with sol pbc from the watch.

The watch target does not use HealthKit or `HKWorkoutSession`; the target has no HealthKit import.

`NSPrivacyAccessedAPITypes` is an explicit empty array. The rule applied for this manifest is: declare a required-reason API category if and only if the watch target's own code calls an API in that category; omit otherwise. The watch target sweep found no file-timestamp APIs, no disk-space APIs, no boot-time APIs, and no `UserDefaults` or `@AppStorage` APIs. The watch persists through plain Foundation file operations such as `createDirectory`, `write(to:options:.atomic)`, `readData`, `contentsOfDirectory`, `fileExists`, and `moveItem`, and reads only `.isDirectoryKey`; none of those are required-reason APIs. App Group access uses `containerURL(forSecurityApplicationGroupIdentifier:)`, which is a container URL accessor, not a required-reason API.

The iOS relay additions (`WatchSegmentDrain`, `WatchRelayReceiver`, and `WatchUploaderHolder`) introduce no new required-reason API category, so this lode does not add an iOS privacy manifest.
