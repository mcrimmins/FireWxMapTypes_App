<#
build/pull_results.ps1
-------------------------------------------------------------------------------
Pull finished data files from the build server to this laptop.

    .\build\pull_results.ps1                       # packed qs2 only (~200 MB)
    .\build\pull_results.ps1 -What daily           # daily .rds (~2 GB)
    .\build\pull_results.ps1 -WhatIf               # list what would transfer

The laptop pulls; the server never pushes. That means the server holds no
credentials for this machine and does not care whether the laptop is on, asleep
or somewhere else entirely — which for a box whose job is to run unattended for
a day is the right way round.

Uses Windows' built-in OpenSSH. If you have rsync (Git Bash, WSL, or MSYS2 on
PATH) it is used instead, which makes the transfer resumable and incremental.
-------------------------------------------------------------------------------
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Host as configured in %USERPROFILE%\.ssh\config, or user@address.
    [string] $Server = "firewx-build",
    # Repo path on the server.
    [string] $RemoteRepo = "~/FireWxMapTypes_App",
    # qs2 = packed deliverables; daily = phase 1 intermediates; all = both.
    [ValidateSet("qs2", "daily", "all")]
    [string] $What = "qs2"
)

$ErrorActionPreference = "Stop"
$LocalRepo = Split-Path -Parent $PSScriptRoot

$sets = @{
    qs2   = @(@{ from = "Data/grids/";           to = "Data\grids" },
              @{ from = "Data/fod/";             to = "Data\fod" })
    daily = @(@{ from = "Data/era5_raw/daily/";  to = "Data\era5_raw\daily" })
}
$jobs = switch ($What) {
    "qs2"   { $sets.qs2 }
    "daily" { $sets.daily }
    "all"   { $sets.qs2 + $sets.daily }
}

$rsync = Get-Command rsync -ErrorAction SilentlyContinue

foreach ($j in $jobs) {
    $dest = Join-Path $LocalRepo $j.to
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $src = "${Server}:$RemoteRepo/$($j.from)"

    if ($PSCmdlet.ShouldProcess($src, "pull to $dest")) {
        Write-Host "`n== $($j.from) -> $($j.to)" -ForegroundColor Cyan
        if ($rsync) {
            # --partial keeps a half-transferred file so a dropped Wi-Fi link
            # resumes rather than restarts. -c compares checksums, not mtimes,
            # which matters because a rebuilt file can have the same size.
            $unix = ($dest -replace '\\', '/') -replace '^([A-Za-z]):', '/$1'
            & rsync -avz --partial --progress --checksum $src $unix
        } else {
            # scp -p preserves timestamps; there is no incremental mode, so this
            # re-copies everything each time. Fine for ~200 MB over a LAN.
            & scp -rp $src $dest
        }
        if ($LASTEXITCODE -ne 0) { throw "transfer failed for $($j.from)" }
    }
}

Write-Host "`nDone." -ForegroundColor Green
Get-ChildItem -Recurse -Path (Join-Path $LocalRepo "Data") -Include *.qs2 -File |
    Select-Object @{n='File';e={$_.Name}},
                  @{n='MB';e={[math]::Round($_.Length / 1MB, 1)}},
                  LastWriteTime |
    Format-Table -AutoSize
