<#
.SYNOPSIS
    Installs tidy-menu for the current user. No administrator rights needed.

.DESCRIPTION
    Asks Y/n for each module, or installs exactly the modules passed to -Modules.
    Running it again replaces the previous install, so changing your mind is a
    re-run. Every registry change is journaled to state.json, and uninstall.ps1
    replays that journal backwards: keys and values tidy-menu added are removed,
    values it changed get their old data back, and nothing else is touched.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -Modules ClassicMenu, OpenTerminal, QuickClean -RestartExplorer

.EXAMPLE
    .\install.ps1 -Modules QuickClean -ProjectRoot 'D:\code;C:\Users\me\src'
#>
[CmdletBinding()]
param(
    [ValidateSet('ClassicMenu', 'HideWindowsEntries', 'HideAppEntries', 'OpenTerminal', 'OpenClaude', 'QuickClean')]
    [string[]]$Modules,

    # Folders where Quick Clean may delete Rust build output (target), separated by ';'.
    [string]$ProjectRoot,

    [switch]$RestartExplorer
)

$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:LOCALAPPDATA 'tidy-menu'
$StatePath  = Join-Path $InstallDir 'state.json'
$HKCU       = [Microsoft.Win32.Registry]::CurrentUser
$Interactive = -not $PSBoundParameters.ContainsKey('Modules')

$catalog = @(
    [pscustomobject]@{ Id = 'ClassicMenu';        Default = $true;  Label = 'Full right-click menu on Windows 11, no "Show more options"' }
    [pscustomobject]@{ Id = 'HideWindowsEntries'; Default = $true;  Label = 'Hide rarely used Windows entries (previous versions, offline files, Work Folders, Defender scan, encryption)' }
    [pscustomobject]@{ Id = 'HideAppEntries';     Default = $false; Label = 'Hide entries added by Git, VLC and Visual Studio' }
    [pscustomobject]@{ Id = 'OpenTerminal';       Default = $true;  Label = 'Open in Terminal, on folders and folder backgrounds' }
    [pscustomobject]@{ Id = 'OpenClaude';         Default = $true;  Label = 'Open Claude Code here, on folders and folder backgrounds' }
    [pscustomobject]@{ Id = 'QuickClean';         Default = $true;  Label = 'Quick Clean submenu on the desktop: empty bin, clear caches, old temp files' }
)

# Shell extensions behind the Windows entries, by CLSID. Blocking one for the
# current user removes its menu entries without uninstalling anything.
$windowsExtensions = [ordered]@{
    '{596AB062-B4D2-4215-9F74-E9109B0A8153}' = 'Restore previous versions'
    '{474C98EE-CF3D-41f5-80E3-4AAB0AB04301}' = 'Always available offline'
    '{E61BF828-5E63-4287-BEF1-60B1A4FDE0E3}' = 'Work Folders'
    '{09A47860-11B0-4DA5-AFA5-26D86198A780}' = 'Scan with Microsoft Defender'
    '{A470F8CF-A1E8-4f65-8335-227475AA5C46}' = 'Encrypt / Decrypt'
}

# Verbs other apps register under HKLM. A LegacyDisable value under the same
# path in HKCU hides one for the current user only.
$appVerbs = @(
    'Directory\shell\git_gui', 'Directory\shell\git_shell'
    'Directory\Background\shell\git_gui', 'Directory\Background\shell\git_shell'
    'Directory\shell\AnyCode', 'Directory\Background\shell\AnyCode'
    'Directory\shell\PlayWithVLC', 'Directory\shell\AddToPlaylistVLC'
)

$script:journal = New-Object System.Collections.Generic.List[object]

