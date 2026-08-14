<#
build/pull_results.ps1
-------------------------------------------------------------------------------
Pull build products from the M710q to this laptop. RUN THIS ON THE LAPTOP.

    .\build\pull_results.ps1                  # daily .rds  (~2.2 GB) - phase 1 output
    .\build\pull_results.ps1 -What hgt        # pressure-level .nc + orography (~350 MB)
    .\build\pull_results.ps1 -What qs2        # packed grids (phase 2 output, ~200 MB)
    .\build\pull_results.ps1 -What all
    .\build\pull_results.ps1 -VerifyOnly      # compare sizes, transfer nothing

The laptop pulls; the server never pushes. The server holds no credentials for
this machine and does not care whether it is awake — which for a box whose job
is to run unattended is the right way round.

Uses Windows' built-in OpenSSH (scp). Nothing to install. Over a gigabit LAN the
2.2 GB set takes a couple of minutes.

FIRST TIME: set up a key so you are not typing a password per file set.
    ssh-keygen -t ed25519                     # if you do not already have one
    type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh crimmins@192.168.0.234 `
        "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
-------------------------------------------------------------------------------
#>
[CmdletBinding()]
param(
    [string] $Server     = "crimmins@192.168.0.234",
    # Path on the server, relative to the remote home directory.
    [string] $RemoteRepo = "RProjects/FireWxMapTypes_App",
    [ValidateSet("daily", "hgt", "qs2", "all")]
    [string] $What       = "daily",
    [switch] $VerifyOnly
)

$ErrorActionPreference = "Stop"
$LocalRepo = Split-Path -Parent $PSScriptRoot

# from  = remote directory, relative to the repo root
# glob  = which files in it
# to    = local subdirectory, relative to the repo root
$sets = @{
    daily = @(@{ from = "Data/era5_raw/daily"; glob = "*";     to = "Data\era5_raw\daily" })
    hgt   = @(@{ from = "Data/era5_raw";       glob = "*.nc";  to = "Data\era5_raw" },
              @{ from = "Data/era5_raw";       glob = "*.txt"; to = "Data\era5_raw" })
    qs2   = @(@{ from = "Data/grids";          glob = "*";     to = "Data\grids" },
              @{ from = "Data/fod";            glob = "*";     to = "Data\fod" })
}
$jobs = if ($What -eq "all") { $sets.daily + $sets.hgt + $sets.qs2 } else { $sets[$What] }

foreach ($j in $jobs) {
    $dest = Join-Path $LocalRepo $j.to
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    Write-Host "`n=== $($j.from)/$($j.glob)  ->  $($j.to)" -ForegroundColor Cyan

    # Ask the server what should be there. GNU find -printf is fine on Ubuntu.
    # This doubles as the existence check: an empty result means the phase that
    # produces these files has not run yet, which is worth saying plainly rather
    # than letting scp fail with "No such file or directory".
    $remoteDir = "$RemoteRepo/$($j.from)"
    $remote = ssh $Server "cd '$remoteDir' 2>/dev/null && find . -maxdepth 1 -type f -name '$($j.glob)' -printf '%f\t%s\n' | sort"
    if (-not $remote) {
        Write-Host "  nothing on the server yet - skipping" -ForegroundColor DarkYellow
        continue
    }

    $remoteFiles = @{}
    foreach ($line in $remote) {
        $p = $line -split "`t"
        if ($p.Count -eq 2) { $remoteFiles[$p[0]] = [int64]$p[1] }
    }
    $totalMB = [math]::Round(($remoteFiles.Values | Measure-Object -Sum).Sum / 1MB, 1)
    Write-Host "  $($remoteFiles.Count) file(s), $totalMB MB on the server"

    if (-not $VerifyOnly) {
        # One scp per set, not per file: each invocation is a separate
        # authentication, and with a password rather than a key that is a prompt
        # each time.
        & scp -p "${Server}:$RemoteRepo/$($j.from)/$($j.glob)" $dest
        if ($LASTEXITCODE -ne 0) { throw "scp failed for $($j.from)" }
    }

    # Compare byte-for-byte sizes. scp reports success on a truncated transfer
    # more readily than you would like, and these files are large enough that a
    # silent short write is a real possibility.
    $rows = foreach ($name in ($remoteFiles.Keys | Sort-Object)) {
        $lf = Join-Path $dest $name
        $ls = if (Test-Path $lf) { (Get-Item $lf).Length } else { 0 }
        [pscustomobject]@{
            File     = $name
            RemoteMB = [math]::Round($remoteFiles[$name] / 1MB, 1)
            LocalMB  = [math]::Round($ls / 1MB, 1)
            OK       = ($ls -eq $remoteFiles[$name])
        }
    }
    $rows | Format-Table -AutoSize
    $bad = @($rows | Where-Object { -not $_.OK })
    if ($bad.Count) {
        Write-Host "  $($bad.Count) file(s) MISSING OR TRUNCATED - re-run" -ForegroundColor Red
    } else {
        Write-Host "  all files match" -ForegroundColor Green
    }
}

Write-Host "`nDone." -ForegroundColor Green
