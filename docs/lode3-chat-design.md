# Lode 3 chat design

This design replaces the one-shot chat stub with a real convey-backed, event-sourced chat client. It is a clean break: no `StubChatTransport`, no compatibility shim for confidence, and no new markdown dependency. Native answer text uses Apple `Text(markdown:)`.

Implemented corrections (A-E): user-message status reflects POST send success only; offer "yes" is a local dismiss; working trace is manager-level `activeTrace`; queue-depth and support capacity lines are distinct; provenance source IDs are stable refs.

## Goals and boundaries

- POSTing a chat message returns only an acknowledgement. Assistant replies arrive through `/sse/events` plus `/api/chat/session` hydration.
- `ChatManager` remains the single `@MainActor @Observable` reducer for native chat state.
- `ConveyChatTransport` owns URL building, HTTP status mapping, SSE connection lifecycle, heartbeat/comment skipping, reconnect, and re-hydration.
- Confidence is deleted wholesale. Provenance is state + sources + coverage only.
- Runtime sol/convey text is rendered verbatim. App-authored chrome stays lowercase-first through `SourceVocabulary`.

## Transport contract

Ship this protocol:

```swift
nonisolated protocol ChatTransporting: Sendable {
    func postMessage(_ text: String) async -> ChatPostResult
    func events() -> AsyncStream<ChatEvent>
    func declineOffer() async -> Bool
    func confirmDraft(id: String) async -> DraftOutcome
    func cancelDraft(id: String) async -> DraftOutcome
}
```

`events()` returns one cold stream per manager listener. `ChatManager` owns one listener task. `ConveyChatTransport` cancels URLSession work when the stream terminates.

### POST result

```swift
nonisolated enum ChatPostResult: Sendable, Equatable {
    case ack(useID: String, queued: Bool, queueDepth: Int?)
    case queueFull(queueDepth: Int?)
    case unavailable(reason: String?)
    case serverError(status: Int, reason: String?)
    case malformed
    case transport
}
```

Mapping:

- `200..<300`: decode `{use_id, queued, queue_depth?}`. Missing/empty `use_id` is `.malformed`.
- `429` with `reason_code == "chat_queue_full"`: `.queueFull(queueDepth:)`.
- `503` with `reason_code == "agent_unavailable"` or equivalent: `.unavailable(reason:)`.
- Other non-2xx: `.serverError(status:reason:)`, where `reason` comes from decoded error body if present.
- URL/session failure: `.transport`.
- JSON decode failure on an expected ack: `.malformed`.

### Stream event model

```swift
nonisolated enum ChatEvent: Sendable, Equatable {
    case snapshot(ChatSessionSnapshot)
    case ownerMessage(ChatOwnerMessage)
    case solMessage(ChatSolMessage)
    case talentSpawned(ChatTalentActivity)
    case talentFinished(ChatTalentActivity)
    case talentErrored(ChatTalentActivity)
    case chatError(ChatErrorEvent)
    case queueDepth(Int)
    case result(ChatResultEvent)
}

nonisolated struct ChatSessionSnapshot: Sendable, Equatable {
    let latestSolMessage: ChatSolMessage?
    let activeTalents: [ChatTalentActivity]
    let completedTalents: [ChatTalentActivity]
    let queueDepth: Int
}

nonisolated struct ChatOwnerMessage: Sendable, Equatable {
    let id: String
    let text: String
    let requestID: String?
    let useID: String?
    let ts: Date?
}

nonisolated struct ChatSolMessage: Sendable, Equatable {
    let id: String
    let text: String
    let notes: String?
    let requestID: String?
    let useID: String?
    let requestedTarget: String?
    let provenance: AnswerProvenance
    let offer: ChatOffer?
    let draft: ChatDraft?
    let ts: Date?
}

nonisolated struct ChatTalentActivity: Sendable, Equatable, Identifiable {
    let id: String
    let useID: String
    let label: String
    let task: String?
    let ts: Date?
}

nonisolated struct ChatErrorEvent: Sendable, Equatable {
    let id: String
    let requestID: String?
    let reason: String
    let detail: String?
    let ts: Date?
}

nonisolated struct ChatResultEvent: Sendable, Equatable {
    let id: String
    let requestID: String?
    let ok: Bool
    let message: String?
    let ts: Date?
}

nonisolated struct ChatOffer: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable, Codable {
        case support
    }

    let id: String?
    let kind: Kind
    let text: String
}

nonisolated struct ChatDraft: Sendable, Equatable, Identifiable {
    let id: String
    let body: String
    let fields: [ChatDraftField]
    let diagnosticsIncluded: Bool
}

nonisolated struct ChatDraftField: Sendable, Equatable, Identifiable {
    let id: String
    let label: String
    let value: String
}

nonisolated enum DraftOutcome: Sendable, Equatable {
    case accepted(ChatSolMessage?)
    case cancelled(ChatSolMessage?)
    case failed(reason: String?)
    case transport
}
```

