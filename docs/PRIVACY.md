# Privacy and uninstalling

herdrorb has no account backend, telemetry uploader, or automatic diagnostic
submission. It communicates with local Herdr over a Unix socket and remote
Herdr through the user's SSH configuration. Clicking documentation links opens
a website in the default browser. Herdr and agent CLIs have their own network
behavior, terms, and account requirements.

## Data stored on this Mac

- `~/Library/Application Support/herdrorb/`: cached machine/session inventory,
  conversation text/history, drafts, and reading state. Session files use private
  0600 permissions; directories use 0700. Data is JSON, not application-encrypted.
- Up to 40 cached sessions, with 250,000 characters each of live output and
  reconstructed history. Drafts are stored along with their session.
- `~/Library/Caches/herdrorb/Artifacts/`: downloaded remote previews, currently
  up to 20 downloads. Remote files are limited to 15 MB each.
- Preferences in the `io.github.andrewjedi.herdrorb` macOS defaults domain:
  appearance, last selection, folder defaults, executable overrides, and setup
  state. These can include personal local paths and machine-profile identifiers.

Settings lets you turn off conversation saving, clear saved conversations,
clear downloaded previews, and turn off automatic image loading. Turning saving
off also removes previously saved cache files. In-memory conversations and
unsent drafts remain usable until quit. Clearing saved conversations while
saving remains enabled is not a permanent opt-out: new activity can save data
again. Live terminal sessions are unaffected.

Remote image paths printed by an agent may download automatically over SSH.
Other file previews require a click. Images are downsampled for display; files
are previewed, not executed as commands. Paths are not restricted to the project
directory. Disable automatic previews if you want to choose every image yourself.
Clearing downloads doesn't close already-open preview windows or undo OS-level
Quick Look caching.

## Voice dictation

The microphone starts only after clicking the dictation button and granting macOS
Microphone and Speech Recognition permission. Stop, Cancel, closing the panel,
or changing conversations releases it. herdrorb does not save audio files.
Recognition uses Apple's on-device speech model when available for the current
language; otherwise audio is processed by Apple's speech service. Recognized text
becomes an editable draft and follows the conversation-saving preference above.
Nothing is sent to the agent until you send the message.

## Diagnostics

Settings → Copy diagnostics copies version, OS, architecture, generic connection
states, and numeric Herdr versions. It omits machine names, paths, SSH targets,
conversation content and raw error messages. Connection-error text shown inside
the app can contain personal details from SSH; inspect screenshots before sharing.
Unified logs contain operation timings and generic cache failure messages.

## Rename migration

On first normal launch, selected preferences from `local.andrew.HerdrBubble` are
copied without overwriting newer settings. Old `HerdrBubble` application-support
and cache directories move to `herdrorb` if the new location doesn't exist.
Quit the prototype before launching herdrorb. If migration cannot finish, original
files remain intact; existing destination directories are never overwritten.
Demo/setup previews use separate preferences and do not migrate personal data.

## Uninstall

Quit herdrorb and remove its application bundle. Running Herdr sessions are not
closed. To remove its retained data, clear caches in Settings first, or remove
the `herdrorb` directories listed above after quitting. Remove the defaults
domain with `defaults delete io.github.andrewjedi.herdrorb` if desired.

If you used the prototype, its old preference domain and any unmigrated
`HerdrBubble` directories may still exist. Remove them separately only if you
no longer want that data. Do not remove Herdr's configuration or SSH keys as
part of uninstalling herdrorb.
