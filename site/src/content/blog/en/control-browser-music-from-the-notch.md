---
title: "How to control music in a browser tab from the MacBook notch"
description: "Pause, skip and scrub YouTube, Spotify Web or SoundCloud without hunting for the tab — from the notch, with no extension and no permissions."
date: 2026-10-28
lang: en
pair: browser-music
---

Music in a browser tab has one annoying habit: to pause it, you have to find the tab. With twenty tabs and two windows open, that is a small hunt every time the phone rings.

macOS already knows what is playing. The same information Control Center shows under **Now Playing** — the track, the artist, the artwork, play and pause — is available for any tab that plays media. Cyclop puts it into the notch, where the pointer can reach it in a second.

## What you get

- **Artwork, track and artist** of whatever is playing, whether it is Apple Music, Spotify, a YouTube video or a SoundCloud tab.
- **Play and pause, previous and next.** Skip buttons light up when the source supports them; a single video usually has no "next", so they dim instead of pretending.
- **A scrubber that actually seeks**, when the source allows it.

There is nothing to install in the browser and nothing to allow in System Settings. Cyclop reads Now Playing from macOS itself, the same way Control Center does.

## How to set it up

1. [Download Cyclop](/download/) and drag it into Applications. It is signed and notarised, so it opens on the first try.
2. Start something in a browser tab — Safari, Chrome, Arc and Edge all report to Now Playing, as do most music and video sites.
3. Move the pointer to the notch. The panel unfolds on the **Music** tab.

On a Mac or an external display without a notch, a thin strip at the top centre of the screen does the same job.

## Good to know

- **Two things playing at once.** The panel follows whichever source macOS considers current — the same one your keyboard's media keys control.
- **Nothing leaves your Mac.** The track information comes from macOS; Cyclop sends nothing anywhere. The only exception is a fallback path for Spotify artwork, used only if the main path ever stops working.
- **It costs nothing at rest.** While the panel is folded, Cyclop uses 0 % CPU. If you never listen to music on your laptop, switch the Music tab off in Settings and its background helper stops completely.

> Cyclop is free and open source. Besides music, the notch panel holds a file shelf, clipboard history, snippets and your next meeting — and any of them can be switched off.
