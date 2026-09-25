# Conversation architecture and long-chat review

Reviewed September 24, 2026 against the current working tree and installed Herdr protocol 22 schema. Existing uncommitted UI/performance work was preserved. This review distinguishes present behavior from the proposed structured integration.

## What happens today

1. `HerdrClient.swift` discovers Herdr panes and agent kinds. `MachineTransport` uses local Unix socket RPC; remote machines use a retained SSH socket-forwarding tunnel. Each RPC still opens a socket exchange; the SSH connection is retained. Status/lifecycle events are separate from output reads.
2. Only the selected, visible conversation polls `pane.read` with `source: visible`, text output, and ANSI stripping. Reads are serialized, with a 100 ms working or 500 ms idle pause after each request. Terminal mode and hidden panels suspend this loop. Protocol 22's advertised output-wait capability is not implemented by the tested Herdr 0.9.1 runtime.
3. `TerminalPresentation` removes recognized CLI chrome, heuristically merges snapshots, infers user/assistant boundaries from prompt markers, and separates Codex work details from the final answer. This is terminal-derived presentation, not a complete provider transcript. ANSI stripping also means original Markdown syntax/links can already be lost before the renderer sees the text.
4. Cleanup, merging, and message parsing run in a detached task. Parse versions reject superseded results. Unchanged cleaned output reuses prior messages; stable identities allow unchanged message parts and artifacts to be reused. Raw output is not published to the whole view.
5. `ConversationRows` uses AppKit scrolling and individual SwiftUI hosting controllers. Heights are cached by width/content. Offscreen rows are hidden, but their controllers remain allocated. Updates are coalesced while a scroll gesture is active. The first window contains 40 messages; showing earlier messages grows the loaded window.
6. Markdown renders headings, lists, code, and inline formatting. Codex activity disclosure reduces visual clutter; terminal mode remains necessary for approvals, menus, and exact output. This is not a full Markdown implementation: tables and richer block structures need explicit support, and one huge message can still have a costly layout.
7. Composer submission calls `agent.prompt` into the existing CLI. Slash commands and approvals use the actual terminal. Pending-message removal currently relies on text appearing in a snapshot, not a provider message acknowledgement. An ambiguous failure restores the draft and asks the user to check before resending.
8. `EmbeddedTerminal` runs `herdr terminal attach` inside SwiftTerm's PTY (or SSH with a PTY remotely). Detaching terminates the attach client, not the underlying agent. Input buffering protects typing during attachment; terminal protocol replies bypass the typing buffer.
9. `ConversationCache` writes per-session JSON on an actor, debounces writes for 400 ms, limits raw/history text to 250,000 characters each, and retains 40 disk/cache entries. These limits are display retention, not model context limits. The separate `BubbleModel.states` dictionary currently retains visited sessions without an equivalent LRU bound.

## Changes made in this review

- Added a compact context ring/percentage in the upper-right conversation toolbar. The message bar is unchanged. Clicking the meter explains the provider reading and how to obtain a missing footer.
- Codex's explicitly labeled context-left percentage is inverted into percent used. Claude accepts explicitly context-labeled percentage footer formats, including `Context: 25% used` and `25% context`. Neither provider uses message length, cumulative billing, account quotas, or a hard-coded model window.
- Readings come only from the current visible snapshot, after an empty provider prompt, outside fenced code. Missing/invalid/unsupported footers produce an unavailable state. Cached, settings-busy, resumed, and terminal-mode views do not present an old reading as live. No CLI settings are rewritten and no slash command is injected by the meter.
- Replaced the suffix-overlap search with a linear KMP line scan. The old algorithm repeatedly allocated and compared candidate suffix arrays and could take quadratic work on repeated terminal output. Existing evolving-tail and explicit discontinuity fallback behavior is preserved.
- Corrected pending-delivery labels to name the actual provider rather than always saying Codex.

The footer meter is an intentionally limited compatibility layer. It cannot promise a reading for every theme, customized status line, actively typed prompt, or CLI release. In particular, Claude does not expose a standard percentage footer unless configured to do so. An auto-compaction warning's remaining budget is not treated as the full model window. A structured telemetry channel is required for always-available readings.

## Highest-priority remaining issues

