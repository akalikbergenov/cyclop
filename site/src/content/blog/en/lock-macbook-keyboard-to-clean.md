---
title: "How to lock a MacBook keyboard and trackpad to clean them"
description: "macOS has no cleaning mode. Here is how to wipe the keys and trackpad without typing into an open document or quitting an app by accident."
date: 2026-10-28
lang: en
pair: keyboard-lock
---

Wiping a MacBook keyboard with the laptop on is a small gamble. A cloth presses keys: letters land in whatever document is open, ⌘Q quits an app, the brightness keys black out the screen. Apple's own advice is to shut the Mac down first — which works, and costs a restart every time.

macOS has no built-in cleaning mode. Cyclop has one in its **Utilities** tab.

## How it works

1. [Download Cyclop](/download/) and open it from Applications.
2. Move the pointer to the notch and open the **Utilities** tab.
3. Press the lock button. The first time, Cyclop explains why it needs Accessibility and opens the right page in System Settings. Turn Cyclop on there and press the button again.
4. The screen goes black. Every key press and every trackpad click is swallowed — wipe as hard as you like.
5. To unlock, **hold Esc or the minus key for 2 seconds**. If you forget, the lock lifts by itself after a minute.

## Why it needs Accessibility

Stopping a key from reaching macOS takes the permission that lets an app see and swallow input — there is no lighter API that does it. An app that only "steals focus" looks locked while ⌘Q, ⌘Tab and the brightness keys still get through, which is worse than no lock at all.

That is why Cyclop asks for it only on the button press, after an explanation, and never at launch. If you switch the Utilities tab off in Settings, it is never asked at all.

## Three ways out, always

- **Hold Esc or −** for 2 seconds. A cloth brushing over the key does not do it; a deliberate hold does.
- **A minute passes.** This limit cannot be changed, on purpose: it does not depend on you, the app or anything else working right.
- **Cyclop quits.** The lock lives inside the app and goes away with it.

One case where the lock refuses to start: while a password field or a password manager holds secure keyboard input, macOS does not let any app intercept keys. Cyclop tells you so instead of pretending to lock.

> Cyclop is a free, open-source app for the MacBook notch: music from any app or browser tab, a file shelf, clipboard history, snippets — and this lock.
