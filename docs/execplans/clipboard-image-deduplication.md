# ExecPlan: Clipboard Image Deduplication in Cyclop

## 1. Purpose / Big Picture

Implement content-based deduplication of images imported from the macOS system clipboard into the Cyclop Shelf.

Cyclop currently monitors the system clipboard and automatically saves detected images to its screenshot storage directory (`~/Pictures/Cyclop`), subsequently adding them to the Shelf.

When another application restores or rewrites an identical image into the clipboard, Cyclop treats it as a new image. This results in duplicate Shelf items and duplicate files on disk.

The objective is to prevent duplicate image imports while preserving the existing behavior of the macOS system clipboard.

**Core principle: Cyclop must deduplicate images on the Shelf, not images in the system clipboard.**

## 2. Repository and environment

- Upstream repository: https://github.com/akalikbergenov/cyclop
- Fork: https://github.com/Twinkle264/cyclop
- Local repository: `/Users/twinkle264/Programming Projects/Forks/cyclop`
- Baseline application version: 0.8.3
- Platform: macOS
- Language: Swift

Before implementation, inspect the current local repository, uncommitted changes, existing architecture, build scripts, and repository-specific instructions.

The local fork may contain changes that are not present in the upstream repository. Preserve all unrelated modifications.

## 3. Problem statement

Cyclop creates duplicate image files when the system clipboard receives an image that has already been imported and is currently present on the Shelf.

The problem has been reproduced while interacting with Cursor, but the implementation must not depend on Cursor or any other specific application.

### Confirmed reproduction

1. Create a screenshot.
2. Cyclop imports the image and saves it to disk.
3. Attach the screenshot to a Cursor chat.
4. Send the message.
5. Send another message without an image.
6. Observe repeated clipboard changes containing the same image.
7. Cyclop creates additional identical files.

### Diagnostic evidence

The following clipboard events were captured:

```text
19:05:45 | changeCount: 426 | Image A
19:06:06 | changeCount: 427 | Temporary text
19:06:06 | changeCount: 428 | Image A
19:06:19 | changeCount: 430 | Image A
```

All three observed image events contained identical SHA-256 hashes:

```text
1de5ad47f6abb96ac6db7bb25826684cdfc4ce18997c837eef3cf15930ab3a9e
```

Cyclop created three files:

```text
Снимок 2026-11-24 в 19.05.45.png
Снимок 2026-11-24 в 19.06.06.png
Снимок 2026-11-24 в 19.06.19.png
```

Each file was 1,825,418 bytes.

This demonstrates that a clipboard change does not necessarily indicate new image content.

The exact process responsible for rewriting the clipboard has not been established and is irrelevant to the proposed solution.

## 4. Functional requirements

### FR-1: Preserve system clipboard behavior

Cyclop must continue monitoring `NSPasteboard` as before.

The deduplication mechanism must never:

- Clear the system clipboard.
- Modify clipboard contents.
- Prevent another application from copying an image.
- Prevent the user from pasting an image.
- Restore previous clipboard contents.
- Interfere with standard macOS clipboard behavior.

Deduplication applies exclusively to automatic image imports into Cyclop.

### FR-2: Detect duplicate images before disk operations

When Cyclop receives an image from the clipboard:

1. Read the image into memory.
2. Calculate a deterministic image fingerprint.
3. Compare the fingerprint against active images on the Shelf.
4. If an identical image exists, terminate the import operation.
5. Otherwise, proceed with the existing image-saving workflow.

The duplicate check must occur before:

- Creating a destination file.
- Writing image data to disk.
- Creating a Shelf item.
- Triggering import-related UI changes.

A rejected duplicate must not create temporary screenshot files.

### FR-3: Scope deduplication to active Shelf items

Only images currently present on the Shelf participate in deduplication.

Do not compare incoming images against the entire screenshot storage directory or a global clipboard history.

If an identical image exists on disk but is no longer present on the Shelf, importing it again is permitted.

### FR-4: Allow reimport after removal

When an image is removed from the Shelf, its fingerprint must no longer prevent future imports, unless another identical image remains on the Shelf.

The next clipboard change containing that image must be processed as a new import.

This is intentional, even if the image was restored by another application rather than explicitly recreated by the user.

