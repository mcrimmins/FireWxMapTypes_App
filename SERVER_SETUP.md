# Build server setup — moving ERA5 acquisition to the M710q

Status: written 2026-08-10, alongside `ERA5_MIGRATION_SCOPE.md` revision 3
Target: Lenovo ThinkCentre M710q, Ubuntu Server, on the LAN
Purpose: run phases 1, 2, 3 and 4 unattended so the laptop stays a development machine

---

## 0. The shape of the answer

| Question | Decision |
|---|---|
| Code layout | **One repo, two renv profiles.** The server clones `FireWxMapTypes_App` and runs with `RENV_PROFILE=build`. |
| What runs where | Server: acquisition, packing, FOD rebuild, precip re-encode. Laptop: `app.R`, figures, everything interactive. |
| Long-running execution | **systemd user unit**, not tmux. Survives disconnects *and* reboots, and has a restart policy. |
| Notifications | **ntfy**, plus a systemd `OnFailure=` unit for deaths the R process cannot report. |
| Getting files back | **The laptop pulls** over SSH. The server holds no credentials for the laptop. |

New files this adds:

```
util/era5_common.R              helpers with no plotting dependencies
build/setup_server.sh           one-time server preparation
build/bootstrap.R               installs the 6 build packages into the build profile
build/run_phase1.R              unattended entry point, exit codes, error handling
build/firewx-build.service      systemd user unit
build/firewx-notify-fail.service  OnFailure notifier
build/pull_results.ps1          laptop-side transfer
SERVER_SETUP.md                 this file
```

---

## 1. Why one repo rather than two

The build scripts sitting in `util/` inside a Shiny app does feel wrong on a
headless box. It is worth being precise about *which* part is wrong, because the
instinct — split the repo — fixes the cosmetic half and creates a worse problem.

What actually hurt was never the directory. It was three couplings:

1. `build_era5.R` sourced `era5_compare.R` for five helpers and inherited
   `library(ggplot2)`, `library(dplyr)`, `library(maps)` with them.
2. `check_project_root()` demanded `Data/FODthin.Rdata`, a 34 MB file the build
   never opens, so a fresh clone refused to start.
3. `renv.lock` describes the *app* — 85 packages — and there was no way to say
   "install the five I need".

