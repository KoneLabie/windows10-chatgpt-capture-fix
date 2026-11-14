# Technical notes

The narrow target is a Windows 10 Computer Use screenshot failure with working window enumeration and accessibility text. The helper returns `FrameArrived timed out: timed out waiting on channel` or `window capture timed out: timed out waiting on channel` even for a responsive empty Notepad window.

## Change

The reviewed upstream approach replaces the frame callback entry with a short wrapper. The wrapper retains the callback object, gates processing with a once flag, starts a worker thread, closes the thread handle, and returns. The worker initializes WinRT in the multithreaded apartment, invokes the original callback body, uninitializes WinRT, and releases the retained object. The thread-creation failure path resets the flag and releases its reference.

The first exact candidate changes 552 byte values; the October 31 candidate changes 551. Each uses 13 guarded regions and preserves its original 1,551,152-byte file length. Each adds a readable/executable `.cuw10` section and two exception/unwind records, adjusts the callback routing, and clears the certificate directory. The original OpenAI signature therefore no longer applies.

The public upstream source lacks an exact profile for the tested original hash. This preparation adapts its `0.7.12-6FCC7C64` profile to the exact `0.7.13` input under a whole-file hash guard. Eleven region guards matched; the two differences were the checksum and certificate-overlay bytes. Similar version numbers or matching guards alone were not considered proof of compatibility. Whole-section equivalence with the older executable was not established.

## October 31 exact-build review

The updated signed original `49C7F43D...C98F45D` reproduced both timeout errors before repair. Two independent comparisons with the previously reviewed original `11825CB7...F5F8` found every one of its ten section headers and raw section contents identical. Imports, relocations, and unwind data also matched. All 9,236 differing byte values were confined to the COFF timestamp (3), PE checksum (3), and certificate overlay (9,230). Normalizing those three fields made the complete originals identical.

The thirteen region checks had the same outcomes as before. The resulting candidate `25A8CD31...10FAB` has eleven section contents identical to the previously tested candidate; the build timestamp and unused certificate-overlay remainder differ outside those sections. The builder pins this new full input/output pair and its 551-byte difference count separately. The controller rejects a manifest combining an original from one profile with the candidate from the other, and restores the original belonging to the selected profile. This is evidence for these two exact builds, not permission to reuse offsets for future files.

## November 14 rebuilt executable

The signed `0.7.18` original `F8AD259C...E81D9` is not a re-sign of the old layout. It has nine sections instead of ten, a different code body and import table, and a 1,548,592-byte file length. Twelve of the previous profile's thirteen guards fail. Even the newer pinned upstream `0.7.17-7F73CF56` profile matches only six unchanged guards; it cannot be applied verbatim.

Independent disassembly and structural review identified the callback at RVA `0x42544`, its vtable slot at raw offset `0x12BB00`, and the same interface GUIDs and AddRef contract. All 3,124 callback instruction shapes and internal branch destinations match the earlier reviewed callback after external address operands are normalized. This comparison does not establish the semantics of external callees.

The new mapping moves the busy and once branches to raw offsets `0x41979` and `0x4198A`, updates the worker's call to the current callback, and appends exception records at the actual table end `0x156878`. Reusing upstream's append offset would leave a gap. The new readable/executable section is at RVA `0x17C000`, raw `0x176400`; the four wrapper import destinations resolve to their intended current imports. A complete callback-body hash and branch destinations are checked in addition to full input/source/output hashes.

The exact candidate `7BCF0B19...7E804` changes 551 byte values across thirteen regions and preserves file length, imports, relocations, and the original exception-table prefix. Independent reconstruction produced the identical candidate. Each old profile continues to require its original pinned source; the new profile requires a separate pinned source and layout. Version labels never choose a profile.

## November 14 second runtime update

The signed `0.7.21` original `A1EB13F3...09DED` is 1,549,104 bytes. Compared with the preceding November build, `.rdata` grows by 640 virtual bytes and 512 raw bytes, and later file sections move by `0x200`. Only eight of the preceding layout's thirteen guards match. Its separately mapped vtable slot is raw `0x12BB48` (RVA `0x12CF48`); the exception-table append position is raw `0x156A78`; the wrapper remains at RVA `0x17C000` but moves to raw `0x176600`.

The callback remains at RVA `0x42544`. All 3,124 instruction shapes and internal branch destinations match the preceding reviewed callback. Its 184 differing bytes are confined to 99 LEA displacement operands; no call operand changes. Independent review classified the ten differing referenced data prefixes as source-location records, dependency registry path text, or padding. Interface GUIDs, AddRef/Release implementations, and callback unwind bytes match. These comparisons do not prove complete runtime semantics.

Candidate `210502D9...406ADF` changes 552 byte values across thirteen guarded regions. Its complete 512-byte worker region matches the preceding candidate. The build preserves all 314 imports, 2,437 relocations, and 2,826 original exception records, with two sorted new exception records. Independent reconstruction reproduced the full pinned candidate hash. This profile uses the November pinned source with its own layout and complete callback hash. The unused `@oai/cua` sibling is not a supported input even though its native sections match this original; helper routing and full-file identity are checked separately.

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