function Open-Key([string]$Path) {
    # Opens HKCU\$Path for writing, creating any missing keys on the way down.
    # Each key created here is journaled so uninstall can remove it again.
    $key = $HKCU.OpenSubKey($Path, $true)
    if ($key) { return $key }

    $cut = $Path.LastIndexOf('\')
    if ($cut -gt 0) { (Open-Key $Path.Substring(0, $cut)).Close() }

    $script:journal.Add([pscustomobject]@{ Type = 'Key'; Path = $Path })
    return $HKCU.CreateSubKey($Path)
}

function Set-Value([string]$Path, [string]$Name, [string]$Data) {
    $key = Open-Key $Path
    try {
        $seen = $script:journal | Where-Object { $_.Type -eq 'Value' -and $_.Path -eq $Path -and $_.Name -eq $Name }
        if (-not $seen) {
            $existed = $key.GetValueNames() -contains $Name
            $script:journal.Add([pscustomobject]@{
                Type    = 'Value'
                Path    = $Path
                Name    = $Name
                Existed = $existed
                Data    = if ($existed) { [string]$key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') } else { $null }
                Kind    = if ($existed) { [string]$key.GetValueKind($Name) } else { $null }
            })
        }
        $key.SetValue($Name, $Data, [Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        $key.Close()
    }
}

function Test-ClassVerb([string]$Path) {
    $key = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey($Path)
    if ($key) { $key.Close(); return $true }
    return $false
}

function Save-ExeIcon([string]$Exe, [string]$Destination) {
    # Copies the first icon in $Exe into a multi-size .ico, so the menu keeps a
    # sharp icon even when the app's own install path changes on update.
    Add-Type -AssemblyName System.Drawing
    if (-not ('TidyMenu.Native' -as [type])) {
        Add-Type -Namespace TidyMenu -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern uint PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] icons, IntPtr ids, uint count, uint flags);
[DllImport("user32.dll")]
public static extern bool DestroyIcon(IntPtr icon);
'@
    }

    $images = @(foreach ($size in 16, 24, 32, 48, 256) {
        $handles = New-Object IntPtr[] 1
        if ([TidyMenu.Native]::PrivateExtractIcons($Exe, 0, $size, $size, $handles, [IntPtr]::Zero, 1, 0) -ne 1) { continue }
        try {
            $stream = New-Object System.IO.MemoryStream
            [System.Drawing.Icon]::FromHandle($handles[0]).ToBitmap().Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            [pscustomobject]@{ Size = $size; Bytes = $stream.ToArray() }
        } finally {
            [void][TidyMenu.Native]::DestroyIcon($handles[0])
        }
    })
    if ($images.Count -eq 0) { return $false }

    # ICO layout: a 6-byte header, one 16-byte entry per image, then the PNG data.
    $out = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter $out
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$images.Count)
    $offset = 6 + 16 * $images.Count
    foreach ($image in $images) {
        $side = if ($image.Size -ge 256) { 0 } else { $image.Size }
        $writer.Write([byte]$side); $writer.Write([byte]$side); $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$image.Bytes.Length); $writer.Write([uint32]$offset)
        $offset += $image.Bytes.Length
    }
    foreach ($image in $images) { $writer.Write($image.Bytes) }
    [System.IO.File]::WriteAllBytes($Destination, $out.ToArray())
    return $true
}

function Read-YesNo([string]$Question, [bool]$Default) {
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = "$(Read-Host "$Question $hint")".Trim()
        if (-not $answer) { return $Default }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
    }
}

function Restart-Explorer {
    Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}

# --- What this machine has --------------------------------------------------

$wt = Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$claude = Get-Command claude -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
$presentAppVerbs = @($appVerbs | Where-Object { Test-ClassVerb $_ })

$unavailable = @{}
if ([Environment]::OSVersion.Version.Build -lt 22000) { $unavailable['ClassicMenu'] = 'Windows 10 already has the full menu' }
if (-not $presentAppVerbs) { $unavailable['HideAppEntries'] = 'none of those apps are installed' }
if (-not $wt) {
    $unavailable['OpenTerminal'] = 'needs Windows Terminal'
    $unavailable['OpenClaude'] = 'needs Windows Terminal'
} elseif (-not $claude) {
    $unavailable['OpenClaude'] = 'needs Claude Code (claude) on PATH'
}

# --- Choose modules ---------------------------------------------------------

Write-Output ''
Write-Output 'tidy-menu: a cleaner right-click menu, for this Windows user only.'
Write-Output ''

