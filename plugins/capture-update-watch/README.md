# Capture Update Watch

A local Codex plugin and Windows event watcher for the capture workaround in this repository. It queues maintenance to an existing, explicitly selected chat when the installed Computer Use runtime changes. **There is no daily maintenance schedule.**

The watcher does not patch executables or upload code. The receiving chat follows the guarded maintenance workflow: test capture first, use only approved exact-build repairs, and ask before installing a new experimental candidate when required by the user's instructions.

## How it works

- Windows filesystem notifications detect relevant installed helper/runtime changes.
- A short debounce/stability check combines update bursts. This is a response to a change event, not a recurring maintenance timer.
- Private local state deduplicates notifications. The first run establishes a baseline without queuing maintenance.
- Both reviewed original-to-repaired hash pairs are recognized, so applying a known repair with an unchanged package and helper path does not itself queue another maintenance request. Restoring an original or seeing an unknown hash still triggers investigation.
- A startup reconciliation detects changes missed while the watcher was stopped.
- `codex queue --thread <existing-chat-UUID> --message <maintenance-request>` stores the request in the chosen chat.
- A current-user, limited-privilege logon task starts the hidden watcher after sign-in.

Codex may process the request when the destination chat is loaded; an unloaded chat can wait until it is resumed. Queue acceptance is not a guarantee of immediate model execution. This does not monitor every new public release on the internet. It watches the local installed runtime that can replace the repaired helper.

## Install the plugin

From a clone of this repository, register its local marketplace and install the plugin with the existing Codex CLI:

```powershell
codex plugin marketplace add . --json
codex plugin add capture-update-watch@capture-fix-local --json
```

The plugin is a local package, not a listing in the official public plugin directory. It contains skills and scripts; it does not use lifecycle hooks, scrape private app endpoints, extract credentials, install a network service, or bypass hook trust. Installing the package alone does not start monitoring. Run its setup workflow or the explicit manager commands below.

## Enable the watcher

Select the existing local maintenance chat UUID and the repair repository path. Do not copy an unrelated chat's identifier. Run the manager in **built-in Windows PowerShell 5.1 (`powershell.exe`)**, because the Windows ScheduledTasks module may not be available in PowerShell 7 (`pwsh`):

```powershell
.\plugins\capture-update-watch\scripts\Manage-CaptureWatch.ps1 -Action Install -ThreadId '<existing-chat-UUID>' -RepositoryPath 'C:\path\to\windows10-chatgpt-capture-fix'
.\plugins\capture-update-watch\scripts\Manage-CaptureWatch.ps1 -Action Start
.\plugins\capture-update-watch\scripts\Manage-CaptureWatch.ps1 -Action Status
```

Keep the checkout available for review and future source maintenance. The watcher/configuration/state are installed privately under the current user's local application-data folder. Review the manager's status before enabling an existing configuration. Unknown task/config collisions must be resolved manually rather than overwritten.

This creates a logon startup task, not a daily trigger. It runs without elevation and without an execution-policy override. If Windows blocks task registration or script execution, stop and inspect the error; do not disable protections to force it through.

## Stop or remove

```powershell
.\plugins\capture-update-watch\scripts\Manage-CaptureWatch.ps1 -Action Stop
.\plugins\capture-update-watch\scripts\Manage-CaptureWatch.ps1 -Action Uninstall
```

Stop disables the owned startup task as well as stopping the watcher; Start enables it again. Uninstall removes only the owned startup task and disables the watcher. Local configuration/state are retained for inspection. Neither operation cancels a maintenance message already queued or an in-flight queue submission. Removing the Codex plugin alone does not remove the separately registered Windows startup task; use the manager's Uninstall action as well.

## Privacy and limits

The selected chat receives a short maintenance request with relevant version/hash evidence. Local watcher configuration includes a private thread identifier and filesystem paths; do not commit it. There is no telemetry upload, GitHub push, or downloaded-code execution in the watcher.

Filesystem notifications can be missed while stopped or during installation. Startup reconciliation reduces that gap. A Store package-version change that does not produce a watched runtime/CLI file event is discovered at the next reconciliation, rather than necessarily at install time. The watcher must not label a partially written helper as a verified repair, and it cannot establish capture correctness itself. The maintenance chat must inspect real screenshots before retaining any patch.

The portable watcher, task manager, queue delivery, and capture repair are separate layers. Test each before claiming unattended operation. The test suite uses inert files and controlled dispatch substitutes; it never changes a live helper.

## Validation

On Windows 10 with Windows PowerShell 5.1, the watcher passed 53 assertions covering change deduplication, both known repairs followed by original-helper overwrites, crossed/unknown hash rejection, package/path/size changes, ambiguous-delivery handling, a native filesystem event on inert files, real argument round trips, and bounded child-process timeout. The manager's inert tests cover task ownership, account-to-SID resolution, unsafe arguments, unrelated/elevated/repeating-task refusal, and recycled process identifiers. The watcher suite's console executable fixture uses Windows PowerShell 5.1; an optional PowerShell 7 run cannot compile that existing fixture.

Local activation on October 26, 2026 confirmed plugin version 0.1.2 installed/enabled, one limited current-user logon task, a running owned watcher, and a baseline containing the already repaired helper hash. Stop disabled the task and halted the watcher; Start restored monitoring. The source and installed watcher hashes matched. A harmless real `codex queue` self-test was accepted and subsequently arrived in the selected chat. No real app update or automatic repair was induced during setup.

On October 31, actual queued update requests reached the existing maintenance chat. Some described older intermediate runtimes, so current installed state was checked before action. The unfamiliar active build required fresh analysis and explicit approval; its subsequent bounded screenshot/input trial passed. This validates update delivery and approved maintenance in a resumed chat, not immediate unattended execution. Messages already queued by an earlier watcher version cannot be retracted by upgrading it.

Plugin version 0.1.3 was installed after that trial. The owned watcher was stopped, updated, and restarted; the same destination and checkout were preserved. Its installed source hash matched the reviewed source, the task was running, and startup reconciliation reported unchanged state for the retained repaired helper.

Run the tests from the repository root in Windows PowerShell 5.1:

```powershell
.\tests\test_watcher.ps1
.\plugins\capture-update-watch\tests\test_manager.ps1
```

## References

- [Codex queue command](https://learn.chatgpt.com/docs/cli/reference#codex-queue)
- [Plugin packaging and local marketplaces](https://developers.openai.com/plugins/build/plugins)
- [MCP Events availability](https://developers.openai.com/plugins/build/mcp-events)

This package uses a local watcher plus the documented CLI queue, not a claim that local Codex supports cloud MCP event subscriptions.
