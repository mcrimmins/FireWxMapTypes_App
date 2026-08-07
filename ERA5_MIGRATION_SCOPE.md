# ERA5 Migration & Data Overhaul — Scope

Status: **draft for review**
Author: drafted with Claude, 2026-08-07
Owner: M. Crimmins

---

## 1. Why

Three forcing functions arrived at once:

1. **FPA-FOD 7th edition (1992–2024)** is published (`FPA_FOD_20260615`, Short 2026). The app is
   stuck at the 6th edition's 2020 endpoint.
2. **The NCEP reanalysis line is unstable.** NCEP switched CDAS → CORe on 2026-03-18; PSL can no
   longer update NCEP/NCAR Reanalysis 1 and states it is "in the process of identifying other
   products that may no longer be able to be updated." R2 (what this app uses) is a separate
   product line and has *not* been formally discontinued — but it was never near-real-time, and
   it is a reasonable bet that it is collateral damage. See §9, Risk R1.
3. **The app cannot exceed 1 GB deployed**, and `Data/` is already 276 MB for a record that stops
   in 2020.

The opportunity: the current encoding is very inefficient, and fixing it frees enough budget that
the size constraint stops being the thing that drives design decisions.

---

## 2. What's actually wrong with the current data

Measured directly against the files in `Data/`:

| File | Grid | Stored as | On disk |
|---|---|---|---|
| `R2_hgt_{500,700,1000}mb` | 33 × 17 = 561 cells × 10,593 bands | **float32** + LZW | 15 MB each |
| `CPC_..._{14,90}dyPercAvg_INT` | 160 × 80 = 12,800 cells × 10,593 bands | int16 + LZW | 109 / 87 MB |
| `FODthin.Rdata` | ~2.3 M records × 11 cols | `save()` gzip | 34 MB |

Findings:

- **Heights are float32** for a field contoured at 10 m intervals spanning 4585–6028 m. ~4× more
  precision than the display can resolve.
- **Precip is 71% of the volume**, not the reanalysis. And **41% of every precip band is nodata**
  (`-32768` for ocean / off-domain), stored 10,593 times over.
- **10,593 GeoTIFF bands of 561 pixels is a pathological container.** Most of each 15 MB height
  file is per-band IFD overhead, and `terra` pays a seek cost per band on every subset.
- The app **already clamps precip display to `[0, 200]` with `oob = squish`** over a 5-colour ramp
  (`app.R` L277–285, L517–525). Only 12% of valid cells exceed 200%. Storing anything finer than
  ~2% steps is invisible.

### Measured encoding alternatives

500 mb heights, full 1992–2020 record:

| Encoding | Size | Lossy? |
|---|---|---|
| float32 + LZW *(current)* | 15.4 MB | no |
| int16 metres + zstd-19 | 5.8 MB | to 1 m |
| **int16 + spatial delta + zstd-19** | **4.3 MB** | to 1 m |
| int8 anomaly @ 5 m + zstd-19 | 2.7 MB | to 5 m — invisible at 10 m contours |

14-day precip, full record:

| Encoding | Size |
|---|---|
| int16 + LZW *(current)* | 108.8 MB |
| uint8 @ 2% steps, 0.5° | 62.9 MB |
| **uint8 @ 2% steps, 1.0°** | **17.8 MB** |
| + drop the 41% nodata cells | ~11 MB |

Derived constants used for projection below: **0.72 bytes/value** for heights (int16 + x-delta +
zstd-19), **0.52 bytes/value** for precip (uint8 + zstd-19). Both measured, not assumed. Note these
should *improve* at finer resolution, since delta encoding benefits from stronger neighbour
correlation — treat the projections as conservative.

---

## 3. Size budget

1992–2024 is **12,053 days** (×1.138 on the current record). Domain 20–60°N, 140–60°W.

### ERA5 geopotential heights

| Resolution | Grid | Cells | MB/level | 3 levels | 3 levels (int8 anom) | CDS download |
|---|---|---|---|---|---|---|
| 2.5° *(R2 today)* | 17 × 33 | 561 | 5 | 15 | 7 | 0.08 GB |
| **1.0°** | 41 × 81 | 3,321 | 29 | **86** | 43 | 0.48 GB |
| **0.5°** | 81 × 161 | 13,041 | 113 | **340** | 170 | 1.89 GB |
| 0.25° *(native)* | 161 × 321 | 51,681 | 448 | 1,345 ✗ | **673** | 7.47 GB |

### Totals

