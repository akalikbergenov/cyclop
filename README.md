> [!WARNING]
> **This is the beta branch.** It holds what has not been decided on yet.
> There is no build to download and no updates — it is built from source and
> breaks without warning.
>
> The stable version lives in [`main`](https://github.com/akalikbergenov/cyclop/tree/main)
> and in [releases](https://github.com/akalikbergenov/cyclop/releases/latest).
> The rules of the channel are in [docs/beta.md](docs/beta.md).

## What is being tried here

| Feature | What it does | Discussion |
|---|---|---|
| **Composed surface** | music, the next meeting and the latest copies on one screen; the rail is down from ten icons to five | [#100](https://github.com/akalikbergenov/cyclop/issues/100) |
| **Live notch** | the panel drops by one line when the charger goes in or the track changes on its own | — |
| **Visualizer** | a real spectrum of what is playing. **Off by default**: turn it on in Settings → Visualizer, and macOS will ask for system audio recording access | [#103](https://github.com/akalikbergenov/cyclop/issues/103) |
| **Pinned bar** | the spectrum and what is playing stay under the notch while the panel is folded | [#103](https://github.com/akalikbergenov/cyclop/issues/103) |

The visualizer is the one place where the beta steps away from the zero
permissions promise, which is exactly why it stays off until it is decided
whether it belongs here at all.

### Home

![Home: music, the next meeting and the clipboard on one surface](docs/beta/home-surface.png)

Music with a real spectrum of what is playing on the left; the next meeting with
its countdown and the latest copies on the right. These used to be three tabs,
and there was no way to see them at once: with the calendar open you could not
see what was playing.

### Tools

![Tools: translate, currency and teleprompter under one icon](docs/beta/tools.png)

Translate, the converter and the teleprompter took three icons out of ten and
are opened less often than anything else. Now it is one icon with a switch
inside: the rail is about where to go, not about which mode you are in.

Five icons are left on the rail instead of ten.

### The pinned bar

![The bar under the notch: artwork, track and spectrum](docs/beta/pinned-bar.png)

The spectrum is only visible while the panel is held open by the pointer. That
is right for everything else in the panel, but not for music: it is listened to
for hours, and the panel is opened for seconds. Pinning leaves the artwork, the
title and the spectrum under the notch.

The bar does not get in the way: hovering the notch opens the panel over it, and
a click beside the notch reaches the menu bar. It carries no buttons — unpinning
lives on the home surface and in settings.

### Where to turn the spectrum on

![Settings: the visualizer switch](docs/beta/settings.png)

The first item in settings. Turning it on makes macOS ask for system audio
recording access — that is the third permission the whole feature hangs on.

## Build

```sh
git clone -b beta https://github.com/akalikbergenov/cyclop.git
cd cyclop
Scripts/bundle.sh release
open build/Cyclop.app
```

To go back to stable, download a disk image from the releases and replace the
app. Settings live in `~/Library/Application Support/Cyclop` and survive it.

> [!NOTE]
> **Permissions are lost on every rebuild.** `Scripts/bundle.sh` signs the bundle
> anew, and macOS ties granted permissions to the signature — to the system this
> is a different app every time. Calendar and audio recording access have to be
> granted again. This is not a beta bug but a consequence of building from source
> without a Developer ID certificate.

---

# Cyclop

*English · [Русский](README.ru.md)*

The MacBook notch as a working tool. A native SwiftUI/AppKit app: invisible at
rest, and on hover it unfolds downwards into a panel with a player, a shelf for
files, clipboard history and your next meetings.

[![build](https://github.com/akalikbergenov/cyclop/actions/workflows/build.yml/badge.svg)](https://github.com/akalikbergenov/cyclop/actions/workflows/build.yml)
[![Buy Me a Coffee](https://img.shields.io/badge/buy%20me%20a%20coffee-%E2%98%95-FFDD00?style=flat-square&labelColor=000000)](https://buymeacoffee.com/akalikbergenov)

![The Cyclop panel](docs/panel.png)

**[Download the latest version](https://github.com/akalikbergenov/cyclop/releases/latest)** —
macOS 15 or newer. The first launch needs one permission granted by hand,
[here is how](#installation).

```
0.0 % CPU at rest  ·  ≈40 MB + 14 MB helper  ·  3.7 MB bundle  ·  one permission, and only on a button
```

The track in the screenshot is playing in a browser tab — Cyclop reads it from
macOS itself, with no permissions and nothing to configure in the browser. How
that works is below.

## What it does

| Tab | What it does |
|---|---|
| **Music** | Artwork, track, artist, a scrubber that seeks, prev / play-pause / next. The source is **anything**: a player, a browser tab, any app macOS itself can see |
| **Shelf** | Drag files into the notch and they stay there until needed; drag a card out and the file goes wherever it is dropped. A click selects a card, ⌘-click selects several, and then the whole group is dragged. A screenshot taken to the clipboard is saved as a file and lands here too — including one taken on an iPhone, if you copy it there |
| **Clipboard** | The last 40 copies; a click puts an entry back on the clipboard |
| **Snippets** | A hand-kept list of what you are tired of retyping: an address, a phone number, an email. Added with a button in the panel, removed with the cross on a card; a click puts the text on the clipboard. The same list lives in `~/Library/Application Support/Cyclop/snippets.json` and can be edited there instead |
| **Calendar** | The next meeting a week ahead: how long until it starts and a button that joins the call — Zoom, Meet, Teams and others. The rest of the meetings as a list |
| **Translate** | Type on the left, the translation appears on the right — by itself, offline, using macOS's own facilities. English goes to Russian, Russian to English; the direction comes from the script the text is written in. macOS does not preinstall language packs, so the first time you have to download one: System Settings → General → Language & Region → "Translation Languages…" |
| **Currency** | An amount on one side, the other currency on the other; type into either. Rates are the one thing in Cyclop that comes over the network — a public table of daily rates, fetched once an hour, and only while the tab is on |
| **Teleprompter** | A script that scrolls under the camera at a speed you set. The notch is the one place on the screen a teleprompter belongs: reading happens right beside the lens, so on the recording the eyes stay on the camera instead of travelling to a window below it. The panel holds itself open while the text is moving — reading a script means not touching the trackpad |
| **Notes** | Scratch, on the right rail of icons: jot something down, come back, delete it or carry it off through the clipboard. Hovering lands with the caret ready; blank notes sweep themselves out |

The panel opens when the pointer reaches the notch and collapses when it leaves.
Tabs switch on hover as well — but only if the pointer has come to rest on the
icon: one passing through switches nothing. During a file drag the panel opens by
itself and goes straight to the shelf. The menu bar icon toggles the panel,
hides every tab's contents at once, and quits. The icon itself can be
removed — ⌘-drag it off the bar, or flip the switch in Settings — and
relaunching Cyclop brings it back.

Any tab can be switched off in **Settings → Show in Panel**. Off means two
things: the icon leaves the rail, and the tab's background work stops with
it — the clipboard poll, the calendar watch, the Now Playing helper, the
rate fetch. The rail is for what gets a glance between other things; a mode
used once a month may live there, but only as long as the people who never
use it can take it off.

## Requirements

- macOS 15 or newer (the Translate tab runs on Translation.framework)
- Swift 6 toolchain (the full Xcode is not needed, Command Line Tools are enough)

The app works on Macs without a notch too: the panel then treats a 180 × 24 pt
area at the top centre of the screen as one.

## Building

```bash
git clone https://github.com/akalikbergenov/cyclop.git
cd cyclop
./Scripts/bundle.sh          # swift build + assemble the .app + ad-hoc sign
open build/Cyclop.app
```

The icon is generated in code, with no graphics editor involved:

```bash
swift Scripts/make-icon.swift "$PWD/Resources/AppIcon.icns"
```

## Installation

Open `Cyclop-<version>.dmg` and drag the app into Applications. It opens on
the first try: since 0.8.0 the image is signed with a Developer ID and
notarised by Apple, so there is nothing to allow and nothing to type.

Updating works the same way: open the new image and replace the app. Coming
from a version before 0.8.0, macOS may ask for the calendar permission once
more — the app's signature changed, and that is what the permission was tied
to. The version is the first line of the menu bar menu.

A build from source (`Scripts/bundle.sh`) is ad-hoc signed and is not
notarised, so on any Mac but the one that built it the first launch goes
through **System Settings → Privacy & Security → "Open Anyway"**. Releases do
not have this step.

Releases come often, and a star does not announce them — it is a bookmark, not a
subscription. To hear about updates: the **Watch** button at the top right →
**Custom** → tick **Releases**. Only releases will arrive, no issues or pushes.

### Building the image yourself

```bash
./Scripts/dmg.sh
```

Puts `build/Cyclop-<version>.dmg` next to the app, with an `/Applications`
shortcut inside. The version number comes from `Scripts/version`.

### Cutting a release

```bash
./Scripts/release.sh
```

Builds the image, tags `v<version>` and creates a GitHub release with the `.dmg`
attached. The notes are two parts: a few lines written by hand, kept in
`docs/releases/<version>.md`, followed by the commit list GitHub assembles. The
script refuses to run without the hand-written part — a list of commits answers
"what changed in the code", while whoever arrives is asking "what does this give
me", and no generator turns the first answer into the second.

The number is written in **one place**, `Scripts/version`. From there it goes
into the app's `Info.plist`, into the image name and into the tag, so they cannot
drift apart. The script also refuses to run on a dirty tree, on unpushed commits,
or when the tag already exists.

Built images live on the [releases page](https://github.com/akalikbergenov/cyclop/releases) —
that is the link to hand to people instead of a file.

## Permissions

**None** — until you open the calendar. The app asks for no Automation, no
Accessibility, no Screen Recording, and needs nothing configured in the browser.
The pointer position is read through `NSEvent.mouseLocation`, the clipboard
through the public `NSPasteboard`, Now Playing through a helper (see below).

Calendar access is the only permission Cyclop ever requests. It is needed by the
Calendar tab alone, and the system dialog appears neither at launch nor when the
tab is opened, but on an explicit press of a button on a screen that explains
why. Don't use the calendar and the app stays without permissions entirely.

A file put on the shelf from Downloads, Documents or the Desktop is the one thing
macOS asks about separately, and it asks when the shelf is opened, not at launch.
Refusing breaks nothing: the card stays, just without a preview.

Permissions would only be needed by the fallback path, if the main one ever stops
working: Automation for Apple Music and Spotify, and Accessibility for the media
keys.

## How it works

Why the window is shaped the way it is, why the pointer is polled on a
timer, why Now Playing lives inside `/usr/bin/perl`, what sitting idle
costs — eighteen notes on decisions the code does not show:
**[docs/architecture.md](docs/architecture.md)**.

## Limitations

- Now Playing rests on a private framework and on `/usr/bin/perl` remaining a
  platform binary without library validation. Apple can close this in any update
  — the Music and Spotify fallback takes over then. For the same reason the app
  is unfit for the App Store.
- Apple has deprecated the scripting runtimes (perl among them) and will remove
  them from the system one day. The helper survives exactly until that moment.
- The shelf references files rather than copying them: move the original and the
  card disappears on the next launch. The exception is clipboard screenshots,
  which are saved into `~/Pictures/Cyclop` and are never deleted automatically,
  even when the card leaves the shelf. Only the user clears that folder: the
  “Clear Screenshots Folder” in Settings sends its contents to the Trash —
  a hand too, not a schedule.
- Entries typed `org.nspasteboard.ConcealedType` (password managers) never enter
  the clipboard history.
- The join button appears only if the call link is in the event itself — in the
  location field, the notes or the URL. Meet, Zoom, Teams, Webex, Whereby, Jitsi,
  Telemost and Discord are recognised.
- A screenshot from the iPhone arrives through Universal Clipboard, so it needs
  what that needs: one Apple ID, Bluetooth and Wi-Fi on, Handoff enabled and the
  devices near each other. And it overwrites the clipboard on the Mac — what was
  overwritten stays in the Clipboard tab one click away.
- macOS does not preinstall translation languages — the first time, the pack has
  to be downloaded through System Settings; the panel says so and opens the right
  screen.

## Layout

```
Sources/Cyclop
├── main.swift                 entry point, .accessory
├── App/
│   ├── AppDelegate.swift      menu bar icon, launch at login
│   └── Strings.swift          string lookup, current language
├── Notch/
│   ├── NotchGeometry.swift    notch size and every rect derived from it
│   ├── NotchPanel.swift       the NSPanel above the menu bar
│   ├── NotchRootView.swift    panel hit-testing + drag & drop destination
│   ├── PointerWatcher.swift   pointer sampling: hover and click-through
│   ├── PanelState.swift       one display's share: open, dragged onto, typing
│   ├── NotchScreenPanel.swift the panel as it stands on one display
│   └── NotchController.swift  one model, one panel per display
├── Model/
│   ├── NotchViewModel.swift
│   └── PrivacyMode.swift      hiding contents: sections and reveals
├── Services/
│   ├── MediaController.swift  picks the Now Playing source
│   ├── NowPlayingFeed.swift   runs the helper in perl, parses its stdout
│   ├── PlayerBridge.swift     fallback: AppleScript + media keys
│   ├── ShelfStore.swift
│   ├── ClipboardStore.swift
│   ├── ScreenshotVault.swift  clipboard screenshots onto disk
│   ├── SnippetStore.swift     snippets: reading and writing snippets.json
│   ├── ConfigStore.swift      settings: reading and writing config.json
│   ├── Support.swift          ~/Library/Application Support/Cyclop
│   ├── DebouncedWrite.swift   writes to disk no more often than needed
│   ├── NoteStore.swift        scratch notes: notes.json
│   ├── Translator.swift       Translation.framework, direction by script
│   ├── CurrencyStore.swift    rates over the network, the one tab that has any
│   ├── TeleprompterStore.swift the script and where reading it has got to
│   ├── ScreenshotFolderWatcher.swift  screenshots saved to disk, onto the shelf
│   └── CalendarStore.swift    EventKit: next meetings and the call link
└── UI/                        NotchShape, tab panes, theme

Sources/CyclopMediaHelper
└── helper.m                   dylib for /usr/bin/perl: MediaRemote -> JSON
```

## Contributing

The rules are short and live in [CONTRIBUTING.md](CONTRIBUTING.md): what gets
taken, what does not, and what to check before sending. The main one is that
the app works without macOS permissions and without the network, and a change
that alters this is a separate conversation.

What the app reads, what it keeps and where, where it goes on the network —
[SECURITY.md](SECURITY.md). The channel for vulnerabilities is there too:
private, no issue needed.

## Thanks

The app is free — no subscriptions, no ads, no data collection — and will stay
that way. If it turned out useful and you feel like supporting it:

**[☕ Buy Me a Coffee](https://buymeacoffee.com/akalikbergenov)**

Special thanks to everyone who showed up in the first days and made the app
better: [@DontTrustMexD](https://github.com/DontTrustMexD),
[@a58becde](https://github.com/a58becde),
[@ispy4you](https://github.com/ispy4you),
[@iFuzYs](https://github.com/iFuzYs),
[@zhd-dm](https://github.com/zhd-dm),
[@komekovars](https://github.com/komekovars),
[@superkai-sdk1](https://github.com/superkai-sdk1),
[@Ariet2003](https://github.com/Ariet2003).

## Licence

MIT
