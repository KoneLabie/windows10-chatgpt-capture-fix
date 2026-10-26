# Technical notes

The narrow target is a Windows 10 Computer Use screenshot failure with working window enumeration and accessibility text. The helper returns `FrameArrived timed out: timed out waiting on channel` or `window capture timed out: timed out waiting on channel` even for a responsive empty Notepad window.

## Change

The reviewed upstream approach replaces the frame callback entry with a short wrapper. The wrapper retains the callback object, gates processing with a once flag, starts a worker thread, closes the thread handle, and returns. The worker initializes WinRT in the multithreaded apartment, invokes the original callback body, uninitializes WinRT, and releases the retained object. The thread-creation failure path resets the flag and releases its reference.

The exact candidate changes 552 byte values across 13 guarded regions while preserving the original 1,551,152-byte file length. It adds a readable/executable `.cuw10` section and two exception/unwind records, adjusts the callback routing, and clears the certificate directory. The original OpenAI signature therefore no longer applies.

The public upstream source lacks an exact profile for the tested original hash. This preparation adapts its `0.7.12-6FCC7C64` profile to the exact `0.7.13` input under a whole-file hash guard. Eleven region guards matched; the two differences were the checksum and certificate-overlay bytes. Similar version numbers or matching guards alone were not considered proof of compatibility. Whole-section equivalence with the older executable was not established.

## Static checks

- Entire original input and upstream text hashes are pinned before parsing or modification.
- Entire output hash is pinned before writing a candidate.
- Region bounds, equal replacement lengths, and overlap checks.
- PE32+ x64 identity, section count/layout, executable/read-only section flags, and image extent.
- Callback vtable target and its existing DIR64 relocation for ASLR.
- Worker import destinations: `CreateThread`, `CloseHandle`, `RoInitialize`, and `RoUninitialize`.
- Original callback destination and sorted exception records with matching unwind data.
- No changes outside the intended regions.

No new network, privilege, or startup-persistence behavior is introduced by the added wrapper. This statement concerns that small reviewed modification, not a general audit of the entire proprietary executable.

## Remaining uncertainty

Successful short tests do not establish correctness of object lifetime, cancellation, capture-session teardown, repeated failures, or long-running concurrency. In particular, the worker's WinRT initialization result handling and interactions with the original callback's lifetime assumptions merit deeper source-level investigation. A supported source-level fix is preferable to a binary adaptation.

Do not extend the profile to another file just because it reports the same library version. Any new target requires its own evidence, review, and tests.
