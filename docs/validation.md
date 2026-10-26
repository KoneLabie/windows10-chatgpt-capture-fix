# Validation record

Test date: October 26, 2026. This record is intentionally limited to capture-related observations; personal event logs and machine identifiers are not included.

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

## Scope

This establishes bounded window-capture and input success on one machine. It does not validate combined desktop capture, every monitor separately, every app, reboot persistence, prolonged use, resource leaks, timeout/cancellation behavior, or crash recovery.

## Public-tool packaging

The portable public scripts preserve the same exact original/candidate hashes. Packaging tests use inert local copies and temporary directories, not the working installation. The generalized controller is distinct from the original hard-coded trial controller; copy-based tests and syntax checks do not establish every live Windows failure scenario.

The public repository intentionally contains no executable fixtures. Running unit tests alone cannot demonstrate GPU capture success. Users must perform the visible acceptance checks during their own bounded trial.