| Priority | Finding and consequence | Recommended change |
|---|---|---|
| P1 | Visible snapshots can skip output between polls and while the app is hidden. Overlap cannot reconstruct missing output. Resizing/reflow and repeated prompts can confuse identity. | Add structured provider events with stable session/turn/item IDs and replay cursors. Keep terminal capture as an explicitly approximate fallback. |
| P1 | The 250k-character tail can begin inside a message or code fence; trimming may change inferred identities and scroll anchors. There is no full archive behind “earlier messages.” | Persist structured messages incrementally, page by stable ID, evict at complete message boundaries, and expose retention/truncation in the UI. |
| P1 | Pending delivery is acknowledged by a substring match. Repeated prompts or an assistant quoting a prompt can acknowledge the wrong submission. | Distinguish transport acceptance from provider turn acknowledgement using request IDs. Never automatically resend an ambiguous prompt. |
| P2 | 40-message initial pagination is not full virtualization. Loading old pages retains and measures their controllers; visited sessions have no model-state eviction. | Add an LRU for inactive session state and a bounded row-controller pool. Retain lightweight message metadata and height indexes; pin the focused/selected row. |
| P2 | Every changed snapshot still scans the bounded history; a large final message still reparses/reflows as one unit. | Normalize events once, append deltas only to the active item, cache completed Markdown blocks, and coalesce UI publishing to a measured frame budget. |
| P2 | Context via footer is unavailable when chrome is hidden, and formats can change. | Bridge provider usage with explicit source, session identity, model, capacity, observation time, and stale/unavailable states. |
| P2 | Repeated image-display instructions are appended to every Codex prompt. This consumes context and enters the terminal-derived history. | Put this contract in a session-level instruction when a structured session API supports it; keep fallback behavior explicit. |

## Target provider integration

Use one normalized event store between provider adapters and UI. Suggested events: session started/reset, message started/delta/completed, tool started/completed, approval requested/resolved, usage updated, compacted, and disconnected. Key every event by machine/profile/provider-session ID, with ordered sequence and replay position. Apply events idempotently and recover gaps before acknowledging a complete transcript. Do not identify a session merely by working directory; multiple agents can share it.

For Codex, the official app-server interface provides item lifecycle events, message phases, token-usage updates, and compaction items. New structured sessions can use this API. Do not assume a separate app-server process can transparently attach to an already-running arbitrary CLI or safely resume the same thread with two writers. Existing terminal sessions need an explicit migration/ownership policy. [Codex app-server documentation](https://developers.openai.com/codex/app-server).

For Claude, the official status-line command receives session-scoped JSON. Use `context_window.used_percentage` directly and preserve null as unknown. If deriving it, use current input plus cache creation plus cache read divided by the reported context capacity; do not include output tokens in that percentage. A bridge should preserve the user's existing status-line command and emit telemetry keyed by session ID, on the machine running Claude. Do not silently replace their configuration. This telemetry adapter is proposed, not installed by this change. [Claude status-line documentation](https://code.claude.com/docs/en/statusline).

An 80% UI accent is a heads-up, not a claim about a provider's compaction threshold. Compaction can lower usage while the visible chat history remains long. Start a new chat for a different task; for continuing work, compact/summarize through the provider rather than discarding the task solely because the meter is high. Codex exposes context/footer settings and compaction through its CLI commands. [Codex command documentation](https://developers.openai.com/codex/cli/slash-commands).

## Validation and performance observations

Local debug measurements from the existing performance fixtures (synthetic content, one run; not release benchmarks or a real CLI end-to-end guarantee):

| Fixture | Observed time |
|---|---:|
| Parse 166,689 characters / 200 messages | 36.7 ms |
| Reparse with unchanged-message reuse | 8.3 ms |
| Lay out all 200 messages | 818.8 ms |
| Lay out recent 40-message window | 176.5 ms |
| Stream update in 200-message fixture, median / worst | 7.4 / 9.2 ms |
| 160-item single Markdown message layout | 67.7 ms |
| Whole-transcript scroll CPU, median / p95 | 6.1 / 6.8 ms |
| Separate-row scroll CPU, median / p95 | 3.1 / 3.6 ms |

The numbers support keeping pagination and row caching. They also show why a large initial layout or single huge message can still hitch. CPU-frame timings do not establish GPU smoothness or a sustained frame rate.

New regression coverage checks percent direction, zero, decimal values, missing data, unrelated quotas, invalid percentages, fenced examples, compaction decreases, and repeated-line/evolving-tail history merges. Full validation results are reported with the change. A live two-provider lifecycle pass across exact installed CLI versions, remote reconnection, narrow widths, and multi-hour sessions remains necessary before claiming complete provider compatibility.

Validation completed: `swift test` ran 54 tests with zero failures and one environment-dependent dictation skip; `scripts/check.sh` passed all interaction/regression checks. After the final parser/provider-label edits, targeted context/composer tests passed (9 tests, the same skip). `swift build` and `git diff --check` passed. The production conversation view was rendered in isolated demo mode and inspected at `output/context-review/01-conversation.png`; the sample 28% meter fits beside search in the upper-right toolbar. The screenshot uses fictional telemetry, not a live account reading. No installed app was replaced or live CLI configuration modified.