The normalized stream covers every known chat-tract kind:

- `owner_message` -> `.ownerMessage`
- `sol_message` -> `.solMessage`
- `talent_spawned` -> `.talentSpawned`
- `talent_finished` -> `.talentFinished`
- `talent_errored` -> `.talentErrored`
- `chat_error` -> `.chatError`
- `chat_queue_depth` -> `.queueDepth`
- `result` -> `.result`
- `/api/chat/session` hydrate -> `.snapshot`

The transport filters `tract == "chat"` before decoding normalized chat events. Malformed non-chat events are ignored. Malformed chat events are logged and dropped unless they are POST ack failures, which map to `.malformed`.

## SSE parser

Factor SSE framing into a pure unit:

```swift
nonisolated struct ServerSentEvent: Sendable, Equatable {
    let data: String
}

nonisolated struct ServerSentEventParser: Sendable {
    init()
    mutating func append(_ data: Data) -> [ServerSentEvent]
    mutating func finish() -> [ServerSentEvent]
}
```

Rules:

- Lines beginning with `:` are comments/heartbeats and never emit events.
- `data:` lines append one line of payload.
- A blank line emits one `ServerSentEvent` if accumulated data is non-empty.
- Multi-line `data:` events join with `\n`.
- Partial trailing data is retained until the next append or `finish()`.

`ConveyChatTransport.events()` sequence:

1. Wait until `localPortProvider()` returns a port.
2. Fetch `/api/chat/session`; emit `.snapshot`.
3. Open `GET /sse/events`.
4. For each SSE data event, JSON-decode, require `tract == "chat"`, normalize to `ChatEvent`.
5. On drop/error, reconnect with bounded backoff and repeat from step 2 so native state rehydrates before live events resume.
6. On `AsyncStream` termination, cancel the active request/task.

## ChatManager contract

Ship this initializer:

```swift
@MainActor
init(
    transport: any ChatTransporting,
    isReachable: @escaping @Sendable @MainActor () -> Bool = { true },
    localPortProvider: @escaping @Sendable @MainActor () -> Int? = { nil }
)
```

Production construction becomes:

```swift
let chatTransport = ConveyChatTransport(
    localPortProvider: {
        observerRegistration.activeLocalPort
    }
)
let chat = ChatManager(
    transport: chatTransport,
    isReachable: {
        tunnel.state.isConnected
    },
    localPortProvider: {
        observerRegistration.activeLocalPort
    }
)
```

`nil` local port is linked-offline for chat. It queues locally, starts the 3-second retry tick, and does not ask transport to POST.

### Manager state additions

Keep existing `messages`, `isSending`, `lastError`. Add:

```swift
var queueDepth: Int?
var pendingOffer: ChatOffer?
var pendingDraft: ChatDraft?
```

Update `ChatMessage` to make text mutable and attach turn metadata:

```swift
struct ChatMessage: Identifiable, Sendable, Equatable {
    enum Role: String, Sendable, Equatable {
        case user
        case assistant
    }

    enum Status: Sendable, Equatable {
        case sent
        case pending
        case failed
    }

    let id: UUID
    let role: Role
    var text: String
    let timestamp: Date
    var status: Status
    var provenance: AnswerProvenance?
    var requestID: String?
    var useID: String?
}

nonisolated struct ChatWorkingTrace: Sendable, Equatable {
    var activeLabels: [String]
    var completedLabels: [String]
    var erroredLabels: [String]
}
```

`ChatWorkingTrace` is exposed as manager-level transient `ChatManager.activeTrace` for the current in-flight turn only. It is not stored on `ChatMessage`; settled per-answer coverage lives on `AnswerProvenance.coverage`.

Labels are rendered verbatim. The manager never derives display labels from talent `name`.

## Invariant remap