Removing an item alone must not immediately reimport the unchanged current clipboard contents.

### FR-5: Preserve deduplication across application restarts

When Cyclop starts:

- Restore Shelf items using the existing persistence mechanism.
- Rebuild or restore the fingerprint index for active image items.
- Ensure the index is ready before accepting clipboard image imports.

An image already present on the Shelf must not be duplicated merely because Cyclop was restarted.

### FR-6: Preserve unrelated functionality

Do not change the behavior of:

- Text clipboard handling.
- File clipboard handling.
- Drag and drop.
- Screenshot folder monitoring.
- Shelf persistence.
- Existing screenshot deletion preferences.
- Privacy settings.
- Existing clipboard monitoring preferences.

Manual file imports must retain their existing behavior. However, image files already on the Shelf should participate in duplicate detection for incoming clipboard images.

## 5. Non-goals

The implementation must not introduce:

- Cursor-specific workarounds.
- Application-specific clipboard rules.
- Global clipboard history.
- Permanent image blacklists.
- Time-based duplicate suppression.
- Arbitrary cooldown periods.
- Automatic cleanup of historical duplicate files.
- Changes to existing screenshot deletion behavior.
- Additional user-facing settings unless required by the existing architecture.
- Perceptual similarity detection.
- New external dependencies.

The feature should work automatically.

## 6. Technical design

### 6.1. Image fingerprinting

Use deterministic SHA-256 fingerprints to identify identical images.

Preferred implementation:

- Use Apple's `CryptoKit`.
- Decode the image into a deterministic pixel representation.
- Normalize the pixel format, color space, alpha representation, orientation, and byte layout.
- Include image width and height in the fingerprint input.
- Calculate SHA-256 over the resulting canonical representation.

Use existing Apple frameworks such as Core Graphics and ImageIO where appropriate.

Do not resize images or use perceptual hashing.

The objective is exact normalized pixel equality, not visual similarity.

The same image encoded as PNG or TIFF should produce the same fingerprint when its normalized pixel data is identical.

Different images, including those differing by a single pixel, must remain distinguishable within the chosen canonical representation.

Avoid hashing filenames, timestamps, or image metadata as the primary identity.

If the existing image conversion pipeline already produces deterministic canonical data, reuse it instead of introducing redundant conversions.

Inspect the current implementation and document the selected canonical representation.

### 6.2. Fingerprint index

Maintain an in-memory index derived from active Shelf image items.

Conceptual structures:

```swift
[ImageFingerprint: Set<ShelfItemIdentifier>]
```

Or an equivalent reference-counted structure compatible with the existing architecture.

The index must support:

- Checking whether a fingerprint exists.
- Registering successfully imported images.
- Removing references when Shelf items are removed.
- Rebuilding from restored Shelf items.
- Keeping the index synchronized when Shelf contents change.

Do not rely on a simple `Set` if multiple existing Shelf items can share the same fingerprint. Removing one item must not unregister another identical item that remains on the Shelf.

Do not repeatedly read and hash every image on the Shelf for each clipboard event.

Reuse cached fingerprints during normal operation.

### 6.3. Import pipeline

Target flow:

```text
NSPasteboard change
        |
        v
Read clipboard image into memory
        |
        v
Calculate image fingerprint
        |
        v
Check active Shelf fingerprint index
        |
        +-- Duplicate found
        |       |
        |       v
        |   Finish processing
        |   No disk writes
        |   No new Shelf item
        |
        +-- No duplicate
                |
                v
            Save image to disk
                |
                v
            Add item to Shelf
                |
                v
            Register fingerprint
```

The existing clipboard event must be marked as processed even when the image is rejected as a duplicate.

An unchanged clipboard must not be reprocessed continuously after the corresponding Shelf item is removed.

### 6.4. Concurrency and consistency

Ensure the following operations cannot race against another import of the same image:

1. Duplicate check.
2. Image persistence.
3. Shelf insertion.
4. Fingerprint registration.

Use the existing actor, main actor, serial execution context, or an appropriate reservation mechanism.

If fingerprint calculation occurs asynchronously, revalidate the result against the current Shelf state before committing the import.

Expensive image decoding and hashing should not unnecessarily block the UI.

