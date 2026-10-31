# Windows 10 ChatGPT / Codex capture fix

An **experimental, exact-build workaround** for Computer Use screenshots that fail on Windows 10 with:

```text
FrameArrived timed out: timed out waiting on channel
window capture timed out: timed out waiting on channel
```

On the tested machine, window discovery and accessibility text worked while screenshots of a fresh, responsive Notepad window repeatedly timed out. The repair restored three visibly verified screenshot requests and mouse/keyboard interaction. All three monitors remained connected.

This is a community experiment, **not an official OpenAI update**. It changes a native helper and removes its embedded signature. It may crash or hang the helper; app updates may overwrite it. No Windows security policy is disabled. If security software or execution policy blocks it, stop rather than weaken that protection.

## Supported target

Only the two exact original executables below are supported. A matching product version alone is insufficient. The builder selects the profile by the complete original SHA-256; the controller requires its matching original/candidate pair, including for rollback.

| Item | Tested value |
| --- | --- |
| OS | Windows 10 22H2, build 19045, x64 |
| Computer Use library | `@oai/sky` 0.7.13 |
| Helper | `codex-computer-use.exe` |

| Tested app package | Original SHA-256 | Repaired SHA-256 |
| --- | --- | --- |
| `26.1021.3705.0` | `11825CB78575D9099AED8F13D16F78B03C20A1A0EBC809CF78B406FB2F25F5F8` | `1071E8CC945EDDFC466637CF096852E670D21AFA396FE7CCA70B107C3DE3EFC5` |
| `26.1027.3384.0` | `49C7F43DA0C2A9DBCADFB0C993058147018BF7C1D0FDE4360DE11ACE2C98F45D` | `25A8CD31B5BC44C387CBF53EC3FE4CD314B5FCAC0D8D84201F444F1B2DB10FAB` |

Both profiles passed a live screenshot/menu/keyboard trial after the original helper reproduced the capture timeouts. The October 31 profile preserves the earlier profile and its recovery path. See the [validation record](docs/validation.md) for the exact scope.

The tools reject unknown input/output hashes. They do not search for a similar version, patch every runtime, change BIOS/graphics settings, or install a driver. This is not a general fix for PC freezes, GPU resets, or every screenshot timeout.

## What is included

- `scripts/prepare.py`: reads the exact original and separately obtained upstream patch text as data, validates the PE changes, and builds an inert candidate in a staging folder.
- `scripts/repair.ps1`: status, bounded trial with rollback, explicit acceptance, and later restoration.
- `tests/`: tests of the preparation and controller safeguards.
- [Technical explanation](docs/technical-notes.md), [test evidence](docs/validation.md), and [source attribution](THIRD_PARTY_NOTICES.md).

No OpenAI executable, patched executable, downloaded upstream script, personal event logs, or screenshots are distributed here. Preparation never executes the downloaded text or the helper.

## Prepare a candidate

Prerequisites: Python 3.9 or newer, PowerShell, the supported installed helper, and permission to modify that installation. Review the source and limitations before proceeding. Close other Computer Use sessions before a live trial.

1. Clone this repository, then open PowerShell in its folder.
2. Identify the **active** Computer Use helper path. It normally has this form:

   ```text
   %LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\<runtime-id>\bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe
   ```

   Do not choose an arbitrary runtime if several exist. The preparation step requires the original, unmodified file. A previously patched installation should not be patched again.