$chosen = New-Object System.Collections.Generic.List[string]
foreach ($module in $catalog) {
    if ($unavailable.ContainsKey($module.Id)) {
        Write-Output "  skip  $($module.Label) ($($unavailable[$module.Id]))"
        continue
    }
    $want = if ($Interactive) { Read-YesNo "  $($module.Label)?" $module.Default } else { $Modules -contains $module.Id }
    if ($want) { $chosen.Add($module.Id) }
}

$roots = @()
if ($chosen -contains 'QuickClean') {
    if ($Interactive -and -not $ProjectRoot) {
        Write-Output ''
        Write-Output '  Quick Clean can also delete Rust build output (target folders) inside your'
        Write-Output '  project folders. Cargo rebuilds them on the next build.'
        $ProjectRoot = Read-Host '  Project folders, separated by ; (Enter to skip)'
    }
    foreach ($root in "$ProjectRoot" -split ';') {
        $root = $root.Trim().Trim('"').TrimEnd('\')
        if (-not $root) { continue }
        if (Test-Path -LiteralPath $root -PathType Container) { $roots += $root }
        else { Write-Warning "Skipping '$root': folder not found." }
    }
}

if ($chosen.Count -eq 0) {
    Write-Output ''
    Write-Output 'Nothing selected, nothing changed.'
    return
}

# --- Replace any previous install -------------------------------------------

$previous = @()
if (Test-Path -LiteralPath $StatePath) {
    $previous = @((Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).Modules)
    & (Join-Path $PSScriptRoot 'uninstall.ps1') -Silent
}

New-Item -ItemType Directory -Path (Join-Path $InstallDir 'icons') -Force | Out-Null
foreach ($file in 'quick-clean.ps1', 'uninstall.ps1') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $InstallDir -Force
    Unblock-File -LiteralPath (Join-Path $InstallDir $file)
}

# --- Apply ------------------------------------------------------------------

$classes = 'Software\Classes'