| Lode 2 invariant | New owner | Exact Lode 3 behavior |
|---|---|---|
| Empty input is ignored | Manager preflight | Same: trim and return with no message, no transport call. |
| Unreachable send queues locally | Manager preflight | If `!isReachable()` or `localPortProvider() == nil`, append user `.pending`, clear stale error, start 3s retry tick, do not POST. |
| Reachability gates draining | Manager preflight + retry | `drainIfPossible()` checks no in-flight POST, first pending user, `isReachable()`, and non-nil port before `postMessage`. Retry tick keeps polling every 3s while pending. |
| Online direct send used to await full reply | POST ack + stream reducer | `send(_:)` returns after POST ack. Successful ack marks the head user `.sent` immediately, stamps `useID`, clears send error, sets the outstanding-turn marker, and sets `isSending = true`. It does not retry the accepted POST. One-turn-at-a-time draining is gated by the outstanding-turn marker while the async answer is still outstanding. |
| `.ok(non-empty)` marks head sent and inserts assistant | Stream reducer | `.solMessage` with non-empty stripped/markdown text inserts or updates the assistant bubble. If `requestedTarget == nil` and no active talents remain, clear the outstanding-turn marker, clear `isSending`, stop retry if no pending, then drain next queued local message. The user message status is unchanged because send success was already recorded by POST ack. |
| `.ok(empty)` fails | Stream reducer | Empty final `solMessage.text` with no offer/draft renders an assistant-side empty-reply error/retry affordance and does not insert an empty assistant bubble. The user message remains `.sent`; then the outstanding turn clears and draining may continue. |
| `.serverError(503)` keeps pending, stops immediate drain, schedules retry | POST ack | `.unavailable` keeps head `.pending`, clears error, schedules 3s retry, stops immediate drain. |
| Transport failure keeps pending, stops immediate drain, schedules retry | POST ack | `.transport` keeps head `.pending`, clears error, schedules 3s retry, stops immediate drain. |
| 429 queue full has no Lode 2 equivalent | POST ack | `.queueFull` keeps head `.pending`, updates `queueDepth`, clears `lastError`, shows the capacity line, schedules 3s retry, and stops immediate drain. |
| Decode failure fails | POST ack | `.malformed` marks head `.failed`, sets `chatErrorDecode`, continues to next pending. Malformed SSE chat events are dropped/logged because retrying the POST would duplicate accepted work. |
| `.serverError(500)` fails with server fallback | POST ack | `.serverError(status: 500, reason)` marks head `.failed`, uses reason or `chatErrorServer`, continues queue. |
| `.serverError(other)` fails with generic fallback | POST ack | `.serverError(other, reason)` marks head `.failed`, uses reason or `chatErrorGeneric`, continues queue. |
| Queue stops on keep-pending cases | POST ack | `.queueFull`, `.unavailable`, and `.transport` all stop immediate drain and rely on 3s retry. Successful ack also stops immediate drain, but because the turn is accepted and awaiting SSE, not because it needs retry. |
| Queue continues after failed non-retry cases | POST ack + stream reducer | `.malformed` and non-503 server errors mark the send failed and call `drainIfPossible()` for the next local pending message. Stream empty-reply and newer `chat_error` are answer-side failures: they keep the user message `.sent`, clear the outstanding turn, and then draining may continue. |
| Retry task is cancelled when no pending | Manager reducer | Same. Stop retry when no local pending user messages remain. Keep only one retry task. |
| In-flight stale results are ignored | Manager reducer | Keep token-based guard for POST tasks. Event reducer dedupes by `id`, `requestID`, and `useID` so reconnect hydrate does not duplicate assistant bubbles. |
| Last error clears on accepted or keep-pending transient cases | POST ack + stream reducer | Ack success, 503, 429, transport, and final sol message clear `lastError`. Malformed/server/empty/chat_error set it. Queue-full additionally updates `queueDepth` for the capacity surface. |

### Stream reducer details

