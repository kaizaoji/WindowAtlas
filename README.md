<p align="center">
  <img src="branding/png/app-icon-256.png" width="128" height="128" alt="WindowAtlas app icon: stacked windows with a highlighted thumbnail inside a focus frame">
</p>

<h1 align="center">WindowAtlas</h1>

<p align="center"><b>A macOS window workspace built for parallel AI coding.</b><br>Run a dozen Claude Code and Codex sessions, terminals and browsers at once, and still find and jump to the one you need in a glance.</p>

<p align="center">
  <a href="https://github.com/zerotoonex/WindowAtlas/releases/latest"><img alt="Download" src="https://img.shields.io/github/v/release/zerotoonex/WindowAtlas?label=download&color=4f8ef7"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-arm64-555">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-3dd68c"></a>
  <a href="https://windowatlas.kaizaoji.com"><img alt="Website" src="https://img.shields.io/badge/website-windowatlas.kaizaoji.com-4f8ef7"></a>
</p>

<!-- README-I18N:START -->
**English** | [简体中文](README.zh-CN.md)
<!-- README-I18N:END -->

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/board-dark.png">
  <img alt="WindowAtlas board: Claude Code, Codex terminals and browser windows as large thumbnails" src="docs/screenshots/board-light.png">
</picture>

## Why WindowAtlas?

AI coding tools move fast, and so has the way we work: one person now runs several Claude Code and Codex agents in parallel across projects, next to dev servers, test runs, browsers, docs and Finder. The windows pile up, and so do the problems:

- **Finding a window is slow.** ⌘Tab switches apps, not windows; with a dozen terminals you are guessing. Mission Control disappears the moment you let go.
- **Switching to the wrong one is easy.** Terminal titles all look alike, so it is easy to send a prompt to the wrong project or interrupt a running task.
- **Progress is invisible.** Is that background agent still working, waiting for your approval, or done? You have to click through to find out.

WindowAtlas is built for this way of working. It lays out every window, grouped by app, as resizable live thumbnails in an always-available workspace. **Recognize a window by what is in it, double-click, and you are back in the real window** — running sessions are never interrupted.

## Made for AI coding

- **Recognize every session at a glance.** Terminals, iTerm2 and browser windows get live thumbnails, refreshed every 6 seconds — find windows by content, not by title.
- **Terminal task status (optional).** See whether a command or AI session in Terminal or iTerm2 is running, has recent output, or how long it has been idle — even in the background. Filter to windows with tasks or sort tasks first. Only session IDs, TTYs and process metadata are read; **never terminal contents, and no commands are run.**
- **Arrange things your way.** Drag thumbnails to reorder; Shift- or ⌥-select several windows to drag them together or move them to the top or bottom, so the sessions you are driving stay up front. Each section remembers its own order.
- **⌘K command library.** Keep your favorite Codex and Claude Code commands (like `/plan` and `/review`) with purpose and examples; search and copy in a keystroke.
- **Project notes.** Markdown notes for prompts, context and lessons learned, with nested folders, one-click code copying, images and backups to multiple locations.

## All features

- **Thumbnail boards by app** — all windows, favorites, terminals, browsers and each app; grid, list, or list with a large preview; every app remembers its own layout, size and sort order.
- **Keyboard navigation** — click to select, double-click or Return to open; arrow keys move the selection with automatic scrolling; Home/End and Esc.
- **Always-on sidebar** — a narrow thumbnail sidebar that follows you across Spaces and keeps working when the main board is closed.
- **Browser tabs (optional)** — read every tab in Chrome, Edge and Safari, per browser or combined under All Windows; search, switch or close; the current tab shows a live preview.
- **Multiple desktops and displays** — windows on other desktops (Spaces) are listed and one click takes you there; closed-but-lingering window surfaces are hidden automatically.
- **Placement and closing** — right-click for a 3×3 grid, halves, center, fill or restore across displays; hover a thumbnail to close it, with confirmation.
- Light, dark and system appearance; English and Simplified Chinese.

## Screenshots

| Light | Dark |
|---|---|
| ![Board · light](docs/screenshots/board-light.png) | ![Board · dark](docs/screenshots/board-dark.png) |
| ![Command library · light](docs/screenshots/commands-light.png) | ![Command library · dark](docs/screenshots/commands-dark.png) |

## Requirements

1. macOS 14 or later.
2. A Mac with Apple silicon (M-series). Intel Macs are not supported yet.

## Install

### Option 1: one line in Terminal (recommended)

Open Terminal, paste and press Return:

```sh
curl -fsSL https://github.com/zerotoonex/WindowAtlas/releases/latest/download/install.sh | sh
```

The script checks for Apple silicon and macOS 14+, downloads the latest release, **verifies its SHA-256** and **that the app is signed with the official certificate**, installs it into Applications (an older copy is moved to the Trash), then opens WindowAtlas. No admin rights needed — [read the script](scripts/install.sh) first if you like.

- A specific version: `curl -fsSL …/install.sh | WINDOWATLAS_VERSION=0.9.2 sh`
- Into your home folder: `curl -fsSL …/install.sh | WINDOWATLAS_INSTALL_DIR="$HOME/Applications" sh`
- Quit WindowAtlas first if it is running.

> Why no security prompt? macOS runs Gatekeeper only on files carrying the quarantine flag that browsers add; files downloaded with `curl` don't have it. The app is still **not notarized by Apple** — which is exactly why the script checks the hash and signature.

### Option 2: download the DMG

