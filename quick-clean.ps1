<#
    Quick Clean - desktop context menu cleanup.

    -Mode Bin      Recycle bin only, after a confirmation prompt.
    -Mode Caches   Browser caches and package manager caches. With -ProjectRoot,
                   also the Rust build output (target) of projects under it.
    -Mode Temp     Temp files older than $TempAgeDays, user and system temp.
    -ProjectRoot   Folders to search for Rust projects, separated by ';'.
    -DryRun        Report what would be deleted, delete nothing.

    Launched from the desktop right-click menu that install.ps1 registers.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Bin', 'Caches', 'Temp')]
    [string]$Mode,

    [string]$ProjectRoot,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$TempAgeDays = 14

$script:lines = New-Object System.Collections.Generic.List[string]
$script:freed = [long]0

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-DirSize([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [long]0 }
    return [long]$sum
}

function Add-Result([string]$Label, [long]$Bytes) {
    $script:freed += $Bytes
    $script:lines.Add("$Label $(Format-Size $Bytes)")
}

function Add-Note([string]$Text) {
    $script:lines.Add($Text)
}

function Show-Toast([string]$Title, [string]$Line1, [string]$Line2) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null

        $t = [System.Security.SecurityElement]::Escape($Title)
        $a = [System.Security.SecurityElement]::Escape($Line1)

        $body = '<toast><visual><binding template="ToastGeneric">'
        $body += "<text>$t</text><text>$a</text>"
        if ($Line2) {
            $b = [System.Security.SecurityElement]::Escape($Line2)
            $body += "<text>$b</text>"
        }
        $body += '</binding></visual></toast>'

        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($body)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        # A failed notification must never fail the cleanup that already happened.
        Write-Verbose "Toast failed: $_"
    }
}

function Clear-Bin {
    $items = @((New-Object -ComObject Shell.Application).NameSpace(0xA).Items())
    if ($items.Count -eq 0) {
        Add-Note 'Recycle bin already empty'
        return
    }

    $size = [long](($items | Measure-Object -Property Size -Sum).Sum)
    $nl = [Environment]::NewLine
    $prompt = "Permanently delete $($items.Count) item(s) from the Recycle Bin?$nl$nl" +
              "This frees $(Format-Size $size) and cannot be undone."

    $answer = [System.Windows.Forms.MessageBox]::Show(
        $prompt,
        'Quick Clean',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        Add-Note 'Recycle bin kept'
        return
    }

    if ($DryRun) {
        Add-Result 'Recycle bin' $size
        return
    }

    try {
        Clear-RecycleBin -Force -Confirm:$false -ErrorAction Stop
        Add-Result 'Recycle bin' $size
    } catch {
        Add-Note 'Recycle bin failed'
    }
}

function Get-ChromiumCacheDir([string]$UserData) {
    Get-ChildItem -LiteralPath $UserData -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
        ForEach-Object {
            foreach ($sub in 'Cache', 'Code Cache', 'GPUCache') { Join-Path $_.FullName $sub }
        }
}

function Get-GeckoCacheDir([string]$ProfilesRoot) {
    Get-ChildItem -LiteralPath $ProfilesRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'cache2' }
}

function Clear-BrowserCache([string]$Label, [string]$Process, [string[]]$Paths) {
    $before = [long]0
    foreach ($path in $Paths) { $before += Get-DirSize $path }
    if ($before -eq 0) { return }

    if (Get-Process -Name $Process -ErrorAction SilentlyContinue) {
        Add-Note "$Label skipped (running)"
        return
    }

    if ($DryRun) {
        Add-Result $Label $before
        return
    }

    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $after = [long]0
    foreach ($path in $Paths) { $after += Get-DirSize $path }
    Add-Result $Label ($before - $after)
}

function Clear-ToolCache([string]$Label, [string]$Exe, [string[]]$Arguments, [string]$SizePath) {
    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { return }

    $before = Get-DirSize $SizePath
    if ($before -eq 0) { return }

    if ($DryRun) {
        Add-Result $Label $before
        return
    }

    try {
        & $Exe @Arguments 2>&1 | Out-Null
    } catch {
        Add-Note "$Label failed"
        return
    }

    Add-Result $Label ($before - (Get-DirSize $SizePath))
}

function Clear-CargoTarball {
    # Only the downloaded .crate tarballs, which cargo refetches on demand.
    # registry\src is left alone so existing builds keep working.
    $path = Join-Path $env:USERPROFILE '.cargo\registry\cache'
    $before = Get-DirSize $path
    if ($before -eq 0) { return }

    if ($DryRun) {
        Add-Result 'cargo tarballs' $before
        return
    }

    Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }

    Add-Result 'cargo tarballs' ($before - (Get-DirSize $path))
}