### 6.5. Failure handling

If image decoding or fingerprint calculation fails:

- Handle the failure safely.
- Record a diagnostic message where appropriate.
- Do not register an invalid fingerprint.
- Do not silently bypass deduplication and create an unverified duplicate.

If image persistence fails:

- Do not add an invalid Shelf item.
- Do not register the fingerprint.
- Permit subsequent clipboard events to attempt the import again.

If persistence succeeds but Shelf insertion fails, roll back only the newly created file where safe.

Never remove pre-existing user files as part of error recovery.

## 7. Expected source code areas

Inspect the actual repository structure before making changes.

Likely components include:

- `ClipboardStore.swift` — clipboard monitoring and image import.
- `ScreenshotVault.swift` — screenshot persistence.
- `ShelfStore.swift` — active Shelf state and item lifecycle.
- Existing image conversion utilities.
- Existing application startup and restoration logic.

These filenames are indicative, not mandatory implementation boundaries.

Prefer placing the duplicate decision in the automatic clipboard import workflow before invoking screenshot persistence.

Keep fingerprint generation independent from clipboard monitoring where practical to simplify testing.

## 8. Implementation milestones

### Milestone 1 — Architecture investigation

- Inspect repository instructions and current Git state.
- Identify the complete clipboard-to-Shelf import pipeline.
- Identify where the first filesystem write occurs.
- Identify Shelf insertion, removal, restoration, and mutation mechanisms.
- Inspect existing tests and build procedures.
- Determine how image formats are currently decoded and saved.
- Record findings in this ExecPlan.

### Milestone 2 — Image fingerprint utility

- Implement deterministic image fingerprint generation.
- Use SHA-256 and existing macOS frameworks.
- Add unit tests for identical and distinct images.
- Verify equivalent PNG and TIFF representations.
- Verify that dimensions and normalized pixel data participate in identity.

### Milestone 3 — Active Shelf fingerprint index

- Implement an index compatible with existing Shelf models.
- Populate the index from active Shelf items.
- Synchronize the index with item insertion and removal.
- Handle multiple references to an identical fingerprint.
- Restore the index after application restart.
- Handle missing or unreadable files safely.

### Milestone 4 — Integrate duplicate prevention

- Insert duplicate detection before screenshot persistence.
- Return early for duplicate images.
- Preserve clipboard event processing semantics.
- Register fingerprints only for successful imports.
- Ensure asynchronous imports cannot create race-condition duplicates.
- Preserve the original behavior for nonduplicate images.

### Milestone 5 — Validation

- Run all existing automated tests.
- Add dedicated regression tests.
- Build Cyclop using the existing build process.
- Test the original reproduction scenario involving Cursor.
- Verify filesystem behavior.
- Verify normal clipboard behavior.
- Verify reimport after Shelf removal.
- Verify persistence across restart.

## 9. Acceptance criteria

| ID | Scenario | Expected result |
|---|---|---|
| AC-01 | Receive a new image A | One file and one Shelf item are created |
| AC-02 | Receive identical image A again | No additional file or Shelf item |
| AC-03 | Copy text, then receive image A again | No duplicate while A remains on the Shelf |
| AC-04 | Receive a different image B | A new file and Shelf item are created |
| AC-05 | Receive A while both A and B are on the Shelf | No duplicate |
| AC-06 | Remove A from the Shelf | A no longer blocks future imports |
| AC-07 | Receive A after removing it | A new file and Shelf item are created |
| AC-08 | Remove A while the clipboard remains unchanged | A is not immediately reimported |
| AC-09 | Restart Cyclop with A on the Shelf | A continues to participate in deduplication |
| AC-10 | Receive A in another lossless format with identical normalized pixels | No duplicate |
| AC-11 | Receive an image differing by one normalized pixel | Image is imported |
| AC-12 | Paste a rejected duplicate using Command+V | Pasting works normally |
| AC-13 | Two simultaneous imports of A | At most one file and Shelf item are created |
| AC-14 | Screenshot persistence fails | No invalid Shelf item or stale fingerprint |
| AC-15 | A exists on disk but not on the Shelf | Importing A is permitted |
| AC-16 | Send a Cursor message while A remains on the Shelf | No duplicate when A is restored to the clipboard |
| AC-17 | Send a Cursor message after removing A from the Shelf | A may be imported again |
| AC-18 | Remove one of multiple existing identical Shelf items | Remaining identical items continue blocking imports |

