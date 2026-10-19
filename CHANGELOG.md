# Changelog

## 0.9.3 — 2026-10-19

- The project now lives at github.com/kaizaoji/WindowAtlas (old links redirect). The one-line installer points to the new location.

- Terminal and iTerm2 tabs: list every tab (each iTerm2 split pane) with its full working directory, running program and TTY; double-click to switch. Tabs can't be closed from WindowAtlas so running sessions are never interrupted. Only titles, TTYs, process names and working directories are read — never terminal contents.
- Tab thumbnails are confirmed against the window's live title at capture time, so a preview is never stored for the wrong tab.
- One search box and one matching rule for windows and tabs: titles, apps, URLs or paths, with multiple keywords.
- Arrange windows: multi-select 2–9 windows from any apps and lay them out in one click (auto grid, side by side, stacked, main window on the left) on the first window's display, on each window's own display, or on a chosen display. Arranged windows are marked with their display until moved.
- Multi-select tabs to arrange their windows, or split Chrome and Edge tabs into their own windows (pages don't reload) and arrange them.
- Command library: four built-in Codex commands for resuming sessions (`codex resume`, `--all`, `--last`, `<session ID>`). Existing libraries receive new built-in commands once, without duplicates or overwriting your edits.

## 0.9.2 — first public release

- Thumbnail boards grouped by app, an always-on thumbnail sidebar, and double-click or Return to open the selected window.
- Grid and list keyboard navigation with selection highlighting, automatic scrolling, Home/End and Esc.
- Stable display selection and verified cross-display resizing; reduced full-window enumeration during switching.
- Optional terminal task status for Terminal and iTerm2.
- Optional Chrome, Edge and Safari tabs, per browser or combined under All Windows, with live preview of the current tab.
- Drag to reorder windows; Shift/⌥ multi-select to drag as a group, move to top or bottom; per-section manual order.
- Windows on other desktops (Spaces) are listed and one click switches there; closed-but-lingering window surfaces are hidden automatically.
- Smoother scrolling: thumbnails update per card instead of redrawing the whole board.
- Window placement grid with multi-display support.
- Command library with ⌘K quick search and copy.
- Markdown project notes with nested folders, sub-notes, images, document import, verified backups to multiple locations, and .zip export/import for moving to another Mac.
- First-launch permission guide; light/dark appearance; English and Simplified Chinese.
- Apple silicon, macOS 14 or later. Not notarized: see the install guide for the one-time “Open Anyway” step.
