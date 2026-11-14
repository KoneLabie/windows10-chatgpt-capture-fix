# Validation record

Test dates: October 26, October 31, and November 14, 2026. This record is intentionally limited to capture-related observations; personal event logs and machine identifiers are not included.

## Before the repair

- Windows 10 22H2 x64, build 19045.7807; three connected physical monitors.
- Original helper SHA-256: `11825CB78575D9099AED8F13D16F78B03C20A1A0EBC809CF78B406FB2F25F5F8`.
- Original signature was valid for OpenAI OpCo, LLC.
- A fresh, responsive blank Notepad repeatedly failed screenshots with the two timeout messages in the README.
- Accessibility text and window discovery worked.
- Temporarily disabling a virtual display adapter did not restore capture; it was restored afterward. That test did not remove driver packages/services or rule out every persistent driver interaction.
- Independent locally compiled Windows Graphics Capture diagnostics acquired a hardware-backed frame. A separate diagnostic converted a frame surface outside the callback in 28 ms. No diagnostic image pixels were saved or exported.
- The original Computer Use helper still failed on the same target.

## Original live trial

The exact candidate was installed after explicit approval with an original backup and a three-minute rollback controller.

1. The normal Computer Use interface returned a visually inspected Notepad screenshot.
2. A coordinate mouse click opened Format; accessibility state and the next screenshot showed the menu.
3. Escape dismissed the menu; accessibility state and another screenshot showed the change.

Three screenshot requests passed, including transient menu regions. The trial was explicitly retained after those checks. An independent read-only check confirmed the candidate hash, intact original backup, responsive helper processes, and no System/Application warning, error, or critical events during the short interval checked. Absence of event-log errors is supporting evidence, not proof of correctness.

No BIOS, monitor-layout, refresh-rate, driver, or tuning adjustment was needed. The new helper was unsigned as disclosed. No Windows security policy was disabled.

## Original trial scope

This establishes bounded window-capture and input success on one machine. It does not validate combined desktop capture, every monitor separately, every app, reboot persistence, prolonged use, resource leaks, timeout/cancellation behavior, or crash recovery.

## Public-tool packaging

The portable public scripts preserve the same exact original/candidate hashes. Packaging tests use inert local copies and temporary directories, not the working installation. The generalized controller is distinct from the original hard-coded trial controller; copy-based tests and syntax checks do not establish every live Windows failure scenario.

The public repository intentionally contains no executable fixtures. Running unit tests alone cannot demonstrate GPU capture success. Users must perform the visible acceptance checks during their own bounded trial.

## October 31 update and live trial

The installed app was `OpenAI.Codex` 26.1027.3384.0 with `@oai/sky` 0.7.13 on Windows 10 build 19045. The active original was signed by OpenAI and had SHA-256 `49C7F43DA0C2A9DBCADFB0C993058147018BF7C1D0FDE4360DE11ACE2C98F45D`. Older queued update notifications were reconciled against this live state; their filenames were not used as installation targets.

A newly opened blank Notepad returned accessibility text, but its screenshot failed with `FrameArrived timed out: timed out waiting on channel`. After refreshing the target, one retry failed with `window capture timed out: timed out waiting on channel`. That established the failure before any repair.

After exact-build analysis, static checks, a backup of the current signed original, and explicit approval, the new candidate `25A8CD31B5BC44C387CBF53EC3FE4CD314B5FCAC0D8D84201F444F1B2DB10FAB` was installed through a 180-second rollback controller. A fresh supported Computer Use connection passed three visually inspected screenshot requests: blank Notepad, its Format menu opened by a coordinate mouse click, and the menu dismissed with Escape. The controller accepted `Keep -Verified` and exited successfully with `KeptVerifiedExperimentalTrial`.

The new helper is unsigned. The current signed original remains backed up for rollback. No BIOS, driver, display-configuration, or security-policy changes were made. The trial used the private exact-build controller; the public multi-profile extension is checked separately on inert files and by reproducing the exact candidate hashes. No failed-trial live rollback was induced, and the scope limitations above still apply.

The public extension passed 13 Python guard tests and inert controller tests under Windows PowerShell 5.1 and PowerShell 7.6. Preparing both private original files through the public builder reproduced their full pinned candidate hashes, with all structural checks enabled. The watcher passed 53 assertions under its target Windows PowerShell 5.1 runtime. No vendor binaries or private fixtures are included in the repository.

## November 14 update and live trial

The current installation was `OpenAI.Codex` 26.1106.6628.0 with `@oai/sky` 0.7.18 on Windows 10 build 19045. Its active original helper, SHA-256 `F8AD259CAA82BC2A62C26CB1A3428E558D26959DE7B4D5BCE0D708F5C40E81D9`, was validly signed by OpenAI. Two actual screenshot requests against a newly opened blank Notepad failed with `window capture timed out: timed out waiting on channel`, while accessibility text worked.

This executable was materially rebuilt: twelve of the previous layout's thirteen region guards failed. A separate exact-build mapping was prepared and independently reviewed before human approval. After approval, the 180-second controller installed candidate `7BCF0B19481A96F478760A345B389AE47C44D6E2A6F745B331B9043CD9F7E804`. Actual images showed the test editor, newly typed text, its Format menu opened by a coordinate click, and the menu dismissed with Escape. `Keep -Verified` completed with `KeptVerifiedExperimentalTrial`. The signed original remains backed up.