try {
    if ($chosen -contains 'ClassicMenu') {
        # An empty InprocServer32 for this CLSID makes Explorer fall back to the
        # classic menu. Takes effect when Explorer restarts.
        Set-Value "$classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" '' ''
    }

    if ($chosen -contains 'HideWindowsEntries') {
        foreach ($clsid in $windowsExtensions.Keys) {
            Set-Value 'Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked' $clsid $windowsExtensions[$clsid]
        }
        if (Test-ClassVerb 'Directory\shell\UpdateEncryptionSettings') {
            Set-Value "$classes\Directory\shell\UpdateEncryptionSettings" 'LegacyDisable' ''
        }
    }

    if ($chosen -contains 'HideAppEntries') {
        foreach ($verb in $presentAppVerbs) { Set-Value "$classes\$verb" 'LegacyDisable' '' }
    }

    if ($chosen -contains 'OpenTerminal' -or $chosen -contains 'OpenClaude') {
        # wt.exe is an app alias with no icon of its own, so borrow the packaged
        # Terminal's. "%V\." keeps a drive root like C:\ from escaping the quote.
        $terminalIcon = Join-Path $InstallDir 'icons\terminal.ico'
        $package = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -First 1
        $iconSource = if ($package) { Join-Path $package.InstallLocation 'WindowsTerminal.exe' } else { $wt.Source }
        $saved = $false
        if ((Test-Path -LiteralPath $iconSource) -and (Get-Item -LiteralPath $iconSource).Length -gt 0) {
            $saved = Save-ExeIcon $iconSource $terminalIcon
        }
        if (-not $saved) { $terminalIcon = "$env:SystemRoot\System32\cmd.exe,0" }

        $claudeIcon = if ($claude -and $claude.Source -like '*.exe') { "$($claude.Source),0" } else { $terminalIcon }

        foreach ($class in 'Directory', 'Directory\Background') {
            if ($chosen -contains 'OpenClaude') {
                $verb = "$classes\$class\shell\TidyMenu.Claude"
                Set-Value $verb 'MUIVerb' 'Open Claude Code here'
                Set-Value $verb 'Icon' $claudeIcon
                Set-Value "$verb\command" '' ('"{0}" -d "%V\." powershell.exe -NoLogo -NoExit -Command claude' -f $wt.Source)
            }
            if ($chosen -contains 'OpenTerminal') {
                $verb = "$classes\$class\shell\TidyMenu.Terminal"
                Set-Value $verb 'MUIVerb' 'Open in Terminal'
                Set-Value $verb 'Icon' $terminalIcon
                Set-Value "$verb\command" '' ('"{0}" -d "%V\."' -f $wt.Source)
            }
        }
    }

    if ($chosen -contains 'QuickClean') {
        # conhost --headless runs PowerShell with no console window and no flash.
        $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $cleanScript = Join-Path $InstallDir 'quick-clean.ps1'

        # An empty SubCommands value makes the shell build a submenu from the
        # child "shell" key. Key names set the order, so they are numbered.
        $root = "$classes\DesktopBackground\Shell\TidyMenu.QuickClean"
        Set-Value $root 'MUIVerb' 'Quick Clean'
        Set-Value $root 'Icon' "$env:SystemRoot\System32\cleanmgr.exe,0"
        Set-Value $root 'SubCommands' ''
        Set-Value $root 'Position' 'Bottom'

        $items = @(
            @{ Key = '01-bin';    Label = 'Empty recycle bin';           Mode = 'Bin' }
            @{ Key = '02-caches'; Label = 'Clear caches';                Mode = 'Caches' }
            @{ Key = '03-temp';   Label = 'Clean temp files (14+ days)'; Mode = 'Temp' }
        )
        foreach ($item in $items) {
            $command = '"{0}" --headless "{1}" -NoProfile -ExecutionPolicy Bypass -File "{2}" -Mode {3}' -f $conhost, $powershell, $cleanScript, $item.Mode
            if ($item.Mode -eq 'Caches' -and $roots) { $command += ' -ProjectRoot "{0}"' -f ($roots -join ';') }
            Set-Value "$root\shell\$($item.Key)" 'MUIVerb' $item.Label
            Set-Value "$root\shell\$($item.Key)\command" '' $command
        }
    }

    # Listed under Settings > Apps, so it can be removed without this folder.
    $entry = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\tidy-menu'
    Set-Value $entry 'DisplayName' 'tidy-menu'
    Set-Value $entry 'Publisher' 'tidy-menu contributors'
    Set-Value $entry 'DisplayIcon' "$env:SystemRoot\System32\cleanmgr.exe,0"
    Set-Value $entry 'InstallLocation' $InstallDir
    Set-Value $entry 'UninstallString' ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), (Join-Path $InstallDir 'uninstall.ps1'))
} finally {
    # Written even after a failure, so a half-finished install can still be undone.
    # ToArray(), because PowerShell 5.1 cannot serialize @() around a generic List.
    [pscustomobject]@{
        Modules = $chosen.ToArray()
        Journal = $script:journal.ToArray()
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

# --- Report -----------------------------------------------------------------

Write-Output ''
Write-Output 'Installed:'
foreach ($module in $catalog | Where-Object { $chosen -contains $_.Id }) { Write-Output "  $($module.Label)" }
if ($roots) { Write-Output "  Quick Clean also clears Rust target folders under: $($roots -join ', ')" }
Write-Output ''
Write-Output "Uninstall from Settings > Apps, or run: $(Join-Path $InstallDir 'uninstall.ps1')"

# Only these two are cached by a running Explorer; the rest show up at once.
$needsRestart = @($chosen) + $previous | Where-Object { $_ -in 'ClassicMenu', 'HideWindowsEntries' }
if ($needsRestart) {
    Write-Output ''
    if ($RestartExplorer -or ($Interactive -and (Read-YesNo 'Restart Explorer now so every change shows? Open File Explorer windows will close.' $true))) {
        Restart-Explorer
        Write-Output 'Explorer restarted.'
    } else {
        Write-Output 'Some changes show after Explorer restarts or you sign out and back in.'
    }
}
