# Vision Browser

An open-source web browser for macOS, built with Swift and WebKit, with the password manager at its core.

Vision Browser starts from what made Arc pleasant to use and rethinks the rest:

- **The page comes first.** The web page fills the whole window. No permanent toolbar or URL bar; the domain appears briefly when you land on a new site.
- **A shelf and an overview instead of a sidebar.** Move the pointer to the bottom edge for your pinned and most recent tabs. Pull it up, or pinch on the trackpad, to see every tab of the space.
- **Spaces with isolated data.** Each space has its own cookies and storage (`WKWebsiteDataStore`), so two accounts on the same site live side by side.
- **Bitwarden built in.** The extension runs through `WKWebExtension`, and each space can be linked to a Bitwarden folder.
- **One command bar** (`Cmd+T`) for URLs, search, open tabs, history, favorites, clipboard history and Bitwarden items.

## Status

Early stage. Nothing here is ready for daily use yet.

| Step | State |
|---|---|
| Product plan and tab navigation design | Done: [PLAN.md](PLAN.md), [interactive mockup](maquette/vues-onglets.html) |
| Phase 0 prototype: isolated spaces + Bitwarden in WebKit | In progress: [prototypes/phase0](prototypes/phase0) |
| Phase 1: the real app (full-window pages, tabs, address bar, domain indicator, Bitwarden) | Done: [VisionBrowser](VisionBrowser) |

What phase 0 has verified so far:

- A cookie set in one space is not visible in another.
- The Bitwarden **Firefox** build (Manifest V2) loads and runs in `WKWebExtension`; the Chrome build (Manifest V3 service worker) does not start.
- Bitwarden detects the browser from the user agent, so extension pages must present a Firefox user agent.
- Passkeys (WebAuthn) require Apple's `com.apple.developer.web-browser.public-key-credential` entitlement.

## Building Vision Browser

Requirements: macOS 26, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen), GitHub CLI.

```bash
cd VisionBrowser
xcodegen generate
xcodebuild -project VisionBrowser.xcodeproj -scheme VisionBrowser -derivedDataPath build build
xcodebuild -project VisionBrowser.xcodeproj -scheme VisionBrowser -derivedDataPath build test
scripts/install-bitwarden.sh   # official Firefox build, SHA-256 checked, WebKit patch applied
open "build/Build/Products/Debug/Vision Browser.app"
```

Shortcuts: `Cmd+T` new tab, `Cmd+L` address, `Ctrl+Tab` next tab, `Cmd+W` close, `Cmd+Shift+T` reopen, `Cmd+Shift+B` Bitwarden, `Cmd+Shift+L` autofill.

## Building the phase 0 prototype

Requirements: macOS 26, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cd prototypes/phase0
xcodegen generate
xcodebuild -project VisionSpike.xcodeproj -scheme VisionSpike -derivedDataPath build build
```

Download `dist-firefox-<version>.zip` from the [Bitwarden releases](https://github.com/bitwarden/clients/releases) and unzip it into `prototypes/phase0/Extensions/bitwarden`, then apply the WebKit adaptation (inline menu protocol allowlist):

```bash
prototypes/phase0/scripts/patch-bitwarden.sh
```

```bash
# Automated checks: space isolation and extension loading
build/Build/Products/Debug/VisionSpike.app/Contents/MacOS/VisionSpike --selftest

# Open the Bitwarden popup headlessly and print its console
build/Build/Products/Debug/VisionSpike.app/Contents/MacOS/VisionSpike --diagnose-popup
```

## Language

Planning documents (`PLAN.md`, `tasks/`, `docs/`) are written in French. Code and this README are in English.

## License

[GPL-3.0](LICENSE), the same license as the Bitwarden clients it integrates with.

Vision Browser is an independent project. It is not affiliated with Bitwarden, Inc., Apple Inc. or The Browser Company.
