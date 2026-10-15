<#
    Installs every module this machine supports, checks the registry and the
    commands it points at, uninstalls, and checks the registry is exactly as it
    was before. Touches only the current user. Exits 1 on any failure.

    powershell -ExecutionPolicy Bypass -File tests\roundtrip.ps1
#>
$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
$installDir = Join-Path $env:LOCALAPPDATA 'tidy-menu'
$HKCU = [Microsoft.Win32.Registry]::CurrentUser

if (Test-Path -LiteralPath (Join-Path $installDir 'state.json')) {
    throw 'tidy-menu is installed for this user. Uninstall it first; this test would remove it.'
}

# A leftover from a crashed run would sit in the baseline and hide a leak.
$leftovers = @(
    'Software\Classes\Directory\shell\TidyMenu.Terminal', 'Software\Classes\Directory\shell\TidyMenu.Claude'
    'Software\Classes\Directory\Background\shell\TidyMenu.Terminal', 'Software\Classes\Directory\Background\shell\TidyMenu.Claude'
    'Software\Classes\DesktopBackground\Shell\TidyMenu.QuickClean'
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\tidy-menu'
) | Where-Object { $key = $HKCU.OpenSubKey($_); if ($key) { $key.Close(); $true } }
if ($leftovers) { throw "Leftover tidy-menu keys, remove them first: $($leftovers -join ', ')" }

$watched = @(
    'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
    'Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
    'Software\Classes\Directory\shell'
    'Software\Classes\Directory\Background\shell'
    'Software\Classes\DesktopBackground\Shell'
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\tidy-menu'
)

function Get-Snapshot {
    $lines = New-Object System.Collections.Generic.List[string]
    $walk = {
        param([string]$Path)
        $key = $HKCU.OpenSubKey($Path)
        if (-not $key) { return }
        try {
            $lines.Add("[$Path]")
            foreach ($name in $key.GetValueNames()) {
                $data = $key.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
                if ($data -is [byte[]]) { $data = [BitConverter]::ToString($data) }
                if ($data -is [string[]]) { $data = $data -join '|' }
                $lines.Add("  '$name' $($key.GetValueKind($name)) = $data")
            }
            foreach ($sub in $key.GetSubKeyNames()) { & $walk "$Path\$sub" }
        } finally {
            $key.Close()
        }
    }
    foreach ($root in $watched) { & $walk $root }
    return $lines
}

$script:failed = 0
function Assert([string]$Name, [bool]$Ok, [string]$Evidence) {
    if ($Ok) { Write-Output "PASS  $Name" }
    else { Write-Output "FAIL  $Name  ($Evidence)"; $script:failed++ }
}

function Get-RegValue([string]$Path, [string]$Name) {
    $key = $HKCU.OpenSubKey($Path)
    if (-not $key) { return $null }
    try { return $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') } finally { $key.Close() }
}

function Get-CommandExe([string]$CommandLine) {
    if ($CommandLine -match '^"([^"]+)"') { return $Matches[1] }
    return $null
}

$before = Get-Snapshot

$all = 'ClassicMenu', 'HideWindowsEntries', 'HideAppEntries', 'OpenTerminal', 'OpenClaude', 'QuickClean'
& (Join-Path $repo 'install.ps1') -Modules $all | Write-Output

$state = Get-Content -LiteralPath (Join-Path $installDir 'state.json') -Raw | ConvertFrom-Json
$installed = @($state.Modules)
Assert 'state.json lists installed modules' ($installed.Count -gt 0) 'no modules'
Assert 'state.json has a journal' (@($state.Journal).Count -gt 0) 'empty journal'

$classes = 'Software\Classes'
if ($installed -contains 'ClassicMenu') {
    $v = Get-RegValue "$classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" ''
    Assert 'ClassicMenu: empty InprocServer32' ($v -eq '') "got '$v'"
}
if ($installed -contains 'HideWindowsEntries') {
    $blocked = 'Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
    foreach ($clsid in '{596AB062-B4D2-4215-9F74-E9109B0A8153}', '{09A47860-11B0-4DA5-AFA5-26D86198A780}') {
        Assert "HideWindowsEntries: $clsid blocked" ($null -ne (Get-RegValue $blocked $clsid)) 'value missing'
    }
}
foreach ($verb in 'TidyMenu.Terminal', 'TidyMenu.Claude') {
    $module = if ($verb -eq 'TidyMenu.Terminal') { 'OpenTerminal' } else { 'OpenClaude' }
    if ($installed -notcontains $module) { continue }
    foreach ($class in 'Directory', 'Directory\Background') {
        $path = "$classes\$class\shell\$verb"
        $command = Get-RegValue "$path\command" ''
        Assert "${module}: $class command uses %V\." ($command -like '*-d "%V\."*') "got '$command'"
        Assert "${module}: $class launcher exists" (Test-Path -LiteralPath (Get-CommandExe $command)) "missing '$(Get-CommandExe $command)'"
        $icon = (Get-RegValue $path 'Icon') -replace ',-?\d+$', ''
        Assert "${module}: $class icon exists" (Test-Path -LiteralPath $icon) "missing '$icon'"
    }
}
if ($installed -contains 'QuickClean') {
    $root = "$classes\DesktopBackground\Shell\TidyMenu.QuickClean"
    Assert 'QuickClean: submenu parent' ((Get-RegValue $root 'MUIVerb') -eq 'Quick Clean') 'MUIVerb missing'
    foreach ($item in '01-bin', '02-caches', '03-temp') {
        $command = Get-RegValue "$root\shell\$item\command" ''
        $target = if ($command -match '-File "([^"]+)"') { $Matches[1] } else { '' }
        Assert "QuickClean: $item points at an installed script" (Test-Path -LiteralPath $target) "got '$command'"
    }
    foreach ($mode in 'Caches', 'Temp') {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $installDir 'quick-clean.ps1') -Mode $mode -DryRun 2>&1
        Assert "QuickClean: $mode dry run exits 0" ($LASTEXITCODE -eq 0) ($output -join ' / ')
        Write-Output ($output | ForEach-Object { "      $_" })
    }
}
Assert 'Apps entry registered' ($null -ne (Get-RegValue 'Software\Microsoft\Windows\CurrentVersion\Uninstall\tidy-menu' 'UninstallString')) 'missing'

& (Join-Path $installDir 'uninstall.ps1') -Silent

$after = Get-Snapshot
$diff = Compare-Object @($before) @($after)
Assert 'uninstall restores the registry exactly' (-not $diff) (($diff | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join '; ')
Assert 'uninstall removes the install folder' (-not (Test-Path -LiteralPath $installDir)) "$installDir still exists"

if ($script:failed) {
    Write-Output "$script:failed check(s) failed."
    exit 1
}
Write-Output 'All checks passed.'
