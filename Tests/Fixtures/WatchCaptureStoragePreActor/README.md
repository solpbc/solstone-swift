# Watch capture pre-actor fixtures

These files are ground truth captured before filesystem and relay ownership move
to `WatchCaptureStorageActor`.

`empty.json`, `one-segment.json`, `several-segments.json`, and
`mixed-state.json` are final storage-tree snapshots: each entry contains a path
relative to the capture root and the base64-encoded file contents.

`mixed-state-trace.json` is the ordered execution trace for a launch
reconciliation followed by a relay drain of three prepared segments: queued,
transferring with an existing transfer, and delivered awaiting ACK. Every
`writer` event records a `called`, `returned`, or `threw` phase for one
`WatchFileWriting` method. A `transferFile` event records the bundle path and
canonical JSON metadata at the synchronous WCSession boundary. Sequence values
are zero-based and impose the required total order across both kinds of event.

The current relay creates its attempt UUID internally, so the trace replaces
that metadata value with `<generated-attempt-id>`; all other recorded values are
literal. A `writer` `writeData` event with phase `returned` for a relay-bundle
path must precede the corresponding `transferFile` event. This means the bundle
write completed durably before the transfer was submitted.
