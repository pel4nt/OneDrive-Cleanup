# Windows PowerShell 5.1. Run elevated for another user's profile/system cleanup.
# Downloads older than 60 days are permanently deleted, as in the original.
$TempDaysOld = 7
$DiagnosticDaysOld = 30

$Profiles = @(Get-ChildItem C:\Users -Directory |
    Where-Object {
        $_.Name -notin @(
            'Public',
            'Default',
            'Default User',
            'All Users',
            'defaultuser0'
        )
    })

Write-Host ""
Write-Host "Available Profiles:"
Write-Host ""

for ($i = 0; $i -lt $Profiles.Count; $i++) {
    Write-Host "$($i+1). $($Profiles[$i].Name)"
}

$Selection = Read-Host "Select profile number"

$SelectionNumber = 0
if (-not [int]::TryParse($Selection, [ref]$SelectionNumber) -or
    $SelectionNumber -lt 1 -or $SelectionNumber -gt $Profiles.Count) {
    throw 'Invalid profile selection.'
}
$UserName = $Profiles[$SelectionNumber - 1].Name
$UserProfile = "C:\Users\$UserName"

# ================= VARIABLES =================

$UserProfile = "C:\Users\$UserName"

if (!(Test-Path "C:\Temp")) {
    New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
}

$LogPath = "C:\Temp\OneDrive_FirstTouch_$UserName.log"
$DaysOld = 60

function Log {
    param([string]$Msg)

    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Msg"
    $Line | Out-File -FilePath $LogPath -Append -Encoding UTF8
    Write-Host $Line
}

Log "======================================================="
Log "First Touch Cleanup Started"
Log "Target User: $UserName"
Log "======================================================="

# ================= VERIFY PROFILE =================

if (-not (Test-Path $UserProfile)) {
    Log "ERROR: User profile not found: $UserProfile"
    exit 1
}

Log "User profile verified: $UserProfile"

# ================= DISK SPACE BEFORE =================

$FreeBefore = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
Log "Free space before cleanup: $FreeBefore GB"

# Enumerate without following junctions/symlinks or cloud reparse points.
function Get-CleanupFiles {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $Root = Get-Item -LiteralPath $Path -Force
    if ($Root.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Log "Skipped linked/cloud cleanup root: $Path"
        return
    }
    $Pending = New-Object 'System.Collections.Generic.Stack[string]'
    $Pending.Push($Path)
    while ($Pending.Count -gt 0) {
        $Directory = $Pending.Pop()
        $ReadErrors = @()
        $Items = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue -ErrorVariable ReadErrors)
        foreach ($ReadError in $ReadErrors) { Log "Enumeration skipped: $ReadError" }
        foreach ($Item in $Items) {
            if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($Item.PSIsContainer) { $Pending.Push($Item.FullName) }
            else { $Item }
        }
    }
}

function Remove-AgedFiles {
    param([string]$Path, [int]$AgeDays, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Log "$Label folder not found: $Path"
        return
    }
    $Cutoff = (Get-Date).AddDays(-$AgeDays)
    $Removed = 0
    $Failed = 0
    [long]$RemovedBytes = 0
    Get-CleanupFiles -Path $Path | Where-Object { $_.LastWriteTime -lt $Cutoff } | ForEach-Object {
        $File = $_
        try {
            Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop
            $Removed++
            $RemovedBytes += $File.Length
        }
        catch {
            $Failed++
            Log "Skipped/failed delete: $($File.FullName): $($_.Exception.Message)"
        }
    }
    Log "$Label : removed $Removed files; skipped/failed $Failed; deleted file lengths $([math]::Round($RemovedBytes / 1GB, 2)) GB"
}

Remove-AgedFiles -Path (Join-Path $UserProfile 'Downloads') -AgeDays $DaysOld -Label 'Downloads'
Remove-AgedFiles -Path (Join-Path $UserProfile 'AppData\Local\Temp') -AgeDays $TempDaysOld -Label 'User temp'
Remove-AgedFiles -Path (Join-Path $env:SystemRoot 'Temp') -AgeDays $TempDaysOld -Label 'Windows temp'
Remove-AgedFiles -Path (Join-Path $UserProfile 'AppData\Local\CrashDumps') -AgeDays $DiagnosticDaysOld -Label 'User crash dumps'
Remove-AgedFiles -Path (Join-Path $UserProfile 'AppData\Local\Microsoft\Windows\WER\ReportArchive') -AgeDays $DiagnosticDaysOld -Label 'User archived error reports'
Remove-AgedFiles -Path (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive') -AgeDays $DiagnosticDaysOld -Label 'System archived error reports'

# ================= RECYCLE BIN CLEANUP =================

if ($env:USERPROFILE.TrimEnd('\') -ieq $UserProfile.TrimEnd('\')) {
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Log 'Executing user recycle bin emptied.'
    }
    catch { Log "Recycle bin cleanup failed: $($_.Exception.Message)" }
}
else { Log 'Recycle bin skipped: selected profile differs from executing account. Empty it in the target user session.' }

# ================= ONEDRIVE ANALYSIS =================

$OneDriveRoots = Get-ChildItem $UserProfile -Directory -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -like "OneDrive*"
    }