All three are now fixed, and none of the fixes required a second repository. What
a second repo *would* have cost is a shared-helper problem with no good answer:
`era5_common.R` is used by phase 0 (laptop, plotting), phase 1 (server) and
phase 2 (server, but its output format is the app's read path). Duplicating it
means the day comes when the server's copy of `read_grid_long()` and the app's
copy disagree about a byte offset, and the symptom is a subtly wrong map rather
than an error. A submodule solves that and introduces a worse one.

The split that *is* worth making, later and separately: when `gridpack.R` is
written in phase 2, the accessor (`read_grid_long()`, the `meta` schema) is app
runtime code and belongs beside `app.R`, while the packer is build code. Same
file, two audiences. Keep them in one file with a clear boundary comment and let
the app source only what it needs.

### How the profile split works

```
renv.lock                      the app: 85 packages, unchanged, never touched by the server
renv/profiles/build/renv.lock  the build: ecmwfr, ncdf4, xml2, qs2, terra, httr
```

`RENV_PROFILE=build` in the server's `.Renviron` selects the second for every R
session on that box. The two libraries are independent, so nothing the server
installs can perturb a deploy bundle.

Commit `renv/profiles/build/renv.lock`. Do not run a bare `renv::snapshot()` on
the server — the repo's `snapshot.type` is `implicit`, which scans `app.R` and
would drag shiny back in. `build/bootstrap.R` passes an explicit `packages =`
list for exactly this reason.

---

## 2. Server preparation

```bash
ssh mike@m710q
git clone <your remote> ~/FireWxMapTypes_App
cd ~/FireWxMapTypes_App
bash build/setup_server.sh
```

`setup_server.sh` is idempotent and covers system libraries, R from CRAN's
Ubuntu repo, the systemd units, and four things that are easy to miss:

**Disk.** The Ubuntu Server installer's default LVM layout commonly leaves half
the SSD unallocated — `ubuntu-lv` at ~100 GB on a 250 GB disk, the rest idle in
the volume group. Phase 1 peaks around 9 GB so this is probably fine, but the
script tells you if there is unclaimed space and how to take it.

**Memory.** Aggregation accumulates every year of a variable's daily matrices
before writing: 3,321 cells × 12,054 days × 8 bytes ≈ 320 MB per statistic, and
gust carries two. Peak is roughly 1.5–2 GB. 8 GB is comfortable; on 4 GB add
swap first, because the OOM killer takes the R process without ceremony and
without a log line.

**Self-interruption.** `unattended-upgrades` can reboot mid-run. Suspend is
worse: the box comes back with a dead TCP connection to the CDS and the run
wedged rather than failed. The script masks the sleep targets and warns about
automatic reboots. Also set *After Power Loss → Power On* in the BIOS, so an
outage brings the machine back and systemd resumes on its own.

**Lingering.** `loginctl enable-linger` is what lets a `--user` service outlive
your SSH session. Without it the unit is killed at logout, which is precisely
the failure this whole exercise is meant to prevent.

### Secrets

`~/FireWxMapTypes_App/.Renviron` on the server — gitignored already, verify with
`git check-ignore -v .Renviron`:

```
CDS_KEY=<your CDS personal access token>
NTFY_TOPIC=firewx-build-<long-random-string>
RENV_PROFILE=build
```

R reads `.Renviron` from the working directory **at startup**, so R must be
started from the repo root. The systemd unit sets `WorkingDirectory=` for this
reason; if you run something by hand, `cd` first.

The CDS licence acceptance is per-account, not per-machine, so nothing to redo
there. The token is the same one the laptop uses.

### Packages

```bash
cd ~/FireWxMapTypes_App
RENV_PROFILE=build Rscript build/bootstrap.R
```

`bootstrap.R` detects the Ubuntu codename and points PPM at the matching binary
repository — `packagemanager.posit.co/cran/__linux__/noble/latest` rather than
`/cran/latest`. Without that segment you get source tarballs and `terra` spends
twenty minutes compiling against GDAL.

### A gotcha that would have hung the run at second zero

`ecmwfr` 2.x stores the CDS token through the **keyring** package. On a desktop
that is the OS keychain. On a headless Ubuntu box there is no Secret Service and
no D-Bus session, so `wf_set_key()` either errors outright or — with the
documented `keyring_backend = "file"` workaround — blocks on an *interactive
password prompt*. Under systemd that is an unattended run stuck forever at the
first line, with no output and no failure.

`setup_cds()` in `util/era5_common.R` now detects the headless case (unix, not
macOS, no `DBUS_SESSION_BUS_ADDRESS`, no explicit backend set) and selects
keyring's `env` backend, which holds the secret in the process environment. It
does not persist between sessions — which is correct here, because `setup_cds()`
re-reads `CDS_KEY` at the start of every run, so persistence buys nothing and a
plaintext keyring file on disk is only a liability.

---

## 3. Smoke test before committing 21 hours

```bash
cd ~/FireWxMapTypes_App
Rscript build/run_phase1.R --dry-run     # prints the plan, submits nothing
Rscript build/run_phase1.R 2020          # one year, ~36 min, in the foreground
```

The dry run exercises the whole path — project root check, package check, job
construction — without touching the CDS. The single-year run additionally
exercises CDS auth, the keyring path above, netCDF reading, aggregation and the
ntfy notifications. Watch for the "headless Linux detected" line; if it is
missing on the server, the keyring detection did not fire and you want to know
before the long run.

Run it inside `tmux` if you like — for a 36-minute foreground job that is what
tmux is good for.

---

## 4. The real run

```bash
systemctl --user start firewx-build
journalctl --user -u firewx-build -f
```

`run_phase1.R` sets `keep_hourly = FALSE` automatically for a multi-year run, so
the ~6.9 GB of hourly netCDF is deleted once aggregated. (Peak on disk is still
the full ~7 GB, because aggregation reads all years of a variable in one pass.)

### Exit codes and what systemd does with them

| Code | Meaning | Systemd |
|---|---|---|
| 0 | everything present and aggregated | stops, clean |
| 1 | unhandled R error | stops, fires `OnFailure` → urgent ntfy |
| 2 | finished but requests outstanding | restarts after 5 min, resumes |

Exit 2 is the interesting one. A failed CDS request is routine, and the build is
resumable on an *integrity check* rather than mere file existence, so a truncated
download is refetched rather than trusted. `RestartForceExitStatus=2` turns that
property into the retry loop: no bespoke retry logic in R, no risk of a retry
loop that re-downloads good files.

`StartLimitBurst=10` over 24 h stops a persistent failure — expired token,
revoked licence — from becoming an infinite loop hammering the CDS. That is a
good way to get an account suspended.

### Useful commands

```bash
systemctl --user status firewx-build
journalctl --user -u firewx-build -f              # live
journalctl --user -u firewx-build --since "1 hour ago"
journalctl --user -u firewx-build | grep '^\[.*\] \['   # just the job lines
systemctl --user stop firewx-build                # safe; costs the request in flight
df -h ~/FireWxMapTypes_App/Data
ls ~/FireWxMapTypes_App/Data/era5_raw/*.nc | wc -l   # of 232
```

---

## 5. Notifications

Set `NTFY_TOPIC` to something long and random. On the public ntfy.sh server the
**topic name is the credential** — anyone who knows it can read your messages and
post to them. Subscribe on the phone app or at `https://ntfy.sh/<topic>`.

With `NTFY_TOPIC` unset every notification call is a silent no-op, so the same
scripts run unchanged on the laptop.

What you get:

| When | Priority | Content |
|---|---|---|
| Run starts | low | jobs to fetch, jobs already present, year range |
| Every 12 jobs (~1 h) | min | percent complete, elapsed, ETA, **free disk**, failures so far |
| 3 consecutive failures | high | which job, counts, the `journalctl` line to run |
| Run finishes | default | duration, per-variable day counts, disk |
| Finishes incomplete | high | the above plus how many are outstanding |
| R throws | urgent | the error message and a reminder that it resumes |
| Process dies without R | urgent | last 25 log lines, from the systemd unit |

The hourly heartbeat is deliberate: **silence becomes the failure signal.** No
message for two hours means the run is stuck or the box is gone, and you learn
that at hour 14 rather than the next morning. That covers the case neither R nor
systemd can — a hang, where the process is alive and doing nothing.

Free disk is in every progress message because ~7 GB of intermediates is the one
resource this build can silently exhaust, and the failure mode when it does is a
truncated netCDF rather than an error.

If you would rather have an explicit dead-man switch than infer it from silence,
a healthchecks.io ping in the same loop is the standard answer — it alerts on
*absence* rather than on presence. ntfy alone is fine for a one-off 21-hour run;
it is worth adding if this becomes an annual job.

---

## 6. Getting files back

From the laptop, in PowerShell:

```powershell
.\build\pull_results.ps1                  # packed qs2 only, ~200 MB
.\build\pull_results.ps1 -What daily      # daily .rds, ~2 GB
.\build\pull_results.ps1 -WhatIf          # dry run
```

Set up `%USERPROFILE%\.ssh\config` first so the host is one word:

```
Host firewx-build
    HostName 192.168.1.xx
    User mike
    IdentityFile ~/.ssh/id_ed25519
```

The script uses rsync if it can find one (Git Bash, WSL, MSYS2) and falls back
to `scp`, which is built into Windows 10+. rsync is worth having: `--partial`
means a dropped link resumes instead of restarting, and `--checksum` catches a
rebuilt file that happens to be the same size.

Pulling rather than pushing means the server needs no key for the laptop and no
knowledge of whether it is awake. It also means nothing lands on the laptop
without you asking, which matters when the server is holding 9 GB of
intermediates you never want to see.

---

## 7. Phases 2–4 on the same box

Same pattern. Each phase gets a `build/run_phaseN.R` with the same argument
handling, error trapping and exit codes, and a unit that reuses the notifier.
When phase 2 exists:

```
build/run_phase2.R        gridpack.R: daily .rds -> qs2
build/run_phase3.R        FOD 7th edition rebuild
build/run_phase4.R        CPC precip re-encode (this is the one that needs terra)
```

Chain them with `Requires=` / `After=` if you want the whole pipeline to run
overnight, or `systemctl --user start firewx-phase2` by hand — for jobs that take
minutes rather than a day, by hand is fine.

`terra` is installed now (and its GDAL/GEOS/PROJ system dependencies) even
though nothing needs it until phase 4, so that phase 4 does not open with a
maintenance window.

---

## 8. Timezone — confirmed, not assumed

You flagged that the MST handling assumes Arizona never observes DST and asked
whether anything depends on the server's local time. Checked, and it does not,
for a specific reason worth writing down:

`read_nc_cells()` builds its time origin with `as.POSIXct(..., tz = "UTC")`, so
every POSIXct in the pipeline carries `tzone = "UTC"`. That matters because
**R 4.3 changed `as.Date.POSIXct()` to use the object's own time zone rather
than UTC** — a change that silently shifts dates for tz-naive objects. Here the
attribute is set explicitly, so `as.Date(tim + BCFG$tz_shift_h * 3600)` gives the
same answer regardless of the machine's `TZ`. The constant −7 offset is applied
arithmetically, never by a locale lookup.

The unit sets `TZ=UTC` anyway. It costs nothing and it makes the log timestamps
unambiguous when you are reading them from a laptop in Arizona at midnight.

---

## 9. What is still worth deciding

- **CDS concurrency.** The scope says one concurrent MARS request per user. If
  the account is ever raised to two, `BCFG$workers` exists but `fetch_jobs()` is
  a serial loop — parallelising it is a real change, not a config flip. Not worth
  doing speculatively.
- **Whether the server should hold `Data/FODthin.Rdata`.** It does not need it
  for phases 1, 2 or 4. Phase 3 *produces* the replacement, so the server needs
  the raw FPA-FOD 7th edition download instead — ~200 MB, and it should live on
  the server, not travel through the laptop.
- **Backups.** Nothing here is backed up. The ~200 MB of `qs2` is expensive to
  regenerate (21 hours) and, per scope R11, the hourly pull is reproducible while
  a derived-product pull would not have been — this build's choice to aggregate
  locally is what makes a rebuild deterministic at all. Still: once the archive
  is built and checksummed, copy it somewhere that is not this SSD.
