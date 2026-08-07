# Cyclop

*English · [Русский](README.ru.md)*

> ### A modified version
>
> This is a fork of [akalikbergenov/cyclop](https://github.com/akalikbergenov/cyclop).
> The original app is by [@akalikbergenov](https://github.com/akalikbergenov), who
> deserves the credit for the idea, the notch panel, the player, the calendar and
> the translator. What this fork adds is a keyboard-driven clipboard, a screenshot
> editor with text recognition, a settings tab and a few other things —
> [full list below](#what-this-version-adds).
>
> Upstream: <https://github.com/akalikbergenov/cyclop> · Same licence, MIT.

The MacBook notch as a tool. A native SwiftUI/AppKit app: invisible at rest, it
unfolds downwards into a panel with a player, one buffer for copies and files,
screenshots, notes and the next meetings.

![The Cyclop panel](docs/panel.png)

```
0.0 % CPU at rest  ·  ≈40 MB + 14 MB helper  ·  ~2 MB bundle  ·  permissions only on a button press
```

## Installation

**[⬇ Download the latest version](https://github.com/marmeladov98/cyclop/releases/latest)** ·
macOS 15 or newer · ~1.2 MB

1. Open the downloaded `Cyclop-<version>.dmg` and drag **Cyclop** into Applications.
2. Launch it. The first time macOS will refuse: the image is signed ad-hoc,
   without a Developer ID. Go to **System Settings → Privacy & Security**, where
   a line about Cyclop and an **"Open Anyway"** button are waiting at the bottom.
   Or, in one command:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Cyclop.app
   ```
3. That is all. An eye appears in the menu bar; the panel opens on hover.

Two permissions are asked for by the app itself, and only when they are needed:
**Accessibility** to paste the entry chosen with ⌘⌥V, and **Screen Recording**
to take a screenshot with ⌘⇧A. Use neither feature and neither is ever asked
for. After granting one, restart the app once.

Updating works the same way: open the new image, replace the app. The version is
the first line of the menu.

> **No image in the releases yet?** Then build one — it is a single command:
> ```bash
> git clone https://github.com/marmeladov98/cyclop && cd cyclop && ./Scripts/dmg.sh
> ```
> Needs macOS 15 and the Command Line Tools (`xcode-select --install`). The
> resulting `build/Cyclop-<version>.dmg` opens exactly as above.

## What this version adds

Everything below sits on top of the original; anything not named here works as
its author wrote it.

**A keyboard-driven clipboard — ⌘⌥V.** The recent copies open as a list in the
middle of the screen: arrows choose, Return pastes into whatever you were typing
in. ⌘1…⌘9 jump, ⌫ drops an entry, esc closes, and pressing ⌘⌥V again steps down
the list. The automatic paste needs Accessibility; without it the entry still
lands on the clipboard.

**The shelf and the clipboard became one list.** Copied text used to live in one
tab and files and pictures in another. Now there is one Buffer tab holding text,
links, files, pictures and video, with QuickLook thumbnails, drag-out and
⌘-click for a group. Old shelf entries migrate themselves.

**Screenshots with an editor — ⌘⇧A.** The screen freezes, you pick a region (or a
window in one click, rounded corners and all; or the whole screen by clicking the
menu bar) and draw on it: rectangle, ellipse, arrow, line, pen, highlighter,
text, pixelation. What is drawn stays an object — movable, resizable by its
grips, recolourable, undoable. ⌘C copies, ⌘S saves to `~/Pictures/Cyclop`.

**Text recognition and translation.** A button on the shot toolbar reads the text
out of the chosen region with Vision — on the device, nothing uploaded. The
result opens in its own window: the crop on the left, the text on the right with
a language menu, a copy button and a translation through the same offline
translator the Translate tab uses.

**A settings tab.** Buffer size, whether copied text survives a restart, saving
copied images, three shortcuts recorded by pressing them, panel and notch size,
launch at login, hide-contents, and whether the panel opens on hover or on a
click.

**Fixes in the original code.** The copy history no longer disappears when a
monitor is plugged in — the store used to live inside the panel, and the panel is
rebuilt on any change of screen arrangement.

**Building.** `Scripts/bundle.sh` signs with a stable identity when one exists
(`CODESIGN_IDENTITY`, a Developer ID, or a self-signed certificate named
"Cyclop"), and spells out what ad-hoc costs: TCC keys granted permissions to the
binary's hash, so they lapse on every rebuild.

Per-version detail lives in [`docs/releases`](docs/releases).

## What it does

| Tab | What it does |
|---|---|
| **Music** | Artwork, track, artist, a scrubber that seeks, prev / play-pause / next. The source is **anything**: a player, a browser tab, any app macOS itself can see |
| **Buffer** | Everything copied or dropped in, one list: text, links, files, pictures. A click puts an entry back on the clipboard. Files can be dragged straight out into a Finder window — ⌘-click several and the whole group goes. A picture copied to the clipboard is saved as a file and kept, including one copied on an iPhone. **⌘⌥V** opens the same list under the keyboard: arrows to choose, Return to paste it into whatever you were typing in |
| **Snippets** | A hand-kept list of what you are tired of retyping: an address, a phone number, an email. Added with a button in the panel, removed with the cross on a card; a click puts the text on the clipboard. The same list lives in `~/Library/Application Support/Cyclop/snippets.json` and can be edited there instead |
| **Calendar** | The next meeting a week ahead: how long until it starts and a button that joins the call — Zoom, Meet, Teams and others. The rest of the meetings as a list |
| **Translate** | Type on the left, the translation appears on the right — by itself, offline, using macOS's own facilities. English goes to Russian, Russian to English; the direction comes from the script the text is written in. macOS does not preinstall language packs, so the first time you have to download one: System Settings → General → Language & Region → "Translation Languages…" |
| **Notes** | Scratch, on the right rail of icons: jot something down, come back, delete it or carry it off through the clipboard. Hovering lands with the caret ready; blank notes sweep themselves out |
| **Screenshot** | **⌘⇧A** freezes the screen, you drag out a region and draw on it — rectangles, ellipses, arrows, lines, pen, highlighter, text, pixelation — and everything drawn can be picked up and moved or resized afterwards. ⏎ copies it, and the buffer catches it like any other copied picture. The other half is reading: point it at a region and it turns the text in the picture into text you can paste, in any language Vision knows, and translates it on the spot |
| **Settings** | How many entries the buffer keeps, whether copied text survives a restart, both shortcuts, the size of the panel and of the notch it folds into |

The panel opens when the pointer reaches the notch and collapses when it leaves.
Tabs switch on hover as well — but only if the pointer has come to rest on the
icon: one passing through switches nothing. During a file drag the panel opens by
itself and goes straight to the buffer. The menu bar icon toggles the panel,
enables launch at login, and quits.

**⌘⌥V — the clipboard without the pointer.** The list appears in the middle of
the screen with the newest copy already selected, and never takes focus away
from the app you were typing in.

| Key | |
|---|---|
| `↑` `↓` | move through the history; it wraps at both ends |
| `⇥` / `⇧⇥` | the same, for the hand that is already there |
| `⇞` `⇟` `↖` `↘` | a screenful at a time, or the top and the bottom |
| `⌘1`…`⌘9` | straight to one of the first nine entries |
| `⌥⌘V` again | one step down the list, the way ⌘⇥ walks the app switcher |
| `⏎` | put it on the clipboard and paste it where the caret is — text as text, a picture as a picture, a file as a file |
| `⌫` | drop the entry from the history and stay on the list |
| `esc` | close, changing nothing |

**⌘⇧A — the screenshot.** The screen freezes on the shortcut, so what gets
picked is the frame you were looking at rather than whatever has moved on by
the time you finish dragging. A loupe follows the crosshair with the size and
the colour under it; `C` copies that colour.

| Key | |
|---|---|
| hover a window | it is outlined in dashed blue; one click takes it whole, rounded corners and all |
| hover the menu bar | the whole screen is offered instead |
| drag | pick the region; the grips re-crop it, and a press anywhere outside starts a new one |
| `⌘C` / `⏎` | copy the shot and close |
| `⌘S` | save it to `~/Pictures/Cyclop` without touching the clipboard |
| `⌫` | delete the selected annotation |
| `⌘Z` / `⇧⌘Z` | undo, redo |
| Move tool, press inside | drags the crop itself; press on something drawn and it moves instead |
| `esc` | leave the text field being typed in; a second press closes the shot |
| `C` | copy the colour under the crosshair, while picking |

The **Move** tool is what makes the drawing worth doing: an arrow that landed
in the wrong place is caught by its shaft and dragged, a box by its edge, and
the grips resize whatever is selected — eight around a box, two on an arrow,
being its tail and its head. Whatever is selected also follows the palette and
the thickness slider, so recolouring what you just drew is not a matter of
deleting it. The shape you have this moment finished drawing is selected and can
be moved straight away, without switching tools. Nothing is baked in until the
shot is copied or saved.

**Reading text out of the picture** is the other half. Pick the region, press
the text button, and what was pixels comes back as text — Vision, on the
device, nothing uploaded. What it read opens in its own window:
the crop on the left, the text on the right, with a language menu, a copy
button and a translation that has its own. "Automatic" follows your own
preferred languages and is right most of the time; naming a language is what
rescues the case it is not — Cyrillic read as Latin comes back as confident
nonsense rather than as an error — and changing it re-reads the same picture.
The translation runs through the same offline translator the Translate tab
uses.

All three shortcuts are yours to change, in Settings — including a second one that
opens the panel itself, which ships unset.

Pasting for you means pressing ⌘V for you, and that is the one thing macOS will
not let an app do unasked — see [Permissions](#permissions). Until the box is
ticked the shortcut still does everything else: the entry lands on the
clipboard, and the last ⌘V is yours to press.

## Requirements

- macOS 15 or newer (the Translate tab runs on Translation.framework)
- Swift 6 toolchain (the full Xcode is not needed, Command Line Tools are enough)

The app works on Macs without a notch too: the panel then treats a 180 × 24 pt
area at the top centre of the screen as one.

## Building

```bash
git clone https://github.com/marmeladov98/cyclop.git
cd cyclop
./Scripts/bundle.sh          # swift build + assemble the .app + ad-hoc sign
open build/Cyclop.app
```

The icon is generated in code, with no graphics editor involved:

```bash
swift Scripts/make-icon.swift "$PWD/Resources/AppIcon.icns"
```

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

Built images live on the [releases page](https://github.com/marmeladov98/cyclop/releases) —
that is the link to hand to people instead of a file.

## Permissions

**None** — until you open the calendar, and none for the panel itself. The app
asks for no Automation and no Screen Recording, and needs nothing configured in
the browser. The pointer position is read through `NSEvent.mouseLocation`, the
clipboard through the public `NSPasteboard`, Now Playing through a helper (see
below). ⌘⌥V itself is registered with the window server, which tells the app
when that one combination is pressed and nothing else about what is typed —
so the shortcut works on a fresh install, with nothing to tick.

Calendar access is the only permission Cyclop ever requests. It is needed by the
Calendar tab alone, and the system dialog appears neither at launch nor when the
tab is opened, but on an explicit press of a button on a screen that explains
why. Don't use the calendar and the app stays without permissions entirely.

**Screen Recording** is what the screenshot tool needs, and it needs it for the
obvious reason: it cannot photograph the screen without being allowed to read
the screen. Asked for the first time ⌘⇧A is pressed, never at launch. Don't
take screenshots and the app never asks.

**Accessibility** is asked for by one thing only: the automatic paste at the end
of ⌘⌥V. Typing a ⌘V into another application is input synthesis, and macOS gates
it. The prompt appears the first time an entry is chosen — not at launch — and
refusing it costs exactly one key press: the entry is on the clipboard either
way and ⌘V finishes the job. The permission is granted to the app on disk, so
macOS needs Cyclop restarted once after the box is ticked. There is a
"Allow Automatic Pasting…" item in the menu bar for as long as it is missing.

> **Ticked the box and still asked?** That is the ad-hoc signature, not a bug in
> the permission. An ad-hoc signed build has no stable designated requirement,
> so macOS keys the grant to the exact code hash of the binary — and every
> rebuild produces a different one. The row left in the list belongs to the app
> that used to be there. Remove Cyclop from Privacy & Security → Accessibility
> with the "−" button, restart it, and allow again. To stop it happening on
> every rebuild, sign with a stable identity: `Scripts/bundle.sh` picks up a
> Developer ID automatically, or any self-signed code-signing certificate named
> "Cyclop" (Keychain Access → Certificate Assistant → Create a Certificate),
> or whatever `CODESIGN_IDENTITY` names.

Permissions would only be needed by the fallback path, if the main one ever stops
working: Automation for Apple Music and Spotify, and Accessibility for the media
keys.

## How it works

**The window.** A single `NSPanel` — borderless, non-activating, one level above
the menu bar, `canJoinAllSpaces`. It is always the same size (that of the
expanded panel) and never changes its frame: only the content animates. That is
what makes the animation smooth without the window geometry jerking about.

**Click-through.** The window frame is 700 × 252 pt at the top centre of the
screen, and most of the time almost all of it is transparent. Returning `nil`
from `hitTest` does not help: the window server has already chosen our window as
the recipient, and `nil` merely discards the event instead of passing it down.
Transparency does not affect routing either. The one thing that works is
`ignoresMouseEvents`, toggled by pointer position: inside the visible panel the
window takes clicks, outside it is completely transparent to events.

**Hover.** The pointer position is sampled on a timer rather than delivered by
event monitors. Monitors are structurally unreliable here: a global one never
sees events delivered to the app's own windows, and a local one only fires while
the app is active — which never happens to an `.accessory` app. Hovering would
then depend on which window happened to be under the pointer. Reading
`NSEvent.mouseLocation` does not depend on event routing and behaves identically
everywhere.

**The cursor.** Its shape is chosen by the window server from cursor regions: the
topmost window that claimed a region under the pointer wins. Claiming nothing
does not mean "leave the cursor alone", it means dropping out of that lookup, and
then the window below decides — over a text editor the panel was handed an
I-beam. Ordinary cursor rects will not do, as AppKit disables them for non-key
windows. So `NotchRootView` keeps an `NSTrackingArea` with `.cursorUpdate` and
`.activeAlways` over exactly its clickable area.

**Hovering over tabs.** The pointer crosses the panel in transit, so "hover
switches" would switch tabs on every crossing of the rail. The difference between
"I want this one" and "just passing" is time: a passing pointer clears an icon in
tens of milliseconds, a choosing one stops. A 150 ms threshold separates the two
cases, and nothing else is needed for it. The icon grows under the pointer via
`scaleEffect` rather than a change of `frame`: a layout that recalculates on
mouse movement reads as a stutter.

A tab that types takes the keyboard immediately — on hover as well. A panel that
shows a field but accepts no keys is worse than a caret dimmed for a second in
someone else's window, and the dwell on the rail already keeps a passing pointer
from arriving here at all. The reverse is still possible: a click into another
app drops the keyboard without touching the tab — what was typed stays, and the
panel is free to collapse. The keyboard comes back with a click on the field,
caught in the window's `sendEvent`: a gesture on `TextEditor` never fires,
because the text view claims mouseDown before SwiftUI does.

**A screenshot from the iPhone.** The Action button on the phone runs a shortcut
of two steps: "Take Screenshot" and "Copy to Clipboard". Continuity carries the
copy to the Mac, and the screenshot lands in the buffer. Not one tap, no cloud, no
shared network: the link is direct, like AirDrop's, and encrypted the same way.

There is no shorter path, and the others were tried. Syncing through Photos would
wait on the cloud. AirDrop cannot be aimed from a shortcut — iOS offers it only
through the share sheet, which costs a choice of device every time. A receiver of
our own on a port worked, but required a shared Wi-Fi and spoke plain HTTP. The
clipboard requires nothing.

It cost one correction in how the clipboard is polled. A copy made on the phone
arrives in two parts: macOS puts the type on the pasteboard the moment the phone
announces the copy, while the picture is still coming over the air. The change
counter has already moved and been marked as seen by then — so a single read
returned nothing, and the screenshot vanished entirely, without an error and
without a trace. An announced but not yet delivered picture is now waited for:
the poll repeats for up to six seconds and stops as soon as the clipboard moves
on, because a copy made meanwhile is the newer intention, and finishing a
superseded transfer would put the wrong thing in the buffer. If the picture never
arrives, the text that lay beside it is recorded instead — otherwise a copy that
merely offered an image would disappear from the history altogether.

**Snippets.** Clipboard history is a queue ordered by recency, and the thing
needed once a week is washed out of it precisely because it is rare. Snippets are
the opposite discipline: a short, permanent list that nothing fills by itself. It
lives in a file:

```json
[
  { "label": "Email", "text": "name@example.com" },
  { "text": "+1 555 000 00 00" }
]
```

`~/Library/Application Support/Cyclop/snippets.json`, where `label` may be left
out. "Show Snippets File" in the menu bar opens it in Finder.

Both sides can add to it: the button in the panel and your hands in the file. A
snippet made in the panel is appended to that same file — but the file is re-read
first. The copy in memory is only as fresh as the last visit to the tab, and
writing over it blind would silently undo whatever was added in an editor
meanwhile. A name without a value means nothing, so only the second field is
required; a row without a name shows itself, which is usually enough for an
address or a phone number.

The file is plain text — ordinary JSON in the user's folder, unencrypted. For an
email and an address that is fine; for anything that should not be left readable,
there is a password manager.

Clicking a snippet overwrites the clipboard, deliberately: what was overwritten
stays in the Clipboard tab one click away, whereas restoring it on a timer would
be guessing when the paste happens, and typing into another app's field directly
would have required Accessibility.

**Notes.** A second column of icons, on the right — and scratch notes open it:
a phone number from a call, half a link, a thought for the next half hour. This
is deliberately not note-taking — no folders, no formatting, no search. It is
the editor window with the unsaved buffer, replaced: jot, return, delete, or
carry it off through the clipboard.

Hovering onto the tab lands with the caret ready, and when there are no notes an
empty one is created on the spot: a welcome screen with a button would be slower
than the window this tab replaces. Blank notes sweep themselves out when the tab
is left — a trail of empty cards is exactly the clutter a scratchpad exists to
avoid. The first line stands in for a title in the list: notes here are too
short-lived to deserve naming as a separate step. Esc hands the keyboard back
and never clears the text — this is the one text in the panel that cannot be
re-derived from anywhere.

Everything is written to `~/Library/Application Support/Cyclop/notes.json` a
moment after the typing pauses, not on every keystroke; unlike the snippets file
it is not meant to be edited by hand, and it is plain text. The right column is
not decoration: the six icons on the left already fill the panel's height, and a
seventh would not fit.

**Hiding contents.** The "Hide Contents" menu bar item covers what the tabs
show with a field of twinkling dots — for a screen-shared call, a stream, or a
café. Enabled as a whole or per section — clipboard, snippets, calendar, notes —
and off by default. A hidden row is not drawn at all: this is no blur, there is
nothing in the frame to recover, and the field covers the whole row rather than
tracing the glyphs — a silhouette would give away the length. The eye on a row
uncovers it for a while, folding the panel covers everything again, and copying
works over the cover — the hidden can be used without being shown. Proposed and
written by the community (#16, PR #17).

**Languages.** Russian and English; macOS picks by the user's preferred language
list. The keys in the tables are the English text, so a string without a
translation stays an English phrase instead of turning into an identifier — which
is also what keeps the app readable when run straight from SwiftPM, where the
`.lproj` folders are not around at all.

Everything the app composes itself follows the chosen language rather than the
system one: those two differ more often than one expects. The weekday in the
meeting list and the language names in the Translate header come from
`Bundle.main.preferredLocalizations`, or a column headed in one language above a
button worded in another would read as a mistake.

Capitalisation is a matter of position, not of language. A label starts with a
capital in both, but the words it starts with may not carry one: English weekday
and month names are proper nouns and come out of a formatter capitalised wherever
they stand, while Russian ones are ordinary words and come out lower-case. So the
capital is applied where the label is built and is not written into the
translations. The countdown is abbreviated on purpose — "in 12 min" rather than a
spelled-out word: the full form does not fit the panel header, and an
abbreviation declines in no language, so plural forms are not needed at all.

An individual app's language can be changed in System Settings → General →
Language & Region → Applications.

**The keyboard.** The panel cannot become key by default: taking focus means
dimming the title of whatever window the user is in and stopping the caret
blinking in their text, which is far too rude for a window one merely hovered.
The Translate tab turns `canBecomeKey` on for as long as it is open;
`.nonactivatingPanel` allows keyboard input without activating the app, so the
editor underneath stays active. The keyboard goes back on Esc, on a tab change,
on a click into another app — which the panel catches as the loss of key status —
and simply when the panel collapses.

The panel does not try to stay open on account of text typed into it: there is
one rule for the whole app — open while the pointer is on it. What was typed
survives, so leaving and coming back is safe at any moment. Pinning was tried
here and removed: it added a second way to close the panel that had to be
remembered separately, and a panel that sometimes disobeys the pointer is worse
than one that always obeys it.

**Translation.** `Translation.framework`, entirely offline. Both languages are
named explicitly: Cyrillic goes out to English, everything else comes in to
Russian. The direction is decided by script rather than by language
identification — a single word is far too short to identify reliably, and
"привет" is regularly detected as Bulgarian. Leaving the source language to the
framework is not an option either: its identifier is a separate asset that is
equally not installed, so auto-detection fails with `unableToIdentifyLanguage`,
and the `translate` that follows never returns at all.

Language packs are not preinstalled in macOS. `prepareTranslation()` is what asks
the system for one, but it shows a window of its own and blocks until answered —
and there is nowhere to show it above the borderless panel of an app that is
never active. So the pair is checked through `LanguageAvailability` first, and if
the pack is missing the panel says so and offers a button into System Settings →
General → Language & Region → "Translation Languages…".

**Notch geometry.** The width is `screen.frame.width` minus
`auxiliaryTopLeftArea` and `auxiliaryTopRightArea`, the height comes from
`safeAreaInsets.top`. On the MacBook Air M4 it was developed on, that is
179 × 32 pt.

**Now Playing.** In macOS 15.4 the `mediaremoted` daemon began answering only
clients it trusts. For an ordinary app that looks like this (checked on 15.7.5
with music playing):

| Call | Answer |
|---|---|
| `MRMediaRemoteGetNowPlayingInfo` | 0 keys |
| `MRMediaRemoteGetNowPlayingApplicationIsPlaying` | `false` |
| `MRMediaRemoteGetNowPlayingApplicationPID` | 0 |
| `kMRMediaRemote…DidChange` notifications, 180 s with track changes | not one |

Claiming the `com.apple.mediaremote.external-access` entitlement is not an option
either: it makes it into the signature, but the process is killed at startup
(SIGKILL, exit 137).

The way around needs neither SIP disabled nor anything set in a browser.
`/usr/bin/perl` is an Apple platform binary (`Platform identifier=16`) that the
daemon trusts, and it is signed without library validation, meaning it can load a
foreign library. `Sources/CyclopMediaHelper/helper.m` compiles into
`libcyclopmedia.dylib`, is loaded into perl through `DynaLoader` and from there
receives the daemon's full answer:

```
$ perl -e 'use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0x01); sleep 4' libcyclopmedia.dylib
14 keys: Title=Sen, Artist=Yerbol Narimanuly, Album=Sen,
         Duration=202.39, ElapsedTime=131.23, ArtworkData=<10681 bytes JPEG>
```

The helper prints one line of JSON per change and takes commands on stdin;
`NowPlayingFeed` reads its stdout. Play/pause, next/prev and seeking go the same
way (`MRMediaRemoteSendCommand`, `MRMediaRemoteSetElapsedTime`). The helper exits
as soon as its stdin closes, so it cannot outlive the app.

This works for any source macOS itself can see: a player, a browser tab,
anything. The source name comes from the pid of the session's owner.

**The fallback.** If the helper fails to start three times in a row (perl
removed, the daemon closed to platform binaries too), `MediaController` switches
to scripting Apple Music and Spotify over AppleScript — and then, and only then,
the system asks for Automation.

**The cost of sitting still.** At rest the app does nothing, and that is
measurable: with the pointer still and the panel collapsed it sits at 0.0 % CPU,
and a sampling profiler shows the whole process asleep in `mach_msg2_trap`. The
fractions of a percent appear only while the pointer travels near the top edge
or the panel is open — the price of interaction, not of idling.

That comes from a rule rather than a trick: a timer runs only while somebody can
see what it produces. Pointer sampling requires place and motion both: 60 Hz
only while the pointer has moved recently near the top edge or on the open
panel; one that has stood still for three seconds drops sampling to 8 Hz
wherever it stands. Place alone was not enough — a cursor parked in the menu
bar, which lies entirely inside the warm band, used to hold full rate forever.
Movement is noticed on the next idle tick, 125 ms at worst, less than the dwell
a hover has to survive anyway. A sleeping display stops sampling entirely.

The track-position ticker runs only while the panel is open: the position is
derivable at any moment from an anchor of where it stood and when, and moving a
bar inside a closed panel — four wake-ups a second for as long as anything
plays — is painting for nobody. The calendar timer lives only while the panel is
open; changes to the meetings themselves arrive through `EKEventStoreChanged`
regardless. Store updates do not repaint a collapsed panel at all. Clipboard
polling reads one change counter twice a second, and image data is not touched
while screenshot saving is off — it used to be encoded to PNG in full and thrown
away. Every timer carries a tolerance so the system can coalesce wake-ups. And
no leaks: `leaks` against the live process finds zero.

## Limitations

- Now Playing rests on a private framework and on `/usr/bin/perl` remaining a
  platform binary without library validation. Apple can close this in any update
  — the Music and Spotify fallback takes over then. For the same reason the app
  is unfit for the App Store.
- Apple has deprecated the scripting runtimes (perl among them) and will remove
  them from the system one day. The helper survives exactly until that moment.
- The buffer references files rather than copying them: move the original and the
  card disappears on the next launch. The exception is clipboard screenshots,
  which are saved into `~/Pictures/Cyclop` and are never deleted automatically,
  even when the entry leaves the buffer. Only the user clears that folder: the
  “Clear Screenshots Folder” menu bar item sends its contents to the Trash —
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
│   ├── NotchController.swift  window assembly, opening and closing
│   ├── BufferPickerPanel.swift       the ⌘⌥V window and its key codes
│   └── BufferPickerController.swift  the list: hot key, keys, pasting
├── Model/
│   ├── NotchViewModel.swift
│   └── ShotDocument.swift     annotations: hit-testing, moving, undo
├── Shot/
│   ├── ShotController.swift   shortcut, overlays, what the result becomes
│   ├── ShotPanel.swift        the full-screen overlay and the loupe
│   └── ShotCanvasView.swift   choosing, drawing, dragging what was drawn
├── Services/
│   ├── MediaController.swift  picks the Now Playing source
│   ├── NowPlayingFeed.swift   runs the helper in perl, parses its stdout
│   ├── PlayerBridge.swift     fallback: AppleScript + media keys
│   ├── BufferStore.swift      one history: copies, files and pictures
│   ├── ScreenCapture.swift    the frozen frame behind the shot editor
│   ├── TextRecognizer.swift   Vision: pixels back into text
│   ├── Settings.swift         what the user can change, and what watches it
│   ├── HotKey.swift           system-wide shortcuts, no permission needed
│   ├── Paster.swift           the synthesised ⌘V and the right to send it
│   ├── ScreenshotVault.swift  clipboard screenshots onto disk
│   ├── SnippetStore.swift     snippets: reading and writing snippets.json
│   ├── NoteStore.swift        scratch notes: notes.json
│   ├── PrivacyMode.swift      hiding contents: sections and reveals
│   ├── Translator.swift       Translation.framework, direction by script
│   └── CalendarStore.swift    EventKit: next meetings and the call link
└── UI/                        NotchShape, tab panes, theme

Sources/CyclopMediaHelper
└── helper.m                   dylib for /usr/bin/perl: MediaRemote -> JSON
```

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