if ($OneDriveRoots.Count -eq 0) {
    Log "No OneDrive roots found."
}
else {

    foreach ($Root in $OneDriveRoots) {

        Log ""
        Log "OneDrive Root: $($Root.FullName)"

        $Libraries = Get-ChildItem $Root.FullName -Directory -ErrorAction SilentlyContinue

        Log "Total synced folders: $($Libraries.Count)"

        foreach ($Lib in $Libraries) {

            $SizeBytes = (
                Get-ChildItem $Lib.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum
            ).Sum

            $SizeGB = [math]::Round(($SizeBytes / 1GB), 2)

            Log "Library: $($Lib.Name)"
            Log "Logical file size (includes online-only files; not allocated disk usage): $SizeGB GB"
        }

        # Largest folders

        Log ""
        Log "Top 20 Largest Folders"

        $FolderReport = foreach ($Folder in $Libraries) {

            $FolderSize = (
                Get-ChildItem $Folder.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum
            ).Sum

            [PSCustomObject]@{
                Folder = $Folder.Name
                SizeGB = [math]::Round(($FolderSize / 1GB), 2)
            }
        }

        $FolderReport |
            Sort-Object SizeGB -Descending |
            Select-Object -First 20 |
            ForEach-Object {

                Log "$($_.Folder) : $($_.SizeGB) GB"
            }
    }
}

# ================= RESTART ONEDRIVE =================
# Use an interactive, LIMITED token in the target user's signed-in session.
$Candidates = @(
    (Join-Path $UserProfile 'AppData\Local\Microsoft\OneDrive\OneDrive.exe'),
    (Join-Path $env:SystemDrive 'Program Files\Microsoft OneDrive\OneDrive.exe'),
    (Join-Path $env:SystemDrive 'Program Files (x86)\Microsoft OneDrive\OneDrive.exe')
)
$OneDriveExe = $Candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $OneDriveExe) { Log 'OneDrive executable not found in the three standard install locations.' }
else {
    Log "OneDrive executable: $OneDriveExe"
    $TaskName = 'OneDriveFirstTouch_' + [guid]::NewGuid().ToString('N')
    $Registered = $false
    try {
        $ProfileInfo = Get-CimInstance Win32_UserProfile -ErrorAction Stop |
            Where-Object { $_.LocalPath -ieq $UserProfile } | Select-Object -First 1
        if (-not $ProfileInfo -or -not $ProfileInfo.Loaded) {
            throw 'Target user profile is not loaded. Start OneDrive from Start in their signed-in session.'
        }
        $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $IsAdmin = (New-Object Security.Principal.WindowsPrincipal($Identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($Identity.User.Value -eq $ProfileInfo.SID -and -not $IsAdmin) {
            Start-Process -FilePath $OneDriveExe -ArgumentList '/shutdown' -Wait -ErrorAction Stop
            Start-Sleep -Seconds 3
            Start-Process -FilePath $OneDriveExe -ArgumentList '/background' -ErrorAction Stop
            Log 'OneDrive restart requested in the current user session.'
        }
        else {
            $QuotedExe = $OneDriveExe.Replace("'", "''")
            $Command = "Start-Process -FilePath '$QuotedExe' -ArgumentList '/shutdown' -Wait -ErrorAction Stop; Start-Sleep -Seconds 3; Start-Process -FilePath '$QuotedExe' -ArgumentList '/background' -ErrorAction Stop"
            $Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
            $Action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -EncodedCommand $Encoded"
            $Principal = New-ScheduledTaskPrincipal -UserId $ProfileInfo.SID -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $TaskName -Action $Action -Principal $Principal -ErrorAction Stop | Out-Null
            $Registered = $true
            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            Start-Sleep -Seconds 8
            $Info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
            Log "OneDrive restart task result: $($Info.LastTaskResult) (0 = command completed; sync health still needs verification)."
        }
    }
    catch {
        Log "Automatic OneDrive restart failed: $($_.Exception.Message)"
        Log "In the TARGET user's non-elevated PowerShell session run: & '$($OneDriveExe.Replace("'", "''"))' /shutdown; Start-Sleep -Seconds 3; & '$($OneDriveExe.Replace("'", "''"))' /background"
    }
    finally {
        if ($Registered) {
            try {
                $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
                if ($Task.State -ne 'Running') {
                    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
                }
                else { Log "Restart task still running; inspect/remove after completion: $TaskName" }
            }
            catch { Log "Task cleanup failed for $TaskName : $($_.Exception.Message)" }
        }
    }
}

# ================= FINAL SPACE REPORT =================

Start-Sleep -Seconds 3

$FreeAfter = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
$Recovered = [math]::Round(($FreeAfter - $FreeBefore), 2)

Log ""
Log "======================================================="
Log "Cleanup Completed"
Log "Free space before: $FreeBefore GB"
Log "Free space after : $FreeAfter GB"
Log "Space recovered  : $Recovered GB"
Log "Log saved to     : $LogPath"
Log "======================================================="