## 10. Testing strategy

### Unit tests

Cover:

- Deterministic SHA-256 generation.
- Identical image content.
- Different image content.
- Different image dimensions.
- Equivalent normalized pixels across image formats.
- Fingerprint index insertion and removal.
- Reference counting.
- Index restoration.
- Invalid image data.

### Integration tests

Where supported by the existing architecture, use test doubles or injected dependencies for the clipboard reader, screenshot persistence layer, and Shelf state.

Explicitly verify that:

- The persistence function is never called for rejected duplicates.
- Shelf insertion is never called for rejected duplicates.
- No temporary screenshot files are created for rejected duplicates.
- Clipboard contents remain unchanged.
- Duplicate clipboard events are marked as processed.
- Import failures do not leave stale index entries.
- Concurrent events cannot create duplicates.

Automated tests should not require manipulating the user's real system clipboard or production screenshot directory.

### Manual regression test

1. Start the modified Cyclop build.
2. Record the initial number of files in `~/Pictures/Cyclop`.
3. Create screenshot A.
4. Confirm one new file and one Shelf item.
5. Attach A to Cursor.
6. Send the message without removing A from the Shelf.
7. Send several text-only messages.
8. Confirm that A remains a single Shelf item and no duplicate files appear.
9. Copy arbitrary text into the clipboard.
10. Recreate screenshot A with identical content.
11. Confirm that A is available through the clipboard but no duplicate is imported.
12. Remove A from the Shelf.
13. Receive A again through a new clipboard event.
14. Confirm that it is imported successfully.
15. Restart Cyclop and repeat duplicate detection.

Useful diagnostic command:

```bash
find "$HOME/Pictures/Cyclop" -type f -name '*.png' \
  -exec shasum -a 256 {} + | sort
```

Use a temporary test directory for automated filesystem tests.

## 11. Performance requirements

Cyclop is a continuously running background application.

The implementation must:

- Avoid processing unchanged clipboard events.
- Avoid repeatedly hashing existing Shelf files.
- Avoid unnecessary disk reads and writes.
- Avoid retaining full decoded image buffers longer than necessary.
- Keep fingerprint index memory usage proportional to active Shelf items.
- Avoid introducing unnecessary background timers.
- Preserve UI responsiveness during large image imports.

Fingerprint computation must occur only when relevant image data needs processing or when initializing or updating the index.

## 12. Development constraints

- Follow existing Swift coding conventions.
- Prefer native Apple frameworks.
- Keep changes focused and suitable for an upstream Pull Request.
- Avoid unrelated refactoring.
- Preserve existing user modifications.
- Do not change bundle identifiers or signing configuration.
- Do not delete existing screenshots.
- Do not automatically publish releases or push changes to upstream.
- Do not overwrite the installed production application without explicit authorization.
- Use the repository's existing build and test workflows.

## 13. Progress

Update this section as implementation proceeds.

- [x] Repository and architecture inspected.
- [x] Existing import pipeline documented.
- [x] Image fingerprint utility implemented.
- [x] Fingerprint unit tests added.
- [x] Active Shelf fingerprint index implemented.
- [x] Index restoration implemented.
- [x] Duplicate check integrated before disk persistence.
- [x] Concurrency and failure handling validated.
- [x] Regression tests added.
- [x] Application built successfully.
- [x] Automated tests passed.
- [ ] Cursor reproduction scenario manually validated.
- [x] Final implementation reviewed.

## 14. Decision log

**Decision 1:** Deduplication is scoped exclusively to active Shelf images.

Rationale: The user must be able to import an identical image again after removing its previous Shelf item.

**Decision 2:** The system clipboard remains untouched.

Rationale: Cyclop must not interfere with copying or pasting images.

**Decision 3:** Duplicate detection happens before filesystem persistence.

Rationale: Prevent both duplicate Shelf items and duplicate files.

**Decision 4:** Use deterministic content-based fingerprints.

Rationale: Clipboard change counters, filenames, and timestamps do not represent image identity.

