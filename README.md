# Vision Browser

An open-source web browser for macOS, built with Swift and WebKit, with the password manager at its core.

Vision Browser starts from what made Arc pleasant to use and rethinks the rest:

- **The page comes first.** The web page fills the whole window. No permanent toolbar or URL bar; the domain appears briefly when you land on a new site.
- **A shelf and an overview instead of a sidebar.** Move the pointer to the bottom edge for your pinned and most recent tabs. Pull it up, or pinch on the trackpad, to see every tab of the space.
- **Spaces with isolated data.** Each space has its own cookies and storage (`WKWebsiteDataStore`), so two accounts on the same site live side by side.
- **Bitwarden built in.** The extension runs through `WKWebExtension`, and each space can be linked to a Bitwarden folder.
- **One command bar** (`Cmd+T`) for URLs, search, open tabs, history, favorites, clipboard history and Bitwarden items.

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

Shortcuts: `Cmd+T` new tab, `Cmd+L` address, `Ctrl+Tab` next tab, `Cmd+W` close, `Cmd+Shift+T` reopen, `Cmd+Shift+D` favorite, `Cmd+Shift+B` Bitwarden, `Cmd+Shift+L` autofill.

## License

[GPL-3.0](LICENSE), the same license as the Bitwarden clients it integrates with.

Vision Browser is an independent project. It is not affiliated with Bitwarden, Inc., Apple Inc. or The Browser Company.
