# App Review Notes

## Naming

The App Store listing name is solstone. The installed iOS and watchOS app display name is also solstone.

The solstone app is what the owner installs on each device. The journal is the owner's private memory, on a computer they choose. The owner can connect the app to that journal.

## Watch Companion

The solstone app on the watch is owner-started. During a session that the owner starts from the watch UI, the app takes in the audio and location the owner shares with it on the watch; that material then goes to the paired iPhone, and from there into the owner's private journal.

The watch target declares `UIBackgroundModes` with exactly `audio` and `location` so an owner-started session can continue briefly in the background. These sessions are not always-on, do not auto-start, and are foreground-armed by the owner before background execution is possible.

Location authorization on the watch is When In Use only. The watch target declares `NSLocationWhenInUseUsageDescription` and does not declare `NSLocationAlwaysAndWhenInUseUsageDescription`.

System indicators stay visible. Audio uses `AVAudioRecorder`, so watchOS controls the microphone status indicator. Location sets `allowsBackgroundLocationUpdates = true` only during an active owner session and resets it to `false` on stop. There is no `showsBackgroundLocationIndicator` usage; that API does not exist on watchOS.

The app has no analytics, telemetry, or crash reporting anywhere. This is reflected in `Watch/PrivacyInfo.xcprivacy`: `NSPrivacyTracking` is `false`, `NSPrivacyTrackingDomains` is empty, and `NSPrivacyCollectedDataTypes` is empty.

The watch relays only to the paired iPhone over WatchConnectivity. There is no direct watch-to-cloud path. Nothing is shared with sol pbc from the watch.

The watch target does not use HealthKit or `HKWorkoutSession`; the target has no HealthKit import.

`NSPrivacyAccessedAPITypes` is an explicit empty array. The rule applied for this manifest is: declare a required-reason API category if and only if the watch target's own code calls an API in that category; omit otherwise. The watch target sweep found no file-timestamp APIs, no disk-space APIs, no boot-time APIs, and no `UserDefaults` or `@AppStorage` APIs. The watch persists through plain Foundation file operations such as `createDirectory`, `write(to:options:.atomic)`, `readData`, `contentsOfDirectory`, `fileExists`, and `moveItem`, and reads only `.isDirectoryKey`; none of those are required-reason APIs. App Group access uses `containerURL(forSecurityApplicationGroupIdentifier:)`, which is a container URL accessor, not a required-reason API.

The iOS relay additions (`WatchSegmentDrain`, `WatchRelayReceiver`, and `WatchUploaderHolder`) introduce no new required-reason API category, so this lode does not add an iOS privacy manifest.