Precip re-encoded to uint8 @ 2% at 1.0°, both windows, land-masked: **24 MB** (measured basis;
the 90-day field is smoother than the benchmarked 14-day one, so this is an upper bound).
FOD 7th edition as factor-encoded `qs2`: **~18 MB** *(estimate — not yet measured, see R6)*.

| Target | Heights | Precip | FOD | **Total** | % of 1 GB |
|---|---|---|---|---|---|
| 1.0° int16 | 86 | 24 | ~18 | **~128 MB** | 13% |
| 0.5° int16 | 340 | 24 | ~18 | **~382 MB** | 38% |
| 0.25° int8 anomaly | 673 | 24 | ~18 | **~715 MB** | 72% |

*(Current app: 276 MB and stops in 2020.)*

**Conclusion: 1 GB is not the binding constraint.** Even 0.5° — a 5× resolution increase over R2
with four extra years — lands at 38% of budget. The real constraints become startup load time and
deployed RAM, both of which the format change improves.

---

## 4. Decision gates

### D1 — Resolution *(blocking; do this first)*

**Deliverable:** the same 4-panel extreme-fire-day map rendered at 2.5° / 1.0° / 0.5° for 3–4 real
AZ fire days, side by side, so the choice is visual rather than numerical.

Things to look at:

- Does 0.5° add *synoptic* information, or just noise on the contours?
- `binwidth = 10` in `geom_contour` (`app.R` L271, L511) will produce visibly denser contours at
  higher resolution. Does the interval need to scale with resolution?
- Do the 1000 mb maps degrade over terrain? 1000 mb is below ground across much of the interior
  West, and ERA5's extrapolation there differs from R2's.

Implementation note: this gate only needs ~10 days of data, so it can be built from a single small
CDS request (minutes, not days) before committing to the full 33-year pull.

### D2 — Source of record

Recommended: **ERA5** (ECMWF/Copernicus).

| Source | Res | Period | Latency | Notes |
|---|---|---|---|---|
| **ERA5** | 0.25° | 1940– | ~5 d (ERA5T) | Best archive. Consistent across the full period — no splice at 1992. Non-US provider. |
| CORe | 2.5° | 1979– | operational | Designated CDAS/R1 successor; maximum lineage continuity. Not on PSL — pull from CPC. |
| CFSR/CFSv2 | 0.5° | 1979– | near-RT | Solid, operational, US. |
| MERRA-2 | 0.5°×0.625° | 1980– | ~3 wk | Earthdata login. |

The only real argument against ERA5 is provenance: if funding or audience wants a US federal
source, CORe keeps the NCEP lineage. Flagging rather than deciding.

### D3 — Access path

Recommended: **CDS API with server-side regridding**, not ARCO-ERA5.

- **CDS** (`reanalysis-era5-pressure-levels`, via the `ecmwfr` R package or `cdsapi`): request
  `area = [60, -140, 20, -60]` and `grid = [1.0, 1.0]` so ECMWF does the regrid before transfer.
  One request per year = 33 requests, ~15 MB each at 1°. Queue times are the wall-clock risk.
- **ARCO-ERA5** (`gs://gcp-public-data-arco-era5`, anonymous): the `...-chunk-1.zarr-v3` store is
  chunked with size 1 along time, so pulling one hour × 3 levels × CONUS means reading whole
  *global* 0.25° fields — roughly 145 GB of reads to extract 0.5 GB of data. Wrong access pattern
  for this job. ARCO wins if you later want many variables at full resolution.

**Verify before building:** that `grid` is still honoured for this dataset on the post-2024 CDS.
If it isn't, regrid locally after downloading at 0.25° (7.5 GB one-time, then discard).

### D4 — Precip: keep CPC

CPC Global Unified is still produced and updated (3–5 day latency), so no source change is needed —
just re-encoding (§5). If ERA5 `total_precipitation` were used instead you'd gain a single-source
pipeline but lose the gauge-based character of the current product. **Recommend keeping CPC.**

---

## 5. Target data architecture

### Layout

```
Data/
  README.md                       # tracked; fill in the TODOs as part of this work
  grids/
    hgt500_archive_1992_2024.qs2  # frozen; regenerated only on ERA5 version change
    hgt500_current.qs2            # appendable, current year
    hgt700_archive_1992_2024.qs2
    hgt700_current.qs2
    hgt1000_archive_1992_2024.qs2
    hgt1000_current.qs2
    precip14_archive_1992_2024.qs2
    precip14_current.qs2
    precip90_archive_1992_2024.qs2
    precip90_current.qs2
  fod/
    fod_archive_1992_2024.qs2
    fod_current.qs2               # WFIGS year-to-date, via util/currYrFireHelperFunc.R
```