- `.snapshot`: updates `queueDepth`, active/completed trace, pending offer/draft, and latest sol message. If latest sol message already exists by `id`/`requestID`, update in place.
- `.ownerMessage`: attach server IDs to the matching optimistic local user message when possible; otherwise append a sent remote owner message.
- `.solMessage`: strip dead `sol://` links to label text, parse citations into sources, render text with `Text(markdown:)`, update or insert the assistant bubble, clear matching chat error, and evaluate turn-final detection.
- `.talentSpawned`: add `label` to manager-level `activeTrace.activeLabels`; show typing/working trace.
- `.talentFinished`: move `label` from active to completed; completed labels become settled `coverage`.
- `.talentErrored`: move `label` to errored; if a later `chat_error` arrives, show error/retry.
- `.chatError`: if newer than latest sol message by `ts` or stream order, render an assistant-side failed/error closer, clear typing, expose retry, and clear the outstanding turn. The user message remains `.sent`. Older chat errors are ignored for turn status.
- `.queueDepth`: update `queueDepth` and capacity line.
- `.result`: record completion for offer/draft actions only; clear pending offer/draft surfaces and do not synthesize answer text from `result.message`. Convey appends a following result `sol_message`; reduce that `sol_message` verbatim through the normal `.solMessage` path.

## Provenance model

Replace `AnswerProvenance` with:

```swift
nonisolated enum AnswerState: String, Sendable, Equatable, Codable {
    case answered
    case partial
    case failed
}

nonisolated struct AnswerProvenance: Sendable, Equatable {
    let state: AnswerState
    let sources: [ProvenanceSource]
    let coverage: [String]

    struct ProvenanceSource: Sendable, Equatable, Identifiable {
        let id: String
        let ref: String
        let label: String
        let url: URL?
    }

    var showsPill: Bool {
        !sources.isEmpty
    }
}
```

No confidence enum, no confidence label, no confidence assets, no unknown case.

### Coverage rendering

- Live working trace comes from active/completed/errored talent labels on the in-flight turn.
- Settled `coverage` comes from completed talent labels in the final answer provenance.
- Talent labels are verbatim sentence-case sol voice from the server. They are never lowercased and never mapped from `name`.
- If the server omits a display label, transport should leave the label empty and the manager should not invent one from `name`; this is the one material dependency on the convey contract.

State mapping:

- active talent exists: assistant side shows typing plus working trace.
- completed talent exists and final `sol_message` has arrived: settled answer shows `coverage`.
- talent errored and no newer final `sol_message`: error trace waits for `chat_error`.
- newer `chat_error`: error/retry state.

## Bubble, pill, offer, and draft UI

### Assistant bubble

`AssistantBubble` renders:

- `Text(markdown:)` for assistant text.
- Working trace above the answer while in flight.
- Settled coverage above final answer when `coverage` is non-empty.
- Source pill iff `!sources.isEmpty`.
- Honest-gap line only for `.partial`.
- Error closer for `.failed` and stream `chat_error`.

Honest-gap rules:

- `answered + sources`: answer + count pill.
- `answered + empty sources`: plain answer, no pill, no honest line.
- `partial`: dimmed answer plus honest line.
- `failed`: error closer/retry state.
- `chat_error`: error closer/retry state.

`sol://` handling:

- Inline markdown links whose URL scheme is `sol` are stripped to their label text before `Text(markdown:)`.
- The same citation becomes a `ProvenanceSource` with `ref` set to the `sol://` string and `url` set only if convey provides an openable URL.
- The pill/panel is the only open affordance.
- A source row with `url == nil` shows only the label; no disabled `"open"` button and no dead href.

### Pill and panel

- Pill face is count only: `"1 source"` / `"2 sources"`.
- Delete `ConfidenceChip`. Replace it with a neutral count capsule local to the chat/provenance UI.
- Neutral colors:
  - Capsule background: `Color(.tertiarySystemFill)`.
  - Capsule foreground and source-row dot: `Color.secondary`.
- Repoint `Color("Confidence/Low/Dot")` to `Color.secondary` before deleting `Sources/Assets.xcassets/Confidence/`.

### Offer and draft surfaces

`ChatView` owns composer-adjacent action surfaces:

- Capacity line above the composer when `queueDepth` is non-zero or queue-full is reported.
- Support-blue mode shift while a support offer or support draft is pending.
- Offer surface: assistant offer text plus two chips:
  - yes: submit `SourceVocabulary.chatOfferYes` through the normal `postMessage` path.
  - not now: `declineOffer()`.
- Draft review card: render payload fields/body verbatim, show confirm/cancel. Confirm calls `confirmDraft(id:)`; cancel calls `cancelDraft(id:)`.
- Draft outcomes that include a `ChatSolMessage` are reduced as `.solMessage` and rendered verbatim. Outcomes without a message wait for stream/session hydration.

`AssistantBubble` owns answer/provenance/error rendering only. It can display the offer text as part of the assistant message, but offer buttons and draft cards live in `ChatView` so actions stay near the composer and do not duplicate across reconnect hydrates.