function Remove-OldTempFile([string]$Label, [string]$Root, [int]$Days) {
    if (-not (Test-Path -LiteralPath $Root)) { return }

    $cutoff = (Get-Date).AddDays(-$Days)
    $candidates = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $cutoff })

    if ($candidates.Count -eq 0) {
        Add-Note "$Label has nothing older than $Days days"
        return
    }

    $size = [long](($candidates | Measure-Object -Property Length -Sum).Sum)

    if ($DryRun) {
        Add-Result "$Label ($($candidates.Count) files)" $size
        return
    }

    $locked = 0
    $reclaimed = [long]0
    foreach ($file in $candidates) {
        $bytes = $file.Length
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $reclaimed += $bytes
        } catch {
            $locked++
        }
    }

    # Directories left empty by the deletions above, deepest paths first.
    Get-ChildItem -LiteralPath $Root -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
            if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }

    Add-Result $Label $reclaimed
    if ($locked -gt 0) { Add-Note "$locked in use, skipped" }
}

function Remove-BuildDir([string]$Label, [string]$Path) {
    $before = Get-DirSize $Path
    if ($before -eq 0) { return }

    if ($DryRun) {
        Add-Result $Label $before
        return
    }

    # A locked file leaves the rest deleted, so report what actually went.
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue

    Add-Result $Label ($before - (Get-DirSize $Path))
}

function Clear-RustTarget([string]$Roots) {
    # A cargo target dir sits next to Cargo.toml and holds .rustc_info.json, so
    # nothing else matches. Each one rebuilds on the next cargo or tauri build.
    foreach ($root in $Roots -split ';' | Where-Object { $_ }) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        Get-ChildItem -LiteralPath $root -Recurse -Depth 4 -File -Filter 'Cargo.toml' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $target = Join-Path $_.DirectoryName 'target'
                if (-not (Test-Path -LiteralPath (Join-Path $target '.rustc_info.json'))) { return }

                $name = Split-Path $_.DirectoryName -Leaf
                if ($name -eq 'src-tauri') { $name = Split-Path (Split-Path $_.DirectoryName -Parent) -Leaf }
                Remove-BuildDir "$name target" $target
            }
    }
}

switch ($Mode) {
    'Bin' {
        $title = 'Recycle bin'
        Clear-Bin
    }
    'Caches' {
        $title = 'Caches cleared'
        Clear-BrowserCache 'Chrome' 'chrome' (Get-ChromiumCacheDir "$env:LOCALAPPDATA\Google\Chrome\User Data")
        Clear-BrowserCache 'Edge' 'msedge' (Get-ChromiumCacheDir "$env:LOCALAPPDATA\Microsoft\Edge\User Data")
        Clear-BrowserCache 'Brave' 'brave' (Get-ChromiumCacheDir "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data")
        Clear-BrowserCache 'Firefox' 'firefox' (Get-GeckoCacheDir "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles")
        Clear-BrowserCache 'Zen' 'zen' (Get-GeckoCacheDir "$env:LOCALAPPDATA\zen\Profiles")
        Clear-ToolCache 'npm' 'npm.cmd' @('cache', 'clean', '--force') "$env:LOCALAPPDATA\npm-cache"
        Clear-ToolCache 'uv' 'uv' @('cache', 'clean') "$env:LOCALAPPDATA\uv\cache"
        Clear-ToolCache 'pip' 'pip' @('cache', 'purge') "$env:LOCALAPPDATA\pip\cache"
        Clear-ToolCache 'go' 'go' @('clean', '-cache') "$env:LOCALAPPDATA\go-build"
        Clear-CargoTarball
        Clear-RustTarget $ProjectRoot
    }
    'Temp' {
        $title = "Temp cleaned ($TempAgeDays+ days)"
        Remove-OldTempFile 'User temp' $env:TEMP $TempAgeDays
        Remove-OldTempFile 'Windows temp' (Join-Path $env:SystemRoot 'Temp') $TempAgeDays
    }
}

if ($DryRun) { $title = "$title (dry run)" }

$total = if ($script:freed -gt 0) { "Freed $(Format-Size $script:freed)" } else { 'Nothing to clean' }
$detail = ($script:lines -join '  |  ')

Show-Toast $title $total $detail

# Visible when run from a terminal, ignored under conhost --headless.
Write-Output $title
Write-Output $total
foreach ($line in $script:lines) { Write-Output "  $line" }