3. Save the pinned [upstream patch source](https://raw.githubusercontent.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/14b418f71b3cd56b3c1cca41db5933dfbc30fbd1/scripts/patch-computer-use-helper-win10.ps1) as a local text file **without running it**. Its required SHA-256 is:

   ```text
   8F961A6AB639F1E9FB2BE91F7F2F429F07CF9A68E80FCECD3654B525C60450D1
   ```

   The builder reads only the pinned byte records and does not evaluate PowerShell. Upstream code is obtained separately because no license file was found at the pinned commit; this repository's license does not cover it.

4. Run preparation with explicit paths. Replace the placeholder values; select a new staging folder outside the repository and the installed runtime:

   ```powershell
   py -3 .\scripts\prepare.py --helper 'C:\path\to\codex-computer-use.exe' --patch-source 'C:\path\to\upstream-patch.txt' --output-dir 'C:\path\to\capture-repair-stage'
   ```

   Successful preparation creates `original.bin`, `candidate.bin`, and `manifest.json`. It does not install or launch either binary. Keep the staging folder private: its manifest contains your local path, and its files include your original executable.

## Trial and verify

Use the actual staging folder in every command. Read-only status:

```powershell
.\scripts\repair.ps1 -Action Status -StagingDirectory 'C:\path\to\capture-repair-stage'
```

In the first PowerShell window, start the trial:

```powershell
.\scripts\repair.ps1 -Action Trial -StagingDirectory 'C:\path\to\capture-repair-stage'
```

Leave this controller running. It verifies the original hash/signature, replaces only the selected helper, and stops only helper processes whose path matches that file. The main ChatGPT app remains open. The trial automatically attempts restoration after 180 seconds unless accepted. **Automatic rollback depends on the controller staying alive**; it cannot protect against a power loss or a forcibly terminated controller.

Start a fresh Computer Use session through the normal app interface, then within the trial window:

1. Capture a harmless application window that failed before, such as an empty Notepad.
2. Inspect the actual image. Text-only accessibility output or a success message is not sufficient.
3. Click a menu, capture again, and check that the image shows the opened menu.
4. Dismiss the menu with Escape and capture again to confirm keyboard input and a fresh image.

If these checks pass, explicitly retain it **from a second PowerShell window**:

```powershell
.\scripts\repair.ps1 -Action Keep -Verified -StagingDirectory 'C:\path\to\capture-repair-stage'
```

`-Verified` is your assertion that you inspected successful screenshots and input. The script cannot verify image correctness for you. Confirm that the first controller reports that it retained the trial.

If capture fails, restore immediately, or leave the first controller running until its deadline:

```powershell
.\scripts\repair.ps1 -Action Rollback -StagingDirectory 'C:\path\to\capture-repair-stage'
```

## Restore later

The same `Rollback` command restores the verified original. It refuses to overwrite an unknown helper, including a newer app update. If it refuses, investigate the changed version rather than bypass the check. Retain `original.bin`, `manifest.json`, and this controller until you no longer need rollback.

The preparation and repair scripts install no automatic reapplication, scheduled task, service, or update blocker. The separately enabled optional watcher has its own logon task. Prefer a supported vendor fix when available. Do not submit private logs or executable backups in public issues.

The controller leaves its status and trial signals in the staging folder. A per-helper lock file and uniquely named atomic `.backup.bin` copies remain beside the helper; they are local recovery artifacts, not files to publish.

## Evidence and limits

Independent Windows Graphics Capture diagnostics could acquire a frame and convert it outside the `FrameArrived` callback while the original helper still timed out. Moving callback work to an MTA worker restored the tested window captures. That supports a helper callback/threading issue; it does not directly prove the original deadlock.

The successful test covered one window and its transient menu on one Windows 10 system. It did **not** establish combined all-monitor capture, each monitor separately, all applications, reboot persistence, timeout/cancellation correctness, or prolonged stability. See [validation](docs/validation.md).

## Optional update watcher

For event-driven maintenance after installed runtime updates, see the optional [Capture Update Watch plugin](plugins/capture-update-watch/README.md). It queues work to an existing chat without a daily schedule; the watcher never patches a helper itself.

## Development checks

```powershell
py -3 -m unittest discover -s tests -p 'test_*.py' -v
.\tests\test_controller.ps1
```

These tests do not reproduce a real GPU capture environment. No live installation should be modified as part of a packaging or CI test.

Original tooling and documentation are under the [MIT license](LICENSE). Third-party code and vendor executables retain their respective rights; see [notices](THIRD_PARTY_NOTICES.md).
