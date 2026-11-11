<p align="center"><img src="Resources/AppIcon.png" width="128" alt="Sysbar icon"></p>

# Sysbar

A tiny macOS menu bar app that shows the **System Stats** panel from
[oMLX](https://github.com/jundot/omlx) — CPU E/P-core usage, thermal state,
load average, uptime, GPU usage, GPU memory and a memory breakdown — plus
Disk (usage, read/write speed) and Network (download/upload, interface, IP)
panels, behind an animated,
[Stats](https://github.com/exelban/stats)-style menu bar icon.
Available in **English** and **Portuguese**.

- Native Swift/AppKit + SwiftUI, no dependencies, no Xcode project.
- Public APIs only (Mach host statistics, IOKit accelerator and block-storage
  stats, `vm_statistics64`) — no `sudo`, no helper tools.
- Runs as a menu bar–only app (no Dock icon). Small: ~0.8 MB on disk,
  ~25 MB of RAM.

## Download & install

1. Download **`Sysbar-<version>.dmg`** from the
   [latest release](https://github.com/rodrigotrombeta/Sysbar/releases/latest).
2. Open it and drag **Sysbar** onto **Applications**.
3. Open Sysbar from Applications. Its icon appears in the menu bar (there's no
   Dock icon).

**First launch:** Sysbar isn't signed with an Apple Developer ID or notarized,
so macOS blocks it the first time ("Apple could not verify…"). To allow it once:

- Open **System Settings → Privacy & Security**, scroll down and click
  **Open Anyway** next to the Sysbar message, then confirm; **or**
- in Terminal:

  ```bash
  xattr -dr com.apple.quarantine /Applications/Sysbar.app
  ```

To update, download the new DMG and replace the app in Applications (quit
Sysbar first).

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon recommended (E/P-core split).
- Swift toolchain: Xcode **or** just the Command Line Tools
  (`xcode-select --install`).

## Build from source

```bash
git clone https://github.com/rodrigotrombeta/Sysbar.git
cd Sysbar
./build.sh install
```

`./build.sh install` builds a release binary, assembles and ad-hoc signs
`build/Sysbar.app`, copies it to `/Applications` (replacing any previous copy)
and launches it.

To only build without installing:

```bash
./build.sh
open build/Sysbar.app
```

## Rebuild & reinstall after changes

After editing the code (or pulling updates), run the same command again — it
quits the running Sysbar, replaces `/Applications/Sysbar.app` and relaunches:

```bash
git pull            # if updating from GitHub
./build.sh install
```

To package a release (universal app, DMG and ZIP in `dist/`):

```bash
scripts/release.sh
```

If you change the app icon drawing in `scripts/make-icon.swift`, regenerate the
icon first:

```bash
swift scripts/make-icon.swift
./build.sh install
```

## Uninstall

```bash
pkill -x Sysbar; rm -rf /Applications/Sysbar.app
defaults delete local.sysbar.app   # optional: remove saved settings
```

If "Open at login" was enabled, turn it off from the menu before deleting (or
remove Sysbar under System Settings → General → Login Items).

## Using it

Click the menu bar icon to open the Sysbar panel. It stays open while you
interact with it (click outside it, press Esc or click the icon again to close).

**Header (always on top):** 📌 pin to the left/right screen edge (or unpin) ·
Activity Monitor · appearance (System → Light → Dark) · ⚙︎ settings · quit.

**Sections:** CPU · GPU · Memory · Disk · Network · Top memory (top 5 processes).

- **Hover** a section to open its detailed metrics beside the panel.
- **Click** a section to keep its details open (📌). Several can stay pinned at
  once; they are placed side by side without overlapping. Click again, or the
  ✕ in the detail panel, to close.

| Details | Contents |
|---|---|
| **CPU** | Chip and core layout (e.g. 6E + 4P), user / system / E-cores / P-cores, utilization history, load average, thermal state, uptime, top 5 processes by CPU, and a **Per core** dropdown with a chart for every core. |
| **GPU** | GPU name and core count, GPU / renderer / tiler utilization and GPU memory, with a history chart for each, plus a **Per GPU** dropdown with a chart per GPU device. |
| **Memory** | Used / total, memory pressure, App / Wired / Compressed / Swap, usage history, page-in/out history, top 10 processes by memory. |
| **Disk** | Startup volume usage, read/write speed, totals since boot, read/write history. |
| **Network** | Download / upload speed and peaks, interface, IP address, history. |
| **Top processes** | Top 15 by memory and top 10 by CPU. |

> macOS's public APIs report GPU utilization per GPU *device* (one on Apple
> Silicon), not per GPU core, and don't expose Neural Engine (ANE) usage or
> FPS, so those aren't shown. Processes owned by other users (e.g.
> WindowServer) need admin rights and aren't listed.

**Settings (⚙︎)** — changes apply instantly and the panel stays open; click anywhere outside the panel to go back to the stats:

| Setting | Options |
|---|---|
| **Menu bar icon** | For each metric — CPU (total), E-cores, P-cores, GPU, GPU memory, Memory, Disk, Network: show it or not, its **style** and its **color**. Use the ▲/▼ arrows to reorder them: top to bottom in the list = left to right in the menu bar. |
| Styles | CPU/GPU metrics: line chart, bar, pie, percentage, chart + %. Memory: pie, bar, line, percentage, I/O (page-ins/outs). Disk: pie, bar, percentage, I/O (read/write). Network: I/O chart (download/upload) or speed text. |
| Colors | **Colored**, **Monochrome** (white/black, follows the menu bar) or **By utilization** (green → orange → red). Memory pies/bars split into App (green) / Wired (orange) / Compressed (magenta). |
| Show label | The small stacked label (CPU, GPU, RAM, SSD, NET). |
| General | Refresh interval (0.5–5 s), Language (English / Português), Appearance (System / Light / Dark), Open at login (needs the app in `/Applications`). |
| Updates | **Check for Updates…** asks GitHub for the latest release; if it is newer, Sysbar offers to download its DMG (install it like the first time). "Check for updates automatically" (on by default) does this once a day and stays silent when offline. The only network request Sysbar makes is to `api.github.com`. |

Settings persist in `UserDefaults` (`local.sysbar.app`).

### Previewing the drawing

```bash
build/Sysbar.app/Contents/MacOS/Sysbar --preview /tmp/sysbar-preview
```

writes PNGs of every icon style/color mode (light and dark) and of the stats
panel, then exits.

## Project layout

```
Sources/Sysbar/
  main.swift                 app entry point (+ --preview mode)
  AppDelegate.swift          status item, sampling timer, panel open/close, pin
  SystemStatsSampler.swift   CPU/GPU/memory/disk readings (adapted from oMLX)
  SystemStatsPanels.swift    CPU/GPU/Memory/Disk SwiftUI panels (adapted from oMLX)
  Localization.swift         English / Portuguese strings (tr("en", "pt"))
  StatsTheme.swift           colors/fonts + sparkline view
  StatusIconRenderer.swift   animated Stats-style menu bar icon
  AppModel.swift             shared observable state for all panels
  MainPanelView.swift        main panel: header, sections, settings
  DetailViews.swift          hover/pinned detail panels (CPU, GPU, Memory, …)
  Charts.swift               history charts, meters
  PanelWindows.swift         floating panels, hover tracking, detail placement
  ProcessSampler.swift       top processes by memory / CPU (libproc)
  IconSettings.swift         icon metrics/style/color options (UserDefaults)
  UpdateChecker.swift        "Check for updates" via GitHub releases
scripts/make-icon.swift      generates Resources/AppIcon.icns
scripts/release.sh           universal build + DMG/ZIP for GitHub releases
build.sh                     build / install script
```

## Credits & license

`SystemStatsSampler.swift`, `SystemStatsPanels.swift` and the sparkline view
are adapted from [oMLX](https://github.com/jundot/omlx) by jundot, licensed
under the Apache License 2.0 (see `LICENSE`). A copy of the license ships in
every build and package (`Sysbar.app/Contents/Resources/LICENSE`, plus
`LICENSE.txt` in the DMG). The menu bar icon design is
inspired by [Stats](https://github.com/exelban/stats) (no code copied).
