# Observer health beacon

The observer health beacon is a diagnostics-only POST from each observer audio upload source: mobile, omi, and watch. It reports upload queue health to the paired journal at `/app/devices/health` using the existing observer bearer handle. It does not include captured audio, transcript content, captured file paths, or location payloads.

Each beacon starts when the app shell starts, emits once immediately when the source already has a configured journal, local port, persisted registration prefix, and cached handle, then emits every five minutes while the app process is running. Missing identity, missing local port, or an unpaired journal skips emission without initiating registration.

The JSON contract is owned by the journal receiver lode. In this app, the payload is limited to the source identity and stream metadata, uptime, latest successful source contact, pending upload depth, recent upload error count, and a redacted single-line last error reason. Journal-side ingest rejections and receiver safety-net health are separate health sources.
