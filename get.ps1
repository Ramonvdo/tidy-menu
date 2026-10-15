# Downloads the latest tidy-menu release and runs its installer.
#
#   irm https://raw.githubusercontent.com/Ramonvdo/tidy-menu/main/get.ps1 | iex
#
# The installer runs in a child powershell.exe with -ExecutionPolicy Bypass,
# because a downloaded .ps1 would otherwise be blocked by the default policy.
& {
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/Ramonvdo/tidy-menu/releases/latest' -UseBasicParsing
    Write-Output "Downloading tidy-menu $($release.tag_name)..."

    $work = Join-Path $env:TEMP ('tidy-menu-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $zip = Join-Path $work 'tidy-menu.zip'
        Invoke-WebRequest -Uri $release.zipball_url -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath $work

        $installer = Get-ChildItem -LiteralPath $work -Directory | Select-Object -First 1 |
            ForEach-Object { Join-Path $_.FullName 'install.ps1' }
        & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $installer
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
