# OneDriveCleanup

An interactive PowerShell tool for first-step troubleshooting of low disk space and OneDrive sync problems caused by insufficient local storage.

`FirstTouchDiskCleanup.ps1` cleans aged files for a selected Windows user profile, reports free space on C:, examines OneDrive folder sizes, and attempts to restart OneDrive in the selected user's session.

## Before running

**Downloads files older than 60 days are permanently deleted, including files in subfolders. There is no preview mode or additional deletion confirmation.** Review the user's needs and your organization's retention requirements before running.

File age is based on **LastWriteTime**, not when the file was downloaded or last opened. Cleanup skips reparse points (including junctions, symbolic links, and cloud placeholders), and logs inaccessible or locked files. Empty directories are left in place.

## Cleanup targets

| Target | Default age threshold |
| --- | --- |
| Selected user's Downloads | 60 days |
| Selected user's local Temp | 7 days |
| Windows Temp | 7 days |
| Selected user's CrashDumps | 30 days |
| User and system Windows Error Reporting archives | 30 days |
| Recycle Bin | No age filter; emptied only when the executing profile matches the selected profile |

The script logs deletion counts, failures, deleted file lengths, and before/after free space. Deleted file lengths can differ from actual storage reclaimed; the final free-space change also includes other disk activity during execution.

## Requirements

- Windows with Windows PowerShell 5.1.
- An interactive PowerShell window for selecting the target profile.
- Administrator or SYSTEM context for system cleanup and access to other users' profiles.
- The affected user signed in for the OneDrive restart attempt.
- An installed and configured OneDrive sync client for restart functionality.

The script currently assumes user profiles are under `C:\Users` and reports free space on C:.

## Run locally

Open Windows PowerShell as administrator:

```powershell
cd C:\Scripts\OneDriveCleanup
.\FirstTouchDiskCleanup.ps1
```

Enter the number corresponding to the affected user's profile. Keep that user signed in if you want to test the OneDrive restart.

If execution policy blocks the script and your organization's policy permits a session-only override:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\FirstTouchDiskCleanup.ps1
```

Running without elevation can perform permitted user cleanup, but system cleanup may report access denied.

## Run through Endpoint Central

The intended remote workflow uses Endpoint Central's **interactive remote PowerShell window**, rather than its script deployment section.

1. Place the script on the endpoint, for example at `C:\Scripts\OneDriveCleanup`.
2. Open the remote PowerShell window as **SYSTEM**.
3. Run the script and select the affected user's profile.
4. Review the space report and any cleanup or restart errors.
5. Verify OneDrive sync status with the user afterward.

Under SYSTEM, the selected user's Recycle Bin is skipped. Empty it separately in their session if appropriate. Because the script uses `Read-Host`, it is not currently suitable for unattended deployment.

## OneDrive restart

The script checks these locations:

- Selected profile: `AppData\Local\Microsoft\OneDrive\OneDrive.exe`
- System drive: `Program Files\Microsoft OneDrive\OneDrive.exe`
- System drive: `Program Files (x86)\Microsoft OneDrive\OneDrive.exe`

It requests shutdown and relaunch using `/shutdown` and `/background`; it does not perform `/reset`.

When running as the selected user without elevation, the script requests the restart directly. From an elevated or SYSTEM session, it creates a temporary scheduled task using the selected user's SID, interactive logon, and limited privileges. A loaded profile is checked, but does not by itself guarantee an available interactive session.

The task is removed if it is no longer running when checked. A still-running task or failed task removal is logged with its name for follow-up. Restart failures produce a fallback command to run in the affected user's non-elevated PowerShell session.

**A task result of 0 indicates command completion, not verified OneDrive sync health.** Confirm that OneDrive is running and syncing afterward.

## OneDrive size report and follow-up

The script searches immediate profile directories named `OneDrive*` and reports the logical sizes of their immediate subfolders, including a top-20 list. It does not verify that these directories are active sync roots; renamed old OneDrive folders can appear, and separately synced SharePoint libraries outside those paths can be missed.

These sizes include online-only files and are **not allocated local disk usage**. Large folder trees can take time to enumerate; the report scans each listed folder twice.

The script does not automatically make OneDrive files online-only. If more space is needed after cleanup, review Files On-Demand and **Free up space** with the user, allowing them to choose what must remain available offline.

## Configuration

Edit these variables in the script to change the age thresholds:

```powershell
$TempDaysOld = 7
$DiagnosticDaysOld = 30
$DaysOld = 60  # Downloads
```

To exclude Downloads deletion, remove or comment out the `Remove-AgedFiles` call labeled `Downloads`.

## Logs

Logs are appended to:

```text
C:\Temp\OneDrive_FirstTouch_<UserName>.log
```

Logs contain usernames, local paths, and error details. Review and redact them before sharing publicly. Log rotation is not implemented.

## Validation status

User temp and Downloads cleanup have been observed working during a workstation test. System cleanup and the OneDrive restart from Endpoint Central's SYSTEM session still require end-to-end validation.

Cleanup errors are generally logged and execution continues. The final `Cleanup Completed` message does not mean every operation succeeded; review individual results.