The archive/current split is the "readily updated" requirement: an annual refresh regenerates a
~3 MB file, not an 86 MB one.

### On-disk object

Drop GeoTIFF entirely — these are small regular arrays, not images.

```r
list(
  meta = list(
    var     = "hgt", level = 500, units = "m",
    source  = "ERA5", hour_utc = 18L,
    dtype   = "int16", scale = 1, offset = 0,   # value = raw * scale + offset
    nx = 81L, ny = 41L,
    xmin = -140, xmax = -60, ymin = 20, ymax = 60,
    crs = "EPSG:4326",
    built = as.Date("2026-..-.."), builder_version = "1.0"
  ),
  dates = <Date[nt]>,
  mask  = <int[ncell_valid] | NULL>,   # indices into the nx*ny grid; NULL when all valid
  data  = <integer matrix, ncell_valid x nt>   # column-major: one column per day
)
```

Serialised with `qs2::qs_save(..., compress_level = 19)` (zstd under the hood). Cell-major layout
with days as columns means a date subset is a contiguous column slice.

### Accessor

One function replaces every `terra::rast()` / `as.data.frame(xy=TRUE)` / `pivot_longer` chain in
`app.R`:

```r
#' @return data.frame(x, y, Date, value) ready for ggplot
read_grid_long <- function(handle, dates)
```

Grids are loaded once at startup into a module-level environment; `read_grid_long` does a
`match()` on the date vector, slices columns, applies scale/offset, and joins the cached
`expand.grid(x, y)` coordinate frame. No file I/O per render.

This alone should remove a visible fraction of current render latency — the app currently rebuilds
a long data frame from a GeoTIFF on every reactive invalidation, three times over.

---

## 6. Work breakdown

| # | Phase | Detail | Est. |
|---|---|---|---|
| 0 | **Resolution comparison** | Small CDS pull (~10 days), render D1 comparison figures. **Gate.** | 0.5 d |
| 1 | **ERA5 acquisition** | `util/build_era5.R`: `ecmwfr` request loop by year, 3 levels, 18Z, `area` + `grid`. Retry/resume, checksum manifest. | 1–2 d *(+ CDS queue, days of wall-clock)* |
| 2 | **Codec + format library** | `util/gridpack.R`: `pack_grid()` / `read_grid_long()`, delta + quantise + mask + `qs2`. Round-trip unit tests. | 1–2 d |
| 3 | **FOD 7th edition** | Rewrite `util/thinFOD.R` for `FPA_FOD_20260615`. **Verify column names first** — schema changed between 5th and 6th editions. Re-derive `OPERATION_DAYS`, `FIRE_SIZE_CLASS`. Factor-encode. | 0.5–1 d |
| 4 | **Precip re-encode** | Extend `util/gridINT.R` → uint8 @ 2%, regrid to chosen resolution, land mask, `qs2`. Extend record to 2024. | 0.5 d |
| 5 | **`app.R` refactor** | Swap in the accessor; **and collapse the triplicated filter chain into one `reactive()`** (see §7). | 2–3 d |
| 6 | **Validation** | R2-vs-ERA5 overlap comparison; quantisation round-trip error; visual diff of the same map old vs new. | 1 d |
| 7 | **Docs + deploy** | Fill in `Data/README.md` TODOs, write `util/build_data.R` as the single entry point, `renv::snapshot()`, deploy test. | 0.5 d |

**Total: ~8–11 working days**, with CDS queue time running in parallel to phases 2–4.

Phases 2, 3 and 4 are independent of phase 1 and of each other — they can be built and tested
against the existing files while ERA5 downloads.

---

## 7. Coupled refactor (why phase 5 is 2–3 days, not 1)

Changing the data format forces a touch of every render block anyway, and those blocks are
currently duplicated. From the earlier review of `app.R`:

- The filter chain (state → year → operation days → month → cause → size class → percentile) is
  copy-pasted **three times** — `fireMap` (L162–192), `fireDaysTable` (L356–383), `weatherMaps`
  (L434–460). They have already drifted:
  - `fireSummaryPlot` (L297) ignores year, month, cause and operation-day filters entirely.
  - `weatherMaps` (L422) silently drops the 1000 mb option: `if (gh500) gh500 else gh700`.
- The ~25-line ggplot block appears twice, byte-identical apart from the data source.
- `FIRE_SIZE_RANK` is computed *after* filtering (L187, L304, L378), so the percentile is relative
  to the current subset rather than the full record. **Confirm whether that's intended** — it
  changes what the slider means.

