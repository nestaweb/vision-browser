# Vision Browser

An open-source web browser for macOS, built with Swift and WebKit, with the password manager at its core.

Vision Browser starts from what made Arc pleasant to use and rethinks the rest:

- **The page comes first.** The web page fills the whole window. No permanent toolbar or URL bar; the domain appears briefly when you land on a new site.
- **A shelf and an overview instead of a sidebar.** Move the pointer to the bottom edge for your pinned and most recent tabs. Open the overview (`Cmd+@` by default, or pinch on the trackpad) to see every tab of the space, your spaces on a rail and your pinned tabs.
- **Spaces with isolated data.** Each space has its own cookies and storage (`WKWebsiteDataStore`), so two accounts on the same site live side by side.
- **A task list as the home page.** When a space has no open tab, its home page lists your tasks: projects and sub-projects, status, due date, subtasks and linked pages, stored on your Mac.
- **Bitwarden built in.** The extension runs through `WKWebExtension`, and each space can be linked to a Bitwarden folder.
- **One command bar** (`Cmd+T`) for URLs, search, open tabs, history, favorites, clipboard history and Bitwarden items.

The interface is in French. Vision Browser is an early preview: try it, but don't rely on it as your only browser yet.

## Installation

### Requirements

- macOS 26 or later.
- A Mac with Apple silicon or an Intel processor (the app is universal).

### 1. Download

Go to the [Releases page](https://github.com/nestaweb/vision-browser/releases) and download `Vision-Browser-<version>.dmg` from the latest release.

To check the file, compare its fingerprint with the SHA-256 shown next to the file on the release page:

```bash
shasum -a 256 ~/Downloads/Vision-Browser-*.dmg
```

### 2. Install

1. Double-click the `.dmg` file. A window opens with Vision Browser on the left and your Applications folder on the right.
2. Drag **Vision Browser** onto **Applications**.
3. Eject the disk image (the eject button next to "Vision Browser" in the Finder sidebar). You can then delete the `.dmg`.

### 3. First launch

Vision Browser is not yet signed with an Apple Developer ID or notarized by Apple, so macOS blocks it the first time you open it. This is expected. To allow it, once:

1. Open **Vision Browser** from Applications. macOS says it can't verify the app. Click **Done** (or **OK**).
2. Open **System Settings > Privacy & Security**.
3. Scroll down to the **Security** section. Next to the message about Vision Browser, click **Open Anyway**, then confirm with your password or Touch ID.
4. Open Vision Browser again and confirm with **Open Anyway**.

macOS remembers this choice; later launches open normally.

<details>
<summary>Alternative: allow it from the Terminal</summary>

This removes the "downloaded from the internet" flag that triggers the check. Only do it for a copy you downloaded from this repository's Releases page.

```bash
xattr -dr com.apple.quarantine "/Applications/Vision Browser.app"
```

</details>

### 4. Make it your default browser (optional)

Open **System Settings > Desktop & Dock**, find **Default web browser** and choose **Vision Browser**. Links opened from other apps then open in Vision Browser, in the space you assigned to that site, if any (menu **Espaces > Toujours ouvrir ce site dans cet espace**).

### 5. Bitwarden (optional)

Vision Browser works without Bitwarden. Two separate pieces add it, and you can install either or both:

| Piece | What it gives you |
|---|---|
| The Bitwarden **extension** | The usual Bitwarden popup and autofill inside web pages (`Cmd+Shift+B`). |
| The Bitwarden **CLI** (`bw`) | Your vault items in the `Cmd+T` command bar, filled into the page after Touch ID, never submitted automatically. |

**The extension.** It is not bundled with the app: an install script downloads the official Bitwarden Firefox build from Bitwarden's GitHub releases, checks its SHA-256 fingerprint and applies a small WebKit adaptation. The script needs the [GitHub CLI](https://cli.github.com), signed in:

```bash
brew install gh
```

```bash
gh auth login
```

```bash
git clone https://github.com/nestaweb/vision-browser.git
```

```bash
vision-browser/VisionBrowser/scripts/install-bitwarden.sh
```

The extension goes into `~/Library/Application Support/Vision Browser/Extensions/bitwarden`. Restart Vision Browser afterwards. Run the script again later to update the extension; your Bitwarden session is kept.

**The CLI.** Install it with [Homebrew](https://brew.sh), then sign in once in the Terminal (email, master password, two-step login):

```bash
brew install bitwarden-cli
```

If your account is on Bitwarden's European server, run this first:

```bash
bw config server https://vault.bitwarden.eu
```

```bash
bw login
```

Vision Browser finds `bw` in `/opt/homebrew/bin`, `/usr/local/bin` or `~/.npm-global/bin`. It never runs `bw serve`. Unlock your vault from Vision Browser when it asks; the session key stays in memory and is never written to disk.

### Updating

Download the new `.dmg` from the Releases page and drag Vision Browser onto Applications again, choosing **Replace**. Your spaces, tabs, history and tasks are kept.

### Uninstalling

Quit Vision Browser, move it from Applications to the Trash, then, to also remove its data (spaces, history, tasks, website data and settings):

```bash
rm -rf ~/Library/"Application Support/Vision Browser" ~/Library/WebKit/app.visionbrowser.browser ~/Library/HTTPStorages/app.visionbrowser.browser ~/Library/Caches/app.visionbrowser.browser
```

```bash
defaults delete app.visionbrowser.browser
```

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| New tab / command bar | `Cmd+T` |
| Edit the address | `Cmd+L` |
| Overview (adjustable in Settings > Raccourcis) | `Cmd+@` |
| Home page (tasks) | `Cmd+Shift+H` |
| Next / previous tab (most recent first) | `Ctrl+Tab` / `Ctrl+Shift+Tab` |
| Go to tab 1 to 9 | `Cmd+1` … `Cmd+9` |
| Close tab / reopen closed tab | `Cmd+W` / `Cmd+Shift+T` |
| Pin tab / add to favorites | `Cmd+D` / `Cmd+Shift+D` |
| Go to space 1 to 9 | `Ctrl+1` … `Ctrl+9` |
| Previous / next space | `Shift+←` / `Shift+→` |
| New space | `Cmd+Shift+N` |
| Open Bitwarden | `Cmd+Shift+B` |
| Settings | `Cmd+,` |

## Building from source

Requirements: macOS 26, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and the GitHub CLI for the Bitwarden script.

```bash
cd VisionBrowser
xcodegen generate
xcodebuild -project VisionBrowser.xcodeproj -scheme VisionBrowser -derivedDataPath build build
xcodebuild -project VisionBrowser.xcodeproj -scheme VisionBrowser -derivedDataPath build test
scripts/install-bitwarden.sh   # official Firefox build, SHA-256 checked, WebKit patch applied
open "build/Build/Products/Debug/Vision Browser.app"
```

To build the installer disk image (`dist/Vision Browser.dmg`, Release build; macOS may ask you to let the script control the Finder the first time):

```bash
VisionBrowser/scripts/make-dmg.sh
```

## License

[GPL-3.0](LICENSE), the same license as the Bitwarden clients it integrates with.

Vision Browser is an independent project. It is not affiliated with Bitwarden, Inc., Apple Inc. or The Browser Company.