**Decision 5:** Do not depend on clipboard restoration markers or source applications.

Rationale: Clipboard restoration behavior varies between applications, and markers may be absent.

**Decision 6:** Deduplication is not a global historical restriction.

Rationale: Reimporting an image after removing it from the Shelf is valid and intentional.

**Decision 7:** No automatic deletion of existing duplicate files.

Rationale: Historical file cleanup is outside the scope of this change.

**Decision 8 (user confirmed, 2026-11-25):** Preserve permission-free startup. Restore cached fingerprints without reading Shelf files. Legacy entries without a cache defer clipboard image imports until the Shelf is opened and indexing is allowed. Never trigger a new file-access prompt just to initialize deduplication.

**Implementation approach:** `ImageFingerprint` normalizes with ImageIO/Core Graphics and SHA-256. A main-actor `ShelfImageIndex` tracks item UUIDs and asynchronous file indexing. `ClipboardImageImporter` hashes away from the main actor, waits for restored/manual entries to be indexed, then performs check, save, Shelf insertion and registration without suspension on the main actor. Store hashes and file signatures alongside existing Shelf defaults; existing URL persistence is unchanged.

## 15. Surprises and discoveries

Architecture findings (2026-11-25):

- Existing flow: `ClipboardStore.poll` marks `changeCount` processed, prioritizes file URLs, converts TIFF via `NSBitmapImageRep`, and calls `onImage`. `NotchViewModel.start` immediately calls `ScreenshotVault.save`, then `receivedScreenshot`, which adds the URL and changes the tab.
- The first screenshot-directory creation and file write occur only in `ScreenshotVault.save`. Rejecting before that call avoids all screenshot filesystem side effects.
- `ShelfStore` is main-actor isolated. Mutation points: `load`, `add` (including 60-item eviction), `remove`, `clear`, `refreshFromDisk` (missing-file removal). IDs are recreated during `load`; durable cache keys must use paths rather than UUIDs.
- `load` deliberately never reads restored files, because even a stat can trigger TCC for Desktop/Documents/Downloads. User chose deferred legacy indexing above.
- Manual drops and folder-watcher images both use `ShelfStore.add`, so index updates belong at Shelf mutation boundaries, while rejection belongs only in the clipboard importer.
- Unrelated uncommitted pipeline changes were present and must be preserved. Baseline: 17 Swift tests passed. Implementation is staged in a separate working copy; only dedicated source/test/plan changes will be copied back after checks.

Maintain this section during implementation.

Record:

- Unexpected clipboard behavior.
- Existing image conversion details.
- Shelf lifecycle edge cases.
- Persistence or concurrency constraints.
- Deviations from the proposed implementation and their rationale.

Additional discoveries:

- ImageIO can return a non-nil image source even for plain text; `CGImageSourceGetType` must also be non-nil before classifying it as an unreadable image. A real test caught this, and the focused fix passed.
- Fingerprints include big-endian UInt64 width/height plus packed sRGB RGBA8 premultiplied pixels. ImageIO applies orientation without rescaling. PNG bytes are retained; TIFF conversion happens off the main actor after the first duplicate check, and the saved PNG keeps the same normalized fingerprint.
- Cache entries include size and modification date. Normal clipboard lookups never read existing Shelf files; a visible Shelf refresh checks signatures and rehashes changed files. Before the Shelf is viewed after restart, cached hashes represent the last indexed file version, as required to avoid startup file access.
- Unreadable or undecodable active image files fail closed: automatic import cannot claim absence until those cards can be refreshed or are removed. Missing files and ordinary non-image files do not block.
- Clipboard events are still consumed before image processing; removing a card does not replay the unchanged pasteboard. Cancellation handles app shutdown and hiding the Clipboard tab.
- Automated tests use only generated image data, temporary directories, isolated UserDefaults domains and named NSPasteboards. The user's general clipboard, production preferences and screenshot folder are not touched.

Final independent review (2026-11-25):

