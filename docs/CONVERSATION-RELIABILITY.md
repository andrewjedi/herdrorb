# Conversation reliability

This is the implementation follow-up to the September 24 conversation review.

## Seven fixes

| Review issue | Implemented behavior |
|---|---|
| P1: terminal snapshots miss or duplicate messages | Herdr's `agent_session` identity selects the exact Codex/Claude JSONL transcript. A reader imports complete records from a durable byte checkpoint. It catches up after the app is hidden or restarted. Replayed message IDs update existing rows. Terminal snapshots are a labeled fallback, never represented as a complete transcript. |
| P1: retained history cuts through messages | An indexed SQLite archive stores complete message objects independently of raw terminal snapshots. Message writes and the input checkpoint commit in one transaction. Paging/search query the archive; the UI holds a page, not a character slice. Legacy terminal retention trims only at message boundaries. |
| P1: repeated text falsely confirms delivery | Terminal substring acknowledgements are removed. Each local send ID receives only its own RPC completion. The receipt explicitly says the terminal accepted the send and that agent receipt is unconfirmed. Ambiguous failures are not retried. Receipts can be dismissed; eight accepted receipts are retained. |
| P2: memory grows with visited chats/history | The UI loads pages of up to 40 messages / 2 MB (allowing one complete oversized message), keeps four sessions' heavy history, and releases inactive history after saving it. Drafts, unread state, and unresolved sends survive. A bounded pool of 24 row hosts retains recent rows; visible/focused rows are protected. |
| P2: streaming repeatedly reparses history and huge replies hitch | Structured reads process appended records only. Unchanged files do not reload message pages. Completed Markdown parses use an 8 MB/256-entry cache. Replies longer than 12,000 characters use an excerpt and a full-text window rather than laying out the entire reply in chat. The full text is preserved. |
| P2: context depends on terminal footer | Codex uses latest request usage and reported capacity from its session record, with its baseline-adjusted percentage. Claude uses official status-line JSON, bound to session ID, including cache input tokens. Capacity is never inferred from a model name. Compaction clears older readings; unavailable data stays unknown. The popover identifies the source and reporting time. |
| P2: repeated image instructions consume context | The image-display contract is appended only to the first successful Codex send in a session. Its flag survives cache reload and memory eviction. Follow-ups contain the user's text without another instruction block. A newly identified session has its own flag. |

## Connecting existing and new sessions

The app continues to interact with the same CLI through Herdr. It does not launch a second agent to impersonate or take over the running session.

- **Codex:** Connect history installs Herdr's Codex session hook. For an idle existing session, it requests `/status` through the guarded settings bridge and reports the returned session UUID to Herdr. If Codex is working/blocked, connect again when idle, or resume the session in Terminal. A session without a verified identity remains in approximate terminal mode.
- **Claude:** Connect history/context installs a small helper and updates the current project's `.claude/settings.local.json`. The helper chains the effective existing status-line command with its original stdin, preserves other settings and padding, and backs up the previous local settings file once. Claude's hot-reloaded status line reports its session to Herdr and writes only session/model/context telemetry. Invalid settings are left untouched and surfaced as an error.
- **New sessions:** Real Herdr launches prepare the integration first. Demo sessions and test transports do not install it. If setup fails, the recoverable launch error is visible instead of silently pretending full history is connected.
- **Remote machines:** The same helper runs on the machine owning the CLI. A retained SSH/Python process serves bounded requests; no new SSH/Python process is spawned per poll. Python 3 is required, as it is for Herdr's provider hooks. Transport failures keep the last archive visible and mark it disconnected. The helper pool is bounded to three remote profiles.

After the CLI reports its identity, the app keeps provider sessions separate even when the same terminal pane is reused. Drafts/receipts transfer when an existing, unidentified CLI is first identified; they are not transferred to an unrelated replacement session.

## What the data means

Provider transcripts are an observation source, not an agent-control protocol. Persisted message records may arrive in chunks at the end of a model/tool step rather than character by character. The app preserves original Markdown and user/assistant roles; tool results, developer instructions, sidechain messages, and private thinking blocks are not displayed as chat messages.

Codex reads `last_token_usage.total_tokens` and `model_context_window`; cumulative lifetime tokens are ignored. Its percentage follows the current Codex baseline normalization (12,000 tokens). [Codex protocol source](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs).

Claude prefers `context_window.used_percentage`, or derives the same input-only percentage from input, cache-read, and cache-creation counts over the reported capacity. Null current usage (including just after compaction) is unknown, not zero. No account quota is substituted for context. [Claude status-line reference](https://code.claude.com/docs/en/statusline).

The adapter does not promise compatibility with an unknown future log format. Missing/ambiguous identity, missing files, corrupt records, or records over the 8 MB ingestion limit produce an explicit unavailable/error state. Incomplete final JSON/UTF-8 records are retried from their starting offset, never marked consumed. Output already missing from an old terminal snapshot cannot be recovered unless it exists in the provider's saved transcript.

## Storage and privacy

`messages.sqlite` lives in the app's private Application Support directory and contains complete visible message text plus read checkpoints. The file uses mode 0600 and the directory 0700. Queries and serialization run away from the main UI actor. There is no application-level encryption. The archive does not silently expire messages during pagination; clearing saved data removes it. Turning saving off removes the disk archive and uses an in-memory archive for the running app. This mode keeps at most 1,000 messages / 16 MB (allowing one complete oversized message), releases whole oldest messages, and visibly explains that older history may be released. Turn saving on to retain a full searchable archive.

Legacy JSON caches retain a small current page, draft, scroll state, and the per-session instruction flag. In-memory JSON cache entries are limited to four; legacy disk metadata retains the existing forty-session limit. These limits never determine model context usage.

Claude telemetry stores model, session ID, context counts, and observation time, not prompts or account details. Its telemetry files are limited to 100 sessions. Integration settings and their backup remain installed when saved conversation data is cleared. Full-message preview windows are limited to four.

## Validation

Regression coverage includes:

- Original role/Markdown preservation; exclusion of private reasoning, tool results, and sidechains.
- Split UTF-8/JSON records, corrupt lines, session mismatches, file truncation, appended reads, and durable restart/replay without duplicates.
- Complete 300 KB messages, archive search beyond the visible page, stable ordering on updates, paging to the beginning, and private archive removal.
- Heavy-session eviction/restoration with draft preservation; a bounded row-controller pool and cached height measurements.
- Codex last-request versus cumulative usage, correct capacity/percentage math, Claude cache input, null usage, and session isolation.
- Delivery receipts that cannot be acknowledged by old matching text, and follow-up sends without repeated image instructions.
- Python helper tests in isolated temporary homes/projects: chaining/preserving a status line, backup/idempotency, private minimal telemetry, retained worker requests, and refusing invalid settings.

Run `swift test`, `sh scripts/check.sh`, and `python3 scripts/tests/test_provider_bridge.py`. No paid model request is required by these tests. Synthetic tests are not a claim that every provider version, customized environment, or remote machine has had a live acceptance pass.

Validated September 24, 2026: the Swift suite ran 73 tests with one skipped and zero failures; interaction checks and all five Python helper tests passed. The release app built successfully, includes the provider helper, and passed signature verification. The synthetic visible-row scrolling measurement reported a 3.36 ms CPU-frame p95; this is not an end-to-end display latency measurement.