1. Download `WindowAtlas-<version>-apple-silicon.dmg` from [Releases](https://github.com/zerotoonex/WindowAtlas/releases/latest) and, optionally, verify it against the published SHA-256:

   ```sh
   shasum -a 256 ~/Downloads/WindowAtlas-<version>-apple-silicon.dmg
   ```

2. Open the DMG, drag **WindowAtlas** into **Applications**, then eject the DMG.
3. **Expect a security prompt on first launch.** WindowAtlas is an independent open-source app and is not notarized by Apple yet (that requires a paid developer account). The first time you open it, macOS says *“Apple could not verify ‘WindowAtlas’ is free of malware…”* with only **Done** and **Move to Trash**:
   1. Click **Done** (not Move to Trash).
   2. Open **System Settings → Privacy & Security** and scroll down to **Security**.
   3. Next to “WindowAtlas was blocked”, click **Open Anyway**, enter your password, then click **Open**.

   You only do this once per version. Please don't disable Gatekeeper. If macOS says the app is damaged, download it again and check the SHA-256.

The full guide — permissions, updating, backups, moving to a new Mac and uninstalling — is in [docs/INSTALL.md](docs/INSTALL.md) (Chinese, with an English quick guide at the end).

## First-time setup

WindowAtlas walks you through two system permissions on first launch:

| Permission | Why |
|---|---|
| Screen Recording | Shows thumbnails of your windows. Quit and reopen WindowAtlas after enabling it. |
| Accessibility | Brings the window you click to the front, and places, minimizes or closes windows. |
| Automation (optional) | Reads Chrome, Edge and Safari tabs and Terminal/iTerm2 session status when you turn those features on. |

If a switch is on but WindowAtlas still says it is not enabled, remove WindowAtlas from the list with “−” and add it again with “+”.

## Privacy and trust

- No account, no server, no analytics, no ads, no crash reporting, no auto-updater. The app makes no network requests of its own.
- Window previews are processed in memory and never written to disk or uploaded.
- Notes and commands stay in `~/Library/Application Support/WindowAtlas/`. Backups are written only to folders you choose; notes marked “Sensitive · No backup” are excluded.
- Read the full [privacy statement](docs/PRIVACY.md).

## Update and uninstall

- **Update:** quit WindowAtlas, replace it in Applications with the new version, and open it. Releases are signed with the same certificate, so your permissions normally carry over; if macOS asks again, re-enable them.
- **Uninstall:** move WindowAtlas to the Trash. To remove data, delete `~/Library/Application Support/WindowAtlas/` and `~/Library/Preferences/com.kaizaoji.windowatlas.plist`, and optionally run `tccutil reset ScreenCapture com.kaizaoji.windowatlas` (likewise for `Accessibility` and `AppleEvents`).

## Build from source

Requires the Xcode command-line tools (Swift 5.9 or later). There are no third-party dependencies.

```sh
swift test                 # run the test suite
zsh scripts/build.sh       # build dist/WindowAtlas.app (ad hoc signed)
zsh scripts/release.sh     # build, sign and package dist/WindowAtlas-<version>-apple-silicon.dmg
```

- `SIGN_IDENTITY="<identity>"` selects the signing identity. Official releases are signed with the maintainer's self-signed “WindowAtlas Release” certificate so permissions survive updates; ad hoc builds require re-granting permissions after every rebuild.
- With a Developer ID certificate, set `SIGN_IDENTITY="Developer ID Application: …"` and `NOTARY_PROFILE=<profile saved with xcrun notarytool store-credentials>` to sign with the hardened runtime and notarize.
- Brand assets live in `branding/` (SVG sources); regenerate everything with `zsh branding/tools/build.sh`.

### Project layout

| Path | Contents |
|---|---|
| `Sources/WindowAtlas/` | The app (SwiftUI + AppKit, ScreenCaptureKit, Accessibility) |
| `Tests/WindowAtlasTests/` | Unit and integration tests |
| `scripts/` | Build, release and test-fixture scripts |
| `branding/` | Logo, icons and usage guidelines |
| `docs/` | Install guide and privacy statement |

## Feedback and contributing

WindowAtlas keeps evolving, and your feedback shapes it:

- **Found a bug?** Open a [bug report](https://github.com/zerotoonex/WindowAtlas/issues/new?template=bug_report.yml) with your macOS version, WindowAtlas version (bottom-left of the main window) and steps to reproduce.
- **Have an idea?** Open a [feature request](https://github.com/zerotoonex/WindowAtlas/issues/new?template=feature_request.yml) — especially window-juggling pain points from parallel AI coding.
- **Want to contribute code?** Fork and open a pull request. Please run `swift test` first and keep changes focused.
- If WindowAtlas helps you, a ⭐️ helps other AI coders find it.

Please never include secrets, passwords or personal data in issues, screenshots or test fixtures.

By submitting a pull request, you agree that your contribution is licensed under the same MIT License as the project.

## License

WindowAtlas is open source under the [MIT License](LICENSE). Copyright © 2026 zerotoonex.

**In plain words** (the [LICENSE](LICENSE) file is the only legally binding text):

- **You may** use WindowAtlas for free — personally or commercially — and copy, modify, merge, publish, distribute, sublicense or sell copies of it.
- **You must** keep the copyright notice and the MIT license text in every copy or substantial portion you distribute, including modified versions and binaries.
- **No warranty:** the software is provided "as is". The authors are not liable for any claim, damage or data loss arising from its use. Keep your own backups of important notes.

**Scope:** the license covers everything in this repository — source code, tests, scripts, documentation and the brand assets in `branding/`. WindowAtlas has no third-party dependencies; it only uses Apple system frameworks, which are governed by Apple's own terms. Each release build includes the license at `WindowAtlas.app/Contents/Resources/LICENSE`, and the DMG includes `LICENSE.txt`.
