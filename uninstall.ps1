<#
.SYNOPSIS
    Removes tidy-menu for the current user.

.DESCRIPTION
    Replays the journal install.ps1 wrote, newest change first. Values tidy-menu
    added are deleted, values it changed get their old data back, and keys it
    created are deleted once empty, so anything another app added since stays.

.EXAMPLE
    .\uninstall.ps1

.EXAMPLE
    .\uninstall.ps1 -RestartExplorer
#>
[CmdletBinding()]
param(
    [switch]$RestartExplorer,

    # Used by install.ps1 when it replaces an earlier install: no output, no prompt.
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:LOCALAPPDATA 'tidy-menu'
$StatePath  = Join-Path $InstallDir 'state.json'
$HKCU       = [Microsoft.Win32.Registry]::CurrentUser

if (-not (Test-Path -LiteralPath $StatePath)) {
    if (-not $Silent) { Write-Output 'tidy-menu is not installed for this user.' }
    return
}

$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
$journal = @($state.Journal)
[array]::Reverse($journal)

foreach ($change in $journal) {
    if ($change.Type -eq 'Value') {
        $key = $HKCU.OpenSubKey($change.Path, $true)
        if (-not $key) { continue }
        try {
            if ($change.Existed) {
                $key.SetValue($change.Name, $change.Data, [Microsoft.Win32.RegistryValueKind]$change.Kind)
            } else {
                $key.DeleteValue($change.Name, $false)
            }
        } finally {
            $key.Close()
        }
    } elseif ($change.Type -eq 'Key') {
        $key = $HKCU.OpenSubKey($change.Path)
        if (-not $key) { continue }
        $empty = $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0
        $key.Close()
        if ($empty) { $HKCU.DeleteSubKey($change.Path, $false) }
    }
}

Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
if ((Test-Path -LiteralPath $InstallDir) -and -not $Silent) {
    Write-Warning "Menu entries removed, but $InstallDir is in use. Delete it by hand."
}

if ($Silent) { return }

Write-Output 'tidy-menu removed.'

# Only these two are cached by a running Explorer; the rest disappear at once.
if (@($state.Modules) | Where-Object { $_ -in 'ClassicMenu', 'HideWindowsEntries' }) {
    $restart = $RestartExplorer
    if (-not $restart -and [Environment]::UserInteractive) {
        $answer = "$(Read-Host 'Restart Explorer now so every change shows? Open File Explorer windows will close. [Y/n]')".Trim()
        $restart = $answer -eq '' -or $answer -match '^(y|yes)$'
    }
    if ($restart) {
        Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 2
        if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
        Write-Output 'Explorer restarted.'
    } else {
        Write-Output 'Some changes show after Explorer restarts or you sign out and back in.'
    }
}