### SourceVocabulary changes

Remove:

- `chatSourceConfidenceHigh`
- `chatSourceConfidenceMedium`
- `chatSourceConfidenceLow`
- `chatSourcesPillA11yCollapsed(count:confidence:)`
- `chatSourcesPillA11yExpanded(count:confidence:)`

Keep or add:

- `chatSourceCount(_:)`
- `chatSourcesPillA11yCollapsed(count:)`
- `chatSourcesPillA11yExpanded(count:)`
- `chatPartialHonestLine`
- `chatAnswerFailedLine`
- `chatQueueCapacityLine(count:)`
- `chatOfferYes`
- `chatOfferNo`
- `chatSupportCapacityFrom`
- `chatSupportCapacityTo`
- `chatSupportCapacitySub`
- `chatDraftReviewTitle`
- `chatDraftConfirm`
- `chatDraftCancel`
- `chatDraftDiagnosticsIncluded`
- `chatRetryAnswer`

Runtime verbatim values are not vocabulary constants: assistant answer text, source labels, coverage/talent labels, offer body text, draft body/field labels, draft result text, and server-provided error detail.

## URL builder and HTTP client

Add `Sources/Chat/ConveyChatURL.swift`:

```swift
nonisolated enum ConveyChatURL {
    static func chatURL(localPort: Int) -> URL?
    static func sessionURL(localPort: Int) -> URL?
    static func eventsURL(localPort: Int) -> URL?
    static func offerDeclineURL(localPort: Int) -> URL?
    static func draftConfirmURL(localPort: Int, id: String) -> URL?
    static func draftCancelURL(localPort: Int, id: String) -> URL?
    static func url(localPort: Int, path: String, queryItems: [URLQueryItem] = []) -> URL?
}
```

`baseURL(localPort:)` must mirror `ConveyURL` exactly:

1. `--integration-test-live` + `LIVE_SERVER`
2. `--integration-test` + `MOCK_CONVEY_PORT`
3. `http://127.0.0.1:{localPort}`

Add `Sources/Chat/ConveyChatTransport.swift`:

```swift
nonisolated struct ConveyChatTransport: ChatTransporting, Sendable {
    init(
        localPortProvider: @escaping @Sendable @MainActor () -> Int?,
        session: URLSession = .shared
    )
}
```

HTTP style follows `EphemeralKeyFetcher`:

- `nonisolated struct`
- `URLSession.data(for:)` for request/ack endpoints
- `URLSession.bytes(for:)` or data task bytes for SSE
- `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`
- `200..<300` status range check
- decode error body before falling back to generic failure

## Files to change during implementation

Chat contract/state:

- `Sources/Chat/ChatTransporting.swift`
- `Sources/Chat/ChatManager.swift`
- `Sources/Chat/ChatMessage.swift`
- `Sources/Chat/AnswerProvenance.swift`
- add `Sources/Chat/ConveyChatTransport.swift`
- add `Sources/Chat/ConveyChatURL.swift`
- add `Sources/Chat/ServerSentEventParser.swift`
- delete `Sources/Chat/StubChatTransport.swift`

UI:

- `Sources/Chat/AssistantBubble.swift`
- `Sources/Chat/ChatView.swift`
- `Sources/Chat/ChatComposerView.swift` if retry/offer/draft actions need composer coordination
- `Sources/Chat/TypingIndicator.swift` only if working trace is integrated there
- `Sources/SourceVocabulary.swift`
- delete `Sources/Design/ConfidenceStyle.swift`
- delete `Sources/Assets.xcassets/Confidence/`

App wiring:

- `Sources/SolstoneSwiftApp.swift`

Tests:

- `Tests/ChatManagerTests.swift`
- `Tests/Mocks/ScriptedChatTransport.swift`
- `Tests/AnswerProvenanceTests.swift`
- `Tests/ConfidenceStyleTests.swift` delete or replace with neutral pill tests
- `Tests/SourceVocabularyTests.swift`
- `Tests/DynamicTypeSmokeTests.swift`
- add parser/transport tests for SSE and POST/session/offer/draft endpoints

Build/config:

- `project.yml` should not need dependency changes.
- Asset deletion should be enough because sources are folder-based.

## Test strategy

Parser tests:

