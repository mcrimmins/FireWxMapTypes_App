# Prompt for a new chat — moving the ERA5 build to a dedicated Linux box

*(Paste this into a fresh conversation. It carries the context that matters and
flags the gotchas already discovered, so they don't get rediscovered the hard way.)*

---

## What I'm doing

I maintain a Shiny app, **FireWxMapTypes_App**, that shows US wildfire occurrence
(FPA-FOD) against reanalysis weather maps. I'm migrating it off the discontinued
NCEP/DOE Reanalysis 2 onto ERA5. The plan is written up in
`ERA5_MIGRATION_SCOPE.md` in the project root — all ten decision gates are closed
and phase 1 (data acquisition) is validated and ready to run for real.

The problem: **phase 1 is ~21 hours of unattended downloading** and I don't want
it tying up my Windows laptop, where I'm developing the app itself.

## The machine

A **Lenovo ThinkCentre M710q running Ubuntu Server**, on my LAN. I want it to be
the data download and processing box. My laptop stays the app development
machine.

## What I want help with

1. **Setting up the M710q** for this job — R, system libraries, unattended
   long-running execution that survives SSH disconnects, disk space, anything
   else I haven't thought of.
2. **How to manage the build code across two machines.** Does the server need its
   own R project, or should it share the repo? The build scripts currently live
   in `util/` inside the Shiny app project, which feels wrong for a headless box.
3. **Push notifications via ntfy** (or a better alternative) — progress as it
   works through 33 years, and an alert if it dies at hour 14 rather than me
   finding out the next morning.
4. **Getting processed files back to the laptop** — into the project directory
   where the app lives.

## What the build actually does

`util/build_era5.R` makes **232 requests** to the Copernicus Climate Data Store:

- 33 pressure-level requests (geopotential at 500/700/1000 mb, 18Z, one per year)
- 198 hourly single-level requests (6 variables × 33 years, at 4–24 hours/day
  depending on the variable)
- 1 static orography field

It then aggregates the hourly data to daily statistics over **MST days**, writing
one `.rds` per variable-statistic to `Data/era5_raw/daily/`.

Measured on a smoke test of one year: **12.1 fields/second, ~36 min per year**,
so ~21 hours total. **CDS allows one concurrent request per user**, so it's
strictly serial — no parallelism to exploit.

Storage: **~7 GB of intermediate netCDF** (deletable after aggregation), ~2 GB of
daily `.rds`, and eventually **~200 MB of packed `qs2`** which is the only part
that needs to reach the laptop.

## Gotchas already found — please account for these

- **`build_era5.R` sources `util/era5_compare.R`** for shared helpers
  (`setup_cds`, `msg`, `need_pkgs`, `check_project_root`, `G0`). That file calls
  `library(ggplot2)`, `library(dplyr)` and `library(maps)`, which a headless
  build box has no use for. Pulling the shared helpers into something like
  `util/era5_common.R` is probably part of the answer.
- **`check_project_root()` requires `Data/FODthin.Rdata` to exist** — a 34 MB
  fire-occurrence file the build doesn't otherwise need. On a fresh server clone
  it would refuse to start.
- **The project uses `renv`** and `renv.lock` has 85 packages including shiny,
  plotly and DT. Restoring all that on the server is pointless. The build
  actually needs: `ecmwfr` (≥ 2.0), `ncdf4`, `xml2`, `qs2`, and `terra` for the
  precipitation work later. `xml2` isn't declared by `ecmwfr` but is required —
  without it CDS errors surface as "Please install xml2 package" instead of the
  real reason.
- **`CDS_KEY` lives in `.Renviron`** and is read via `Sys.getenv("CDS_KEY")`.
  It'll need to exist on the server, and not get committed to git.
- **`ncdf4` needs `libnetcdf-dev`**; `terra` needs GDAL/GEOS/PROJ. On Ubuntu
  Server these aren't there by default.
- The run is **fully resumable** — completed files are skipped on an integrity
  check, not merely on existence — so interrupting it costs only the request in
  flight. Whatever supervision approach we use can lean on that.
- The MST day handling assumes **Arizona does not observe DST** (constant UTC−7).
  The server's own timezone shouldn't matter, since the offset is applied
  explicitly, but worth confirming nothing else depends on system local time.

## What comes after phase 1

Phase 2 (`util/gridpack.R`, not yet written) quantises the daily `.rds` to `qs2`
— int8 anomaly encoding for the heights, uint8 for precipitation. There's also a
CPC precipitation re-encode and an FPA-FOD 7th-edition rebuild to do. **I'd like
all of that to run on the server too**, so the laptop only ever receives finished
`qs2` files rather than multi-gigabyte intermediates.

## What I'd like out of this conversation

A concrete setup plan I can work through, and a recommendation on the code-layout
question — I'd rather decide that properly now than end up with two diverging
copies of the build scripts.