Recommend: one `filteredFires()` reactive, one `fire_wx_map(fire_df, gh_df, precip_df, ...)`
plotting function, and fix the 1000 mb bug. Doing this *with* the format swap is much cheaper than
doing it after.

---

## 8. Enabled by the overhaul (not in scope, but cheap afterward)

- **Precomputed synoptic map types.** SOM or k-means on 500 mb anomaly fields, computed offline.
  One cluster ID per day (12 KB) plus ~30 composite maps. Would support a "which synoptic types
  are over-represented on extreme fire days in AZ?" tab that renders instantly. This is the app's
  namesake and is currently absent from it.
- **More variables.** At 1° the budget has ~875 MB spare. 700 mb winds, PWAT, or a VPD/ERC field
  would say more about fire weather than finer heights would.
- **Current-year data.** `util/Reanal2CurrYear.R` and `util/currYrFireHelperFunc.R` already reach
  toward this but were never wired in. The archive/current split makes it straightforward.

---

## 9. Risks

| | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | R2 may not actually be discontinued — it's R1/CDAS that ended | Migration may be less urgent than assumed | Email `psl.data@noaa.gov` to confirm R2's update schedule. Doesn't change the recommendation (ERA5 is better regardless), but changes the deadline. |
| R2 | **ERA5 ≠ R2.** Different model, resolution, and topography | Maps will not match previously published figures; any prior interpretation may shift | Phase 6 overlap comparison over 1992–2020. Budget time to look at it seriously. |
| R3 | **ERA5 `z` is geopotential (m² s⁻²), not height (m)** | Silent 9.8× error | Divide by 9.80665. Assert range 4500–6100 m for 500 mb in the build script. |
| R4 | CDS `grid` regridding may not be supported post-2024 CDS | 7.5 GB download instead of 0.5 GB | Verify in phase 0. Fall back to local regrid. |
| R5 | CDS queue times are unpredictable | Wall-clock slip | Start phase 1 first; it parallelises with 2–4. |
| R6 | FPA-FOD 7th ed. column names may differ | Build script breaks | Inspect schema before writing phase 3. |
| R7 | `qs2` must build on the deploy target | Deploy failure | `renv::snapshot()` and a deploy smoke test in phase 7. Check the platform's binary availability. |
| R8 | Longitude convention (0–360 vs ±180) | Empty or wrapped grids | `area` on CDS uses ±180. Assert extent after read. |
| R9 | 1000 mb below ground over the interior West | Physically meaningless contours | Already true with R2. Worth deciding in D1 whether to keep the level at all. |

---

## 10. Open questions for Mike

1. **D1** — resolution, pending the visual comparison.
2. **D2** — ERA5 vs CORe: does provenance (US federal vs ECMWF) matter for your audience or funding?
3. Is 18Z still the right snapshot, or would a daily mean / a different hour serve the fire-weather
   framing better? ERA5 is hourly, so this is free to change — but it's a break from the R2 record.
4. Is the **fire size percentile** meant to rank within the current filtered subset, or against the
   full record? (§7)
5. Keep 1000 mb? (R9)
6. Where does the deployed app live — shinyapps.io, Posit Connect, self-hosted? The 1 GB figure and
   the RAM ceiling depend on it, and so does R7.

---

## Appendix — sources

- [PSL Data Notice: NCEP/NCAR Reanalysis 1 updates to end](https://psl.noaa.gov/news/2026/r1datanotice.html)
- [NCEP/DOE Reanalysis II](https://psl.noaa.gov/data/gridded/data.ncep.reanalysis2.html)
- [NCEP CPC CORe](https://www.cpc.ncep.noaa.gov/products/CORe/pns/eval/)
- [NWS CDAS→CORe service change notice (PDF)](https://www.weather.gov/media/notification/pdf_2026/scn26-12_Updated_CDAS_COReUpdate_aaa.pdf)
- [ERA5 five days behind real time (ERA5T)](https://climate.copernicus.eu/key-update-climate-dataset-brings-data-five-days-behind-real-time)
- [CDS API setup](https://cds.climate.copernicus.eu/how-to-api)
- [`ecmwfr` R package](https://bluegreen-labs.github.io/ecmwfr/)
- [ARCO-ERA5 (google-research)](https://github.com/google-research/arco-era5)
- [CPC Global Unified Gauge-Based Analysis of Daily Precipitation](https://psl.noaa.gov/data/gridded/data.cpc.globalprecip.html)
- [FPA-FOD, Forest Service Research Data Archive](https://www.fs.usda.gov/rds/archive/catalog/RDS-2013-0009.6)