- Fixed P2 cache-loss-on-refresh: keep durable previous records while pending, excluding them from live matches. `refreshKeepsDurableCacheUntilVerificationCompletes` failed before the fix and passed afterward.
- Fixed P2 malformed-TIFF text regression: image handlers receive an event-bound invalid-data callback, which resumes the original bounded retry and text fallback. Duplicate rejection never invokes it. `invalidTIFFStillRetriesThenRecordsAccompanyingText` failed before the fix and passed afterward. Stopping clipboard monitoring invalidates pending retry callbacks.
- Fixed P2 identical deferred-input accumulation: a temporary per-fingerprint in-flight reservation coalesces repeated image rewrites, removed on every completion, failure and cancellation. `identicalDeferredImportsAreCoalescedAndCancellationReleasesReservation` timed out before the fix and passed afterward.
- Full working-copy suite after the single review fix pass: **45/45 tests passed**, across 6 suites. No review findings remain deferred.
- Limitation/ruling: distinct images awaiting a legacy index remain queued as compressed data until the Shelf is opened. They are not silently dropped or saved to disk before verification. Repeated identical images are coalesced; opening the Shelf once completes migration and produces the durable cache. Capping or dropping distinct images would change the requested import behavior and was not introduced.

## 16. Outcomes and retrospective

Current implementation status (2026-11-25):

- Implemented utility, reference-counted index, cached/deferred restoration, clipboard-only importer, and Shelf lifecycle integration.
- New production files: `ImageFingerprint.swift`, `ShelfImageIndex.swift`, `ClipboardImageImporter.swift`.
- Modified production files: `ClipboardStore.swift`, `ShelfStore.swift`, `NotchViewModel.swift`. ScreenshotVault, folder watcher, bundle identifiers, signing and installed app are unchanged.
- New test files: `ImageFingerprintTests.swift`, `ShelfImageIndexTests.swift`, `ClipboardImageImporterTests.swift`, `ClipboardImagePipelineTests.swift`.
- Baseline: `./Scripts/test.sh` — 17 existing tests passed.
- TDD: fingerprint tests failed before the utility existed; index/importer tests failed before those types existed; lifecycle/pasteboard tests failed before injected stores and lifecycle wiring existed. Then `./Scripts/test.sh` — 42 tests across 6 suites passed in the working copy.
- Publication, pushes, installation and deletion of existing screenshots were not performed.
- Final-repository validation: `./Scripts/pipeline.sh` passed after review fixes: localization/version checks, **45 Swift tests in 6 suites**, release `build/Cyclop.app`, bundle resources/version, ad-hoc signing verification, Now Playing helper JSON. `python3 Scripts/test-pipeline.py`: **12/12 passed**. `git diff --check` passed. Existing Swift warning in `MediaController.swift:189` remains unrelated and unchanged.
- Final source/test hashes in the repository match the tested working copy. Earlier uncommitted CONTRIBUTING/pipeline files were verified unchanged.
- Independent review completed; all three findings were reproduced by failing tests and fixed; the final full suite passed.
- User feedback (2026-11-25): "Вроде бы работает". This is a preliminary manual report; the full paste/removal/restart matrix is not confirmed.
- Manual Cursor reproduction was **not performed by the implementation agent**. The built app was not launched or installed, and the production clipboard/screenshot directory were not altered. Keep the manual progress box unchecked until a person has completed the original scenario.
- To validate manually: quit the installed Cyclop, open the built `build/Cyclop.app`, open the Shelf once to index legacy cards, then perform the manual scenario above. Confirm duplicate rejection while the card remains, successful paste, reimport only on a new event after the last matching card is removed, and behavior across restart.

Complete this section after implementation.

Include:

- Summary of implemented changes.
- Modified and newly created source files.
- Selected fingerprint representation.
- Actual build and test commands.
- Automated test results.
- Manual validation results.
- Remaining limitations.
- Any deviations from the original ExecPlan.
- Recommended follow-up work, if necessary.

Do not mark manual tests as passed unless they were actually performed.

## 17. Definition of done

The implementation is complete when Cyclop automatically prevents duplicate clipboard image imports based on images currently present on the Shelf, without modifying the system clipboard or creating duplicate files.

An identical image becomes eligible for import again after its last matching Shelf item is removed.

All applicable existing tests and new automated regression tests must pass. The application must build successfully, and the original reproduction scenario must be manually verified before declaring the bug fully resolved.

Treat this ExecPlan as a living document. Update progress, discoveries, decisions, and outcomes throughout implementation.