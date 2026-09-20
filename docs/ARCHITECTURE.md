# Architecture

The SwiftPM executable target is `HerdrOrb`. The application/display/repository
name is `herdrorb`; the bundle identifier is `io.github.andrewjedi.herdrorb`.

| File | Responsibility |
|---|---|
| main.swift | AppKit lifecycle, floating windows, menu bar, first-launch presentation |
| Installation.swift | Executable resolution, JSON status contract, typed health, shared process/SSH arguments, preferences migration, diagnostic redaction |
| HerdrClient.swift | API decoding, independent machine workers, selected-session state, sends, cache coordination and launch recovery |
| Transport.swift | Bounded/cancellable subprocesses, per-request Unix sockets, retained SSH tunnels and event subscriptions |
| ConnectionSetup.swift | Welcome/setup, per-device troubleshooting, custom paths and failed-launch actions |
| GeneralSettings.swift | Appearance, persistence, preview controls and project links |
| ConversationCache.swift | Actor-isolated private files, bounded retention and disabled-persistence behavior |
| SessionConversation.swift | Conversation/terminal switching and composer |
| TerminalPresentation.swift | Conservative reconstruction of terminal text and artifact detection |
| EmbeddedTerminal.swift | SwiftTerm attachment to the selected Herdr terminal |
| Artifacts.swift | Local/SSH file preview, bounded downloads, thumbnails and Quick Look |
| Demo.swift | Fictional in-memory transport and isolated preview launch modes |

## Data and control flow

UI actions go through the main-actor model. Each device owns an independent
transport and refresh worker. Local RPC uses Herdr's reported Unix socket;
remote RPC forwards it through SSH. Each JSON API request has its own socket
connection. Events trigger resynchronization, with periodic snapshots as a
fallback. Only the visible conversation is read continuously.

Normal executable resolution is shared by discovery and terminal attachment.
Remote commands invoke a POSIX shell with quoted positional arguments. Custom
paths do not silently fall back when broken. SSH targets cannot start with an
option or contain whitespace/control separators. Host-key checking is never
disabled. Protocol 22 is checked before returning a usable server socket.

Session identity includes the machine/profile and terminal/pane IDs. Sends
capture their destination; late replies cannot overwrite another session's
draft. Uncertain prompt mutations are never automatically retried. Launch
recovery reuses the failed terminal and checks whether an agent is already
present before an explicit retry.

## Persistence and lifecycle

The model controls persistence; the cache actor also enforces its enabled state,
cancels pending writes when disabled/cleared, and ignores disabled writes.
Migration preserves prototype preferences without overwriting newer values.
See PRIVACY.md for locations and retention. Quit flushes enabled cache writes
and shuts down this application's connections, not Herdr sessions.

## Validation boundaries

Unit tests import the executable module through SwiftPM. Existing native and
asynchronous interaction checks remain in scripts/check.sh. Real connections
are explicitly opt-in via scripts/check-live.sh. Demo and setup-preview modes
use separate defaults and temporary caches, with no real transport subprocesses.
CI does not exercise personal SSH connections or agent credentials.
