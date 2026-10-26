---
name: setup
description: Set up, inspect, stop, or remove the Windows capture-update watcher for an explicitly authorized existing local Codex chat. Uses local filesystem events, not daily scheduled maintenance.
---

# Capture Update Watch setup

Use this workflow when the user asks to enable or manage the watcher. Read the plugin README and `scripts/Manage-CaptureWatch.ps1` before installation.

1. Confirm the intended existing local maintenance chat and repair repository from trusted user instructions. The destination UUID must come from the current root thread environment or the app's thread tools; never use a subagent's UUID. Do not create a separate chat unless requested.
2. Explain that enabling creates one current-user logon task and a hidden event watcher. It queues a maintenance request when installed runtime files change; it does not itself patch, execute downloaded code, or push Git commits. No daily timer is used.
3. Inspect existing watcher status. Preserve unrelated tasks, repository changes, and user configuration. Never overwrite a destination chat or repository choice without authorization.
4. Use the manager's explicit Install and Start actions with the selected thread UUID and repository path. Do not weaken execution policy, security settings, or permissions. If the host refuses registration or execution, report the exact blocker instead of bypassing it.
5. Verify the task's logon-only trigger, limited current-user principal, private configuration, and running owned watcher status. Perform a harmless queue delivery test only when authorized by the setup request; never fake an update against the real helper.
6. Explain that queued work may wait until the destination chat is loaded/resumed. Do not claim an unattended end-to-end repair was verified merely because a message was queued.

Use Status for read-only inspection. Stop halts this watcher. Uninstall removes only its owned startup task and retains local state for review. Disabling the plugin alone does not remove the independently registered watcher; tell the user to run Uninstall when removing it.

Use the normal shell tools for scripts, not terminal UI automation. Never expose private configuration, paths, logs, or thread identifiers in a public repository. No API key is required by the watcher; never request or extract credentials for it.