The trial and subsequent verification made nineteen screenshot requests with no capture timeouts. The first returned occluding content rather than the intended Notepad pixels; raising the target corrected that, and the remaining requests showed the intended window or its transient UI. Some accessibility text lagged newly typed text by one observation; actual screenshots showed the new text, and the next accessibility refresh caught up. These observations do not establish perfect occlusion handling or accessibility synchronization.

The disposable window was tested on the primary landscape monitor, the right landscape monitor, and the left portrait monitor. Screenshot-region origins confirmed placements at `(784, 280)`, `(2324, 280)`, `(-866, 280)`, and `(-866, -325)`, with a 629-by-697 window. Fresh text and screenshot-based menu clicks worked on each monitor, including negative X/Y coordinates. Only the test window moved; monitor configuration was unchanged. It was returned to its original location.

After stopping only processes matching the exact patched helper path, a fresh supported Computer Use connection again captured the window, displayed new typed text, and opened a menu with a coordinate click. The disposable document was closed without saving. This verifies a helper restart, not a Windows reboot. The tested Windows interface exposes window/transient captures; no combined image of the entire multi-monitor desktop was tested.

The public extension passed fifteen Python tests and inert controller tests under Windows PowerShell 5.1 and PowerShell 7.6. All three preserved original backups reproduced their complete pinned candidate hashes through the public builder; wrong sources and crossed hash pairs were rejected. The updated event watcher passed seventy-one assertions under Windows PowerShell 5.1, including the new profile's different file size, reverse updates, and unknown builds. Manager ownership fixtures also passed.

The candidate remains an unsupported unsigned modification. No failed-trial live rollback, prolonged stability, complete external-callee semantics, cancellation, or object-lifetime correctness was established. Automatic rollback needs a living controller, and its lease does not exclude a concurrent vendor updater. No BIOS, driver, display-configuration, or security-policy changes were made.

Plugin 0.1.4 was installed and enabled. The owned watcher was refreshed and restarted with the same destination, repository, and installation identity. Reviewed source, plugin cache, installed script, and configuration hashes matched. Its task remained a single limited, interactive current-user logon trigger without repetition; startup reconciliation reported unchanged state. An earlier version may already have queued a notification for the repair, which upgrading cannot retract.

## November 14 second update: sky 0.7.21

A later update installed `OpenAI.Codex` 26.1111.2228.0 with `@oai/sky` 0.7.21. The active original helper was validly signed by OpenAI, measured 1,549,104 bytes, and had SHA-256 `A1EB13F38DC0214AE56D5C8B676B3740054A0818AB2BB68801B7AEDC85909DED`. The supported Computer Use connection selected this sky helper; an inactive `@oai/cua` sibling and an older cached sky helper were left unchanged.

Before repair, a fresh, raised blank Notepad returned accessibility text but failed an actual capture with `FrameArrived timed out: timed out waiting on channel`. After refreshing discovery and rebinding the target, a second request failed with `window capture timed out: timed out waiting on channel`. The previously published builder rejected the new full hash without creating an output directory.

This build received its own layout analysis, independent review, exact candidate, isolated tests, and explicit human approval. The approved 180-second trial installed candidate `210502D9B2FD64F66613DDDD79BFA6942EB3CBC5472C10387AB72B9279406ADF`. Four trial screenshots visibly showed the blank editor, newly typed text, a mouse-opened Format menu, and the menu dismissed with Escape. The controller accepted `Keep -Verified` at 14:11:39 UTC and exited successfully with `KeptVerifiedExperimentalTrial`. The signed original remains backed up.

Extended verification placed the disposable 629-by-697 window on the primary monitor at `(784, 280)`, the right monitor at `(2324, 280)`, and the portrait monitor at `(-866, -325)`. Actual screenshots showed fresh typed text on both secondary monitors and captured menu regions at negative coordinates. Only the test window moved. It was returned to its original position before restarting only the exact-path helper processes.

A fresh supported Computer Use connection after that helper restart returned the window image, new typed text, and a menu opened with a coordinate click. The disposable document was closed without saving. No capture request timed out after this repair. Some accessibility snapshots lagged fresh pixels; one typing attempt while a menu still held focus required refocusing the editor before input appeared. A cleanup accessibility click reported an unavailable cached element; a fresh screenshot and coordinate click closed the document successfully. Transient menu/dialog images sometimes captured the opening animation before a later image showed the settled UI. These are observed interface limitations, not evidence that every input path is flawless.

The private candidate passed seventeen Python checks. The public extension passed fifteen Python tests and inert controller tests under Windows PowerShell 5.1 and PowerShell 7.6. All four retained original backups reproduced their exact expected candidates through the public builder. All twelve crossed original/candidate pairs and both inactive helper hashes were rejected. The watcher passed ninety-three assertions under Windows PowerShell 5.1; manager ownership fixtures also passed. An independent integration review found no blocking issue.

Plugin 0.1.5 was installed and enabled, and the owned watcher was refreshed and restarted. Its source, cache, installed script, and configuration hashes matched. The destination chat, repository, and installation identity were preserved. The current signed vendor CLI was selected, the task remained a single limited interactive logon trigger without repetition, and startup reconciliation reported unchanged state. An earlier watcher version had already processed the repair's filesystem change; upgrading does not retract queued messages. No fake update or delivery test was induced.

This verifies window and transient UI capture across three monitors and after a helper restart. It does not verify a combined all-monitor desktop image, a Windows reboot, all applications, prolonged stability, or complete cancellation/lifetime behavior. No failed-trial live rollback was induced. The unsigned modification and controller/updater limitations above still apply. No BIOS, driver, display-configuration, or security-policy changes were made.