- `: heartbeat` comments are skipped.
- single `data:` event emits once at blank line.
- multiple events in one append emit in order.
- multi-line data joins with `\n`.
- partial event across appends is retained.
- `finish()` flushes final event.

Transport URLProtocol tests:

- `POST /api/chat` 200 ack -> `.ack`.
- `POST /api/chat` 429 `chat_queue_full` -> `.queueFull`.
- `POST /api/chat` 503 `agent_unavailable` -> `.unavailable`.
- malformed 200 ack -> `.malformed`.
- URLProtocol failure -> `.transport`.
- `GET /api/chat/session` snapshot -> `.snapshot`.
- offer decline endpoint returns true only on 2xx.
- draft confirm/cancel endpoints map to `DraftOutcome`.

Manager tests:

- nil port queues pending and starts retry.
- ack success marks head sent immediately, sets outstanding-turn, and does not retry POST.
- final sol message inserts/updates assistant and clears outstanding-turn without changing user status.
- queue-full, unavailable, and transport keep pending and schedule 3s retry.
- malformed ack and server errors fail and continue queue.
- empty sol message renders assistant-side empty-reply error/retry and keeps user sent.
- chat_error newer than latest sol message renders assistant-side failure/retry and keeps user sent.
- result event records outcome only; following sol_message renders the visible result.
- talent labels flow active -> working trace, finished -> settled coverage, errored -> error trace.
- snapshot hydrate dedupes existing message by `id`/`requestID`.

Bubble tests:

- pill appears iff sources are non-empty.
- answered + empty sources renders plain answer, no honest line.
- partial renders dimmed/honest line.
- failed/chat_error renders error closer/retry.
- coverage labels preserve mixed case and punctuation, e.g. `"Reading your journal…"`.
- `sol://` markdown links render as label text, and source row open button appears only when `url != nil`.

Existing test rewrites:

- `AnswerProvenanceTests`: new state/sources/coverage semantics; no `.unknown`.
- `ChatManagerTests`: replace `ChatReply` scripts with POST result scripts plus event stream injection.
- `ScriptedChatTransport`: implement `postMessage`, `events`, offer/draft calls; expose an `AsyncStream.Continuation` so tests can push normalized events.
- `DynamicTypeSmokeTests`: remove confidence cases; add partial/failed/offer/draft/pill states.
- `SourceVocabularyTests`: remove confidence constants and confidence parameter expectations; add new vocabulary.
- `ConfidenceStyleTests`: delete with `ConfidenceStyle`, or replace with focused neutral capsule behavior if extracted.

## Implementation sequence

1. Add new model contracts: `ChatPostResult`, `ChatEvent`, draft/offer/talent structs, new `AnswerProvenance`.
2. Add pure SSE parser and tests.
3. Add `ConveyChatURL` and `ConveyChatTransport` with URLProtocol tests.
4. Rewrite `ScriptedChatTransport` for POST scripts + injected event stream.
5. Rewrite `ChatManager` around POST ack + stream reducer while preserving retry/drain invariants.
6. Rework `AssistantBubble` and `ChatView` for `Text(markdown:)`, neutral pill, working trace, offer/draft/capacity surfaces.
7. Remove confidence vocabulary, `ConfidenceStyle`, confidence assets, and stub transport.
8. Update app wiring in `SolstoneSwiftApp`.
9. Rewrite affected tests and run focused test targets, then `make ci`.

## Integration loose end

`make integration-test-push-chat` currently fails. I ran it on 2026-06-18 and it failed with:

- missing asserted log: `"chat stub presented"`
- actual router logs included `"routed to chat"` and `"chat presented"`

Recommendation: repoint the target to the stable presentation log:

- `PUSH_ASSERT=chat presented`

Do not change this during the design stage. It should be part of implementation or a small prerequisite cleanup commit.

## Risks and open questions

- Convey must send verbatim talent display labels. If it only sends `name`, native will not derive owner-visible labels from `name`; that would require a server contract fix.
- The exact `sol://` ref-to-open-URL mapping depends on convey. Native can safely strip inline links and show source labels now; open buttons require either explicit source URLs or a deterministic URL builder from ref.
- Successful POST ack means the user bubble becomes `.sent` immediately. Answer-side failures from the stream render assistant-side and do not change user-message send status.
- If `/api/chat/session` remains latest-message-only, native cannot reconstruct full historical transcript on cold launch. This design supports current-session/live correctness and reconnect hydration, not full history, unless convey expands the session contract.
