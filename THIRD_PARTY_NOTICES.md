# Third-party notices

herdrorb's original code and documentation are MIT licensed; see LICENSE.

## SwiftTerm 1.20.0

https://github.com/migueldeicaza/SwiftTerm

MIT licensed. Copyright holders include Miguel de Icaza, the xterm.js authors,
SourceLair Private Company, and Christopher Jeffrey. The complete upstream
copyright and license text is copied into every application bundle as
Contents/Resources/SwiftTerm-LICENSE. Do not remove that notice.

Swift Package Manager also resolves Apple's swift-argument-parser (Apache-2.0
with Runtime Library Exception) for SwiftTerm's auxiliary targets. herdrorb
links the SwiftTerm library product, not the termcast executable. Keep upstream
notices when redistributing dependency source or additional products.

## Herdr

https://github.com/herdrdev/herdr

Herdr is a separately installed application, licensed by its authors under
Apache-2.0. herdrorb communicates with the installed CLI and socket API; no Herdr
binary or source code is bundled. Herdr's name identifies the software this
independent companion supports; no endorsement or affiliation is implied.

## Artwork and sound

ObservatoryBackground.png is supplied by the project owner, who confirmed
permission to redistribute it with this open-source project on 2026-09-20.
It is included under the project MIT license. The orb shader, synthesized hover
sound, and procedural app icon (scripts/make-icon.swift) are project source
assets under the same license. SF Symbols are provided by macOS at runtime.
