# herdrorb design

Native SwiftUI product UI with AppKit windows, a SwiftTerm terminal, and a Metal desktop orb. Approved visual references live in `output/black-card-ui/`. The implementation retains the app's session and connection behavior.

## Surfaces and type

`OrbTheme` in `DesignSystem.swift` is the source of truth. The main working surface is opaque obsidian (#111216), the sidebar graphite (#18191E), body text platinum (#E8E9ED), secondary text #ADB0BC, and the interaction accent lavender (#B5A8E4). Decorative separators are #34363E. Interactive boundaries and focus use stronger contrast. SF Pro is the UI face; SF Mono is used for terminal output and code.

The default panel body is 900 × 613 macOS points, with 14 points reserved on each side for its popover pointer. The sidebar is 254 points. The main header is 70 points; the settings header is 58 points, with Back on the left as shown in the corrected privacy reference. Content insets are 24 points. The minimum window is 700 × 460 points. Forms and settings scroll at smaller sizes while their important actions remain reachable.

Panel corners are 20 points, sheet corners 16, and controls generally 8. Standard buttons and fields are 36 points tall; secondary compact buttons are 28. Controls retain accessible labels, native keyboard behavior, hover feedback, and distinguishable selected/disabled states. Orb switches provide native Toggle accessibility semantics.

## Artwork

`ObservatorySidebar.png` supplies atmosphere only behind navigation. A dark veil keeps it subordinate to the session hierarchy. `OrbAtlas.png` supplies the three approved nebula materials. The Metal renderer samples each atlas cell, subtly moves its interior wisps, and brightens on hover. It pauses when hidden and respects Reduce Motion. A procedural fallback remains available if the artwork cannot load.

The atlas was generated from the approved orb settings concept with the built-in image-generation tool. It contains artwork only; interface text and controls are rendered natively. Exact generation model identity is not exposed by the tool. The generated source is preserved in the user's generated-images directory.

## Repeatable visual review

Run `scripts/render-previews.sh` to capture the production SwiftUI views with fictional data, isolated preferences, and no subprocess or terminal attachment. Add `--screen 01-conversation` to target one screen, or `--preview-size 700x460` to inspect the minimum panel. Screens 12 and 13 are specimen compositions; they must not be mistaken for actual application navigation screens or complete verification of native Quick Look chrome.

Snapshots use the production Metal shader at a fixed time. AppKit bitmap caching does not faithfully capture every layer-backed native view, so terminal and Quick Look appearance also require inspection in the running demo build. Image dimensions, rasterized glyphs, and OS-owned chrome are not equivalent to cross-platform pixel identity.

## Artifact documents

Markdown files now render their actual contents in a native SwiftUI document view, using the shared Markdown renderer with document typography. Loading happens off the main thread and is capped at 512 KB. Invalid UTF-8, larger files, and other file types retain native Quick Look. The artifact window still owns its real macOS title bar; the file card remains a separate conversation component.

The review build can open a real fictional Markdown file with `--demo --preview-artifact`. This path never reads a user document or connects to a remote machine.

The comparison viewer is `output/implementation-review/compare.html`, with side-by-side and opacity-overlay modes. It normalizes image width, not OS font rasterization or generated chrome.

For native verification, launch the isolated demo with `--panel-only` to hide its orb and `--preview-size 700x460` to exercise minimum dimensions. Preview processes have separate preference suites and clean them up on normal termination, so rendering screenshots cannot change another demo's UI state.

## Conversation activity

Codex conversations present one collapsed activity disclosure per reply, labelled
“Thinking…” during work and “Worked for…” when the terminal provides a duration.
Intermediate commentary, tool calls, and completed approval notices remain
searchable and expandable. Search reveals matching activity. The final answer
owns its artifact cards, so temporary files from commands do not clutter the
conversation. Pending approvals still use the existing terminal handoff.

This follows the separation of compact status and expanded history in Codex's
[public status renderer](https://github.com/openai/codex/blob/main/codex-rs/tui/src/status_indicator_widget.rs)
and [message history](https://github.com/openai/codex/blob/main/codex-rs/tui/src/history_cell/messages.rs).
It is a presentation of terminal snapshots, not access to structured reasoning;
unrecognized idle prose is preserved. No transcript or cache data is discarded.

The conversation uses SF Pro at 15 points with 13-point activity labels, neutral
raised user bubbles, ordinary list bullets, and the existing lavender action
accent. Short conversations align to the top of the viewport. The activity
indicator respects Reduce Motion. Preview screens 14 and 15 cover thinking and
approval states; screen 01 covers the completed, collapsed reply.
