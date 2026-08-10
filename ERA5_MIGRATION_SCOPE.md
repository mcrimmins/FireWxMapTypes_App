# ERA5 Migration & Data Overhaul — Scope

Status: **revision 3 — all ten decision gates closed, phase 1 in progress**
Author: drafted with Claude, 2026-08-07
Owner: M. Crimmins

---

## 0. What changed since draft 1

Phase 0 ran. Three benchmarks were built and executed (`util/era5_compare.R`,
`util/bench_1deg.R`, `util/bench_render_opts.R`), and their output is in
`Data/scratch/`. Several things in draft 1 turned out to be wrong.

| | Draft 1 said | Measured | Consequence |
|---|---|---|---|
| **D1 resolution** | open | 1.0° adds real synoptic detail over 2.5°; 0.5°/0.25° add noise, not signal | **1.0° chosen** |
| **R4 CDS `grid`** | unverified; 0.5 GB or 7.5 GB | honoured at 1.0/0.5/0.25° | **closed** — 0.5 GB, no local regrid |
| **R9 1000 mb** | "already true with R2" | at 1.0° it degrades below R2 quality *over the West* — but the level is sound in the East | **keep, mask below ground** (an interim revision said drop it, on AZ-only evidence) |
| **§5 accessor** | "should remove a visible fraction of render latency" | removes 440 ms of a 3,160 ms render — 14% | claim was wrong |
| **§5 object spec** | implies an integer matrix | integer costs 4x the RAM of raw bytes | **spec change** — store raw |
| **render cost** | not considered | the map takes 3–8 s to *draw*; filtering it gives 2.2–3.3x | **new phase, independent of ERA5** |
| **derived daily stats** | "worth checking whether it honours `grid`" | `area` **and** `grid` both honoured; 81 × 41 not 1440 × 721 | **daily max/min variables are cheap** |
| **added variables** | "cheap afterward", §8 | seven fire-weather variables cost ~137 MB disk | **in scope, D8** |
| **eager loading** | §5, load all grids at startup | ~1,044 MB all-resident vs ~575 MB lazy | **lazy per variable, required** |
| **sampling frequency** | not considered | 3-hourly is exact for daily means, 2–3% low for daily maxima | **3-hourly, D10** — cuts phase 1 from ~2 days to ~14 h |
| **deploy ceiling** | "cannot exceed 1 GB deployed" | the 1 GB is the **bundle** cap on disk; Connect reports Max RAM = 0, no runtime cap | R10 closed; R13/R14 opened |

The headline: **the app's responsiveness problem is not the data format.** It is
that every render draws roughly 24x more geometry than ends up visible. That is
fixable now, without ERA5.

The second headline: because the derived daily-statistics entry regrids
server-side, the app can carry humidity, wind and ignition variables it has never
had, for less than the heights cost.

---

## 1. Why

Three forcing functions arrived at once:

1. **FPA-FOD 7th edition (1992–2024)** is published (`FPA_FOD_20260615`, Short 2026). The app is
   stuck at the 6th edition's 2020 endpoint.
2. **The NCEP reanalysis line this app depends on has stopped.** NCEP switched CDAS → CORe on
   2026-03-18 and PSL can no longer update NCEP/NCAR Reanalysis 1. **R2 — what this app uses — is
   also no longer being updated** (confirmed by MAC, 2026-08-07). Migration is required, not
   optional; the only in-family alternative would be CORe.
3. **The app cannot exceed 1 GB deployed**, and `Data/` is already 276 MB for a record that stops
   in 2020.

---

## 2. What's actually wrong with the current data

Measured directly against the files in `Data/`:

| File | Grid | Stored as | On disk |
|---|---|---|---|
| `R2_hgt_{500,700,1000}mb` | 33 × 17 = 561 cells × 10,593 bands | **float32** + LZW | 15 MB each |
| `CPC_..._{14,90}dyPercAvg_INT` | 160 × 80 = 12,800 cells × 10,593 bands | int16 + LZW | 109 / 87 MB |
| `FODthin.Rdata` | ~2.3 M records × 11 cols | `save()` gzip | 34 MB |

Findings:

- **Heights are float32** for a field contoured at 10 m intervals. ~4× more precision than the
  display can resolve.
- **Precip is 71% of the volume**, and **41% of every precip band is nodata**, stored 10,593 times.
- **10,593 GeoTIFF bands of 561 pixels is a pathological container.** Most of each 15 MB height
  file is per-band IFD overhead, and `terra` pays a seek cost per band on every subset.
- The app **already clamps precip display to `[0, 200]` with `oob = squish`**. Storing anything
  finer than ~2% steps is invisible.

### Measured encoding alternatives

Two independent measurements now exist. The 2.5° column is from real R2 data. The 1.0° column is
from `bench_1deg.R`, whose synthetic record repeats 10 real ERA5 days and therefore **compresses
better than the real thing will** — treat it as a lower bound and plan against the 2.5°-derived
projection.

| Encoding | 2.5°, real | bytes/value | 1.0° projected | 1.0° bench (flattered) |
|---|---|---|---|---|
| float32 + LZW *(current)* | 15.4 MB | 2.59 | — | — |
| int16 + zstd-19 | 5.8 MB | 0.976 | 39 MB | 27.4 MB |
| int16 + spatial delta + zstd-19 | 4.3 MB | 0.72 | **29 MB** | 10.8 MB |
| int8 anomaly @ 5 m + zstd-19 | 2.7 MB | 0.455 | **18 MB** | 9.7 MB |

int8 anomaly at 5 m is invisible against 10 m contours; measured round-trip error is 2.5 m.

---

## 3. Size and memory budget

1992–2024 is **12,054 days**. Domain 20–60°N, 140–60°W. At 1.0° that is 81 × 41 = **3,321 cells**,
so **40.03 M values per level**.

### Disk

| Component | Choice | Disk |
|---|---|---|
| Heights, 500 + 700 + 1000 mb, 1.0°, int8 anomaly | D1, D6 | ~54 MB |
| Derived daily variables, seven of them | D8, D10 | ~137 MB |
| Precip, 14 + 90 day, 0.5°, uint8 @ 2%, land-masked | D5 | ~84 MB |
| FOD 7th edition, factor-encoded `qs2` | | ~18 MB *(estimate, unmeasured)* |
| **Total** | | **~293 MB** — 29% of the 1 GB bundle cap |

*(Current app: 276 MB, stopping in 2020 and carrying a third as much information.)*

### Resident RAM — the actual constraint

Disk was never the binding limit. RAM is, and R's lack of an int16 type is the trap: the same
40 M values cost 4 bytes each as an R `integer` and 1 byte as a `raw`. Measured with
`object.size`, so these are exact:

| Backend | Per level | 3 levels | Lossy to |
|---|---|---|---|
| R integer matrix | 152.7 MB | 458 MB | 0.5 m |
| int16 raw | 76.4 MB | 229 MB | 0.5 m |
| **int8 anomaly raw** | **38.2 MB** | **115 MB** | 2.5 m |

Full deployed estimate:

| | Everything resident | Lazy per variable |
|---|---|---|
| Heights, 3 levels | 115 MB | 38 MB — one level shown at a time |
| Derived variables, 7 | 305 MB | 0 until selected, then 38–76 MB each |
| Precip, 2 windows @ 0.5° land-masked | 174 MB | 87 MB — one window shown at a time |
| FOD 7th edition | ~200 MB *(unmeasured — the largest remaining unknown)* | ~200 MB |
| R + shiny + ggplot + terra | ~250 MB | ~250 MB |
| **Total** | **~1,044 MB** | **~575 MB at startup** |

**Eager loading no longer fits.** Draft 1's §5 rule — hold every grid resident from startup — was
written when the alternative was 440 ms of `terra` seeking per render. `qs2` reads a full
level-record in 0.12 s, which against a ~1 s render is imperceptible. **Lazy per-variable loading is
now a requirement, not an optimisation.** Every selector in the UI displays one level, one precip
window and one derived variable at a time, so the resident set stays small in practice.

Measuring the FOD term should be the first thing phase 3 does: it is both the largest line and the
only guessed one. If it lands well above 200 MB, precip at 1.0° returns ~130 MB (D5) and is the
cheapest lever. This is also the number that depends on **open question 6**.

---

## 4. Decisions

### D1 — Resolution: **1.0°.** CLOSED

Evidence: `Data/scratch/d1_byres_*.png`, `d1_topdays_*.png`, `d1_binwidth_*.png`.

- 500 mb at 1.0° reproduces the 2.5° synoptic pattern with a better-resolved gradient. 0.5° and
  0.25° add contour wiggle without adding a feature you would interpret differently.
- 700 mb behaves the same way and is clean at every resolution.
- `binwidth = 10` still reads at 1.0°. It does not need to scale with resolution. It becomes
  cluttered at 0.25°, which is moot now.
- Contour drawing is cheap (290–470 ms of a 2,350–2,900 ms render), so the interval carries no
  performance consequence either way.

### D2 — Source of record: **ERA5.** CLOSED

Confirmed by MAC 2026-08-07. The technical case was already settled; the only open question was
whether funding or audience required a US federal source. It does not. CORe is not pursued.

With this, **every decision gate is closed** and the acquisition plan is fixed.

| Source | Res | Period | Latency | Notes |
|---|---|---|---|---|
| **ERA5** | 0.25° | 1940– | ~5 d (ERA5T) | Best archive. No splice at 1992. Non-US provider. |
| CORe | 2.5° | 1979– | operational | Designated CDAS/R1 successor. Not on PSL — pull from CPC. |
| CFSR/CFSv2 | 0.5° | 1979– | near-RT | Solid, operational, US. |
| MERRA-2 | 0.5°×0.625° | 1980– | ~3 wk | Earthdata login. |

### D3 — Access path: CDS API with server-side regridding. CLOSED

**Verified 2026-08-07:** `grid` is honoured. Requested 1.0/0.5/0.25°, delivered 1.000/0.500/0.250°.
The R4 fallback is not needed.

- `reanalysis-era5-pressure-levels` via `ecmwfr`, `area = [60, -140, 20, -60]`, `grid = [1.0, 1.0]`.
- One request per year = 33 requests. Queue time is the wall-clock risk.
- Request key names differ between the legacy and post-2024 CDS. `era5_compare.R` tries four
  payload variants; **variant 1 succeeded** (`data_format` / `download_format`, numeric `grid`).
  Reuse that shape in `build_era5.R`.
- ARCO-ERA5 rejected: chunked with size 1 along time, so a CONUS hour means reading whole global
  fields — ~145 GB of reads for 0.5 GB of data.

### D4 — Precip source: keep CPC. CLOSED

Still produced and updated (3–5 day latency). Re-encode only.

### D5 — Precip resolution: **0.5° (keep native).** CLOSED, with a caveat

Draft 1 assumed precip would drop to 1.0° alongside the heights. Measured, the render penalty for
keeping 0.5° is much smaller than it first appeared — but only *after* the §6.1 filtering work:

| | unfiltered | filtered to view |
|---|---|---|
| 0.5° vs 1.0° precip, 12 facets | +1,200 ms | +30 ms |
| 0.5° vs 1.0° precip, 30 facets | +5,300 ms | +370 ms |

The fill is the dominant visual element on these maps and 1.0° reads noticeably blockier, so 0.5°
is worth 30 ms. **Caveat:** this decision was taken on render-time grounds; it also costs ~130 MB
of resident RAM (§3). If open question 6 resolves to a 1 GB instance, revisit it.

### D6 — Levels: **keep all three, and mask 1000 mb below ground.** CLOSED (was R9)

*Revised. An earlier revision of this section recommended dropping 1000 mb; that conclusion was
drawn from Arizona figures alone and did not generalise.*

Evidence: `Data/scratch/d1_byres_1000mb_*.png`.

At 2.5° the 1000 mb field is smooth and broad. At 1.0° it breaks into closed contour blobs over the
Mogollon Rim and Colorado Plateau; at 0.5° and 0.25° it is a tangle. That is ERA5's below-ground
extrapolation tracing terrain, and a finer grid resolves the artifact more sharply — 1000 mb is the
one level that gets *worse* as resolution improves.

**But that is a Western problem, not a general one.** 1000 hPa sits near 110 m in a standard
atmosphere, so over the eastern coastal plain and most of the Southeast the level is at or just
above the surface and reads as a near-equivalent of SLP: surface highs and lows, frontal passage,
the post-frontal pressure rise that drives dry windy days in the east. The pathology in the AZ
figures reflects the *severity* of the extrapolation over 1,000–2,500 m terrain, not its existence.
The app carries a state selector for all 50 states; a level cannot be dropped on Southwest evidence.

**Resolution: mask, don't drop.** Pull ERA5's static surface geopotential once — a single
time-invariant field, one request for the whole record — and blank any cell where the level's
geopotential height falls below the model terrain height. The map goes empty over the interior West
instead of drawing terrain as weather, and stays valid everywhere it is valid, including over the
Appalachians. Cost: one request, ~13 KB, zero runtime overhead. Applied at build time.

An earlier draft of this fix proposed daily `surface_pressure` for a time-varying mask. Unnecessary:
comparing the level's own height against terrain height uses data already being pulled, and saves
33 requests.

Consequence: the `weatherMaps` bug at `app.R` L422 (`if (gh500) gh500 else gh700`, silently dropping
the third option) is still a real bug and still needs fixing in phase 5.

### D7 — Snapshot hour: **keep 18Z.** CLOSED

ERA5 is hourly so this was free to change, and 18Z is 11:00 MST — before the afternoon burning
period, so 21Z or 00Z would arguably frame fire weather better. Rejected in favour of continuity
with the 1992–2020 R2 record and previously published figures. Worth revisiting only if the R2
comparison in phase 6 shows the record is not comparable anyway.

### D8 — Additional variables: **six, from the derived daily-statistics entry.** CLOSED

`util/probe_derived.R` confirmed that `derived-era5-single-levels-daily-statistics` honours both
`area` and `grid` — 81 × 41 rather than 1440 × 721, a 55× reduction — despite neither parameter
appearing in ECMWF's documentation or API example. Daily max/min variables therefore cost the same
as the heights, and the app can carry fire-weather fields it has never had.

| Variable | ERA5 name | Statistic | Encoding | Why |
|---|---|---|---|---|
| 2 m temperature | `2m_temperature` | `daily_max` | int8 anom @ 0.25 K | with dewpoint → VPD, RH, dewpoint depression |
| 2 m dewpoint | `2m_dewpoint_temperature` | `daily_min` | int8 anom @ 0.25 K | " |
| 10 m wind gust | `10m_wind_gust_since_previous_post_processing` | `daily_mean` | int8 @ 0.25 m s⁻¹ | unbiased windiness of the burning period (D10) |
| 10 m wind gust | `10m_wind_gust_since_previous_post_processing` | `daily_max` | int8 @ 0.25 m s⁻¹ | blow-up days; carries the D10 low bias |
| CAPE | `convective_available_potential_energy` | `daily_max` | **int16** — see note | with PWAT → dry-lightning signature |
| Total column water vapour | `total_column_water_vapour` | `daily_mean` | int8 @ 0.3 kg m⁻² | monsoon surges; the other half of dry lightning |
| Volumetric soil water L1 | `volumetric_soil_water_layer_1` | `daily_mean` | int8 @ 0.0025 m³ m⁻³ | fuel dryness from the land surface |
| *(surface geopotential)* | `geopotential`, static | — | not shipped | the D6 mask |

**CAPE needs int16 or a non-linear transform.** It is strongly right-skewed (0 to 5,000+ J kg⁻¹);
int8 linear at 20 J kg⁻¹ steps tops out at 2,540 and would clip real values. Either store int16
(76 MB resident) or int8 on a square-root scale. Decide in phase 2 and record the transform in
`meta`.

Max-T with min-Td approximates peak-afternoon dryness. Honest caveat: minimum RH is not directly
available and the two extremes do not always coincide, so this slightly overstates dryness. It is a
proxy, not an observation.

Derived from these at render time, never stored: RH, VPD, dewpoint depression, 1000–500 mb thickness.

### D9 — Daily aggregation window: **UTC−07:00 (MST).** CLOSED

The derived entry can compute each statistic over a local day rather than 00–00 UTC, and
`time_zone = "utc-07:00"` was confirmed accepted. MST matches the app's AZ default and the interior
West, where most extreme fire-count days occur.

One archive can only carry one window, so this is wrong by up to 3 h on the east coast. A daily
max or min is fairly insensitive to that, and the alternative — UTC — splits the western afternoon
burning period across two calendar days, which is the worst case for exactly the days the app
exists to examine. Record the offset in `meta` so it is never ambiguous.

Note this **decouples from D7**: heights stay 18Z instantaneous for continuity with the R2 record;
the new variables have no legacy record to match and use MST daily statistics. Mixed sampling across
variables is fine, and is documented per variable in `meta`.

### D10 — Sampling frequency: **3-hourly.** CLOSED

The derived entry builds each daily statistic from a subsample of the underlying hourly data, set by
`frequency`. This drives both the CDS cost limit and the wall-clock: 3-hourly cuts server-side reads
to a third, taking phase 1 from roughly two days to roughly 14 hours.

Measured, not assumed — `util/bench_gust_sampling.R` pulled two months of full hourly gust from the
*archived* hourly entry and recomputed the daily statistics using the exact UTC hours the adaptor
samples (02,05,…,23 for 3-hourly at `utc-07:00`; 05,11,17,23 for 6-hourly).

| statistic | domain bias | AZ Apr | AZ Jul | short-peak days |
|---|---|---|---|---|
| **daily mean, 3-hourly** | **0.00%** | −0.19% | 0.50% | ~1% |
| daily max, 3-hourly | 2.4% | 1.5% | 3.2% | 13–18% |
| daily max, 6-hourly | 6.4% | 3.2% | 9.0% | 23–37% |

**A mean is a fair sample of the day; a maximum only sees the single highest sample.** So mean gust
is effectively exact at 3-hourly (0.6% typical error, 0.02% of cell-days off by >10%) while max gust
is systematically low, worst on days whose peak lasts under two hours — convective outflow and
frontal gust fronts. Contrary to expectation the bias does *not* concentrate on the windiest days
(2.6% on the top decile domain-wide, 3.7% over AZ in July): the largest gusts at 1° come from
long-duration synoptic events, which sample well.

6-hourly is rejected. Beyond the 9% AZ July bias, it samples 05/11/17/23 UTC — 22:00, 04:00, 10:00
and 16:00 MST — bracketing the afternoon burning period without landing in it.

Consequence for D8: **carry gust twice**, as `daily_mean` and `daily_max`. The mean is the unbiased
windiness index; the max flags blow-up days with a documented ~3% low bias. Taking both now rather
than later matters because of R11 — the derived product is not archived, so a top-up pull months
from now may not be numerically consistent with this one.

---

## 5. Target data architecture

### Layout

```
Data/
  README.md                       # tracked; fill in the TODOs as part of this work
  grids/
    hgt500_archive_1992_2024.qs2  # frozen; regenerated only on ERA5 version change
    hgt500_current.qs2            # appendable, current year
    hgt700_archive_1992_2024.qs2  # + _current
    hgt1000_archive_1992_2024.qs2 # + _current; below-ground cells masked (D6)
    orography.qs2                 # static, ~13 KB — the D6 mask
    precip14_archive_1992_2024.qs2   # + _current
    precip90_archive_1992_2024.qs2   # + _current
    t2max_archive_1992_2024.qs2      # D8, one file per variable, + _current
    d2min_archive_1992_2024.qs2
    gustmax_archive_1992_2024.qs2
    capemax_archive_1992_2024.qs2
    pwatmean_archive_1992_2024.qs2
    soilw1mean_archive_1992_2024.qs2
  fod/
    fod_archive_1992_2024.qs2
    fod_current.qs2               # WFIGS year-to-date, via util/currYrFireHelperFunc.R
```

The archive/current split is the "readily updated" requirement: an annual refresh regenerates a
~1 MB file, not a 36 MB one.

### On-disk object — **REVISED**

Drop GeoTIFF entirely. `data` **must be a `raw` vector, not an integer matrix** — see §3. This is
the single most important change from draft 1.

```r
list(
  meta = list(
    var     = "hgt", level = 500, units = "m",
    source  = "ERA5", hour_utc = 18L,
    dtype   = "int8_anom",          # raw byte = (value - ref) / step + 128
    step    = 5, ncell = 3321L,
    nx = 81L, ny = 41L,
    xmin = -140, xmax = -60, ymin = 20, ymax = 60,
    crs = "EPSG:4326",
    built = as.Date("2026-..-.."), builder_version = "1.0"
  ),
  dates = <Date[nt]>,
  ref   = <double[ncell]>,          # per-cell climatology, added back on decode
  mask  = <int[ncell_valid] | NULL>,
  data  = <raw[ncell_valid * nt]>   # cell-major: one contiguous block per day
)
```

`qs2::qs_save(..., compress_level = 19, nthreads = 4)`. Measured: 13.6 s to pack, **0.12 s to
load**, 38.2 MB resident per level.

### Accessor

```r
#' @return data.frame(x, y, Date, value) ready for ggplot
read_grid_long <- function(handle, dates)
```

`match()` on the date vector, slice the contiguous byte ranges, `as.integer()`, apply step and
`ref`, join the cached coordinate frame. Measured at 0–20 ms for 12–30 days, against 440–640 ms
for the current `terra` → `as.data.frame` → `pivot_longer` chain — while returning 6× more rows.

**Be honest about what this buys.** It is a 440 ms saving on a render that takes 3,160 ms. Real,
worth doing, and not the reason the app feels slow. Draft 1 claimed otherwise.

---

## 6. Render performance — NEW, and independent of ERA5

`bench_render_opts.R` measured the draw itself. The Extreme Fire Days map takes **3–8 seconds to
render**, and more than half of that is ggplot building grobs rather than the device rasterising
them. The cause is that the app hands ggplot the entire CONUS precip grid (~7,662 cells per facet)
and all ~15k `us_states` path points, draws them in every facet, and only then clips with
`coord_fixed`. The AZ + 2° window shows roughly 320 precip cells and a handful of states.

### 6.1 The fix

Four cumulative changes, measured at 12 and 30 facets against both today's grids and the 1.0°
target:

| | today 12f | today 30f | 1.0° 12f | 1.0° 30f |
|---|---|---|---|---|
| baseline | 3,160 | 7,760 | 2,110 | 6,370 |
| + filter precip fill to view | 2,280 | 5,450 | 1,920 | 5,660 |
| + filter state outlines to view | — * | 3,100 | 1,340 | 3,890 |
| + `geom_raster` for the fill | 2,650 | 2,860 | 1,330 | 3,120 |
| + filter contour input to view | **980** | **2,370** | **950** | **2,000** |

\* one measurement in that cell came back slower than its own baseline, which is impossible;
treat it as an outlier. Absolute times vary ~50% between runs — the same baseline measured 7,050 /
10,485 / 3,160 ms on three occasions. **Compare within a run, never across.** The ratios were
stable at 2.2–3.3× on all three.

### 6.2 Two correctness constraints, both learned the hard way

1. **You cannot filter the data behind an unpinned scale.** `color = after_stat(level)` has no
   explicit `limits`, so filtering the contour input retrains it on a narrower range and recolours
   every line. The first benchmark run failed on exactly this. Fix: pin
   `scale_color_gradientn(limits = )`. `scale_fill_gradientn` survived only because `app.R` already
   hard-codes `limits = c(0, 200)`.
   *This is a latent bug in the current app*: the contour colour scale retrains on every render, so
   the same 5,800 m contour takes a different colour depending on which days are selected.
2. **Filter state outlines by whole group, never by vertex.** Dropping individual vertices leaves
   `geom_path` connecting the survivors across the gap, drawing false straight lines across the map.

Verification: every variant is rendered to PNG and diffed against the baseline. The raw pixel count
is *not* the test — swapping `geom_tile` for `geom_raster` redraws every cell boundary and reads
~9% differing on an identical picture. The test is whether any differing region survives a 3×3
erosion. Measured: 0.000%.

---

## 7. Work breakdown — REORDERED

Phase 1 moved to the front because it has days of wall-clock latency that parallelise with
everything else. Phase 0.5 is new and independent of the migration entirely.

| # | Phase | Detail | Est. | Blocked by |
|---|---|---|---|---|
| 1 | **ERA5 acquisition** | `util/build_era5.R`, three request loops: (a) hourly pressure-levels, 500/700/1000 mb, 18Z, 33 requests; (b) derived daily statistics, 3 statistic groups × 33 = 99 requests, `time_zone = utc-07:00`; (c) static orography, 1 request. **133 total.** `area` always set — omit it and longitudes return 0–360 (R8). Retry/resume, checksum manifest. Batch submission via `wf_request_batch`. **Start first.** | 1–1.5 d *(+ CDS queue, days of wall-clock)* | — |
| 0.5 | **Render fix** | §6.1 in `app.R`. Ships value immediately, no ERA5 dependency. Fold into the phase 5 `fire_wx_map()` helper rather than doing it twice. | 0.5 d | — |
| 2 | **Codec + format library** | `util/gridpack.R`: `pack_grid()` / `read_grid_long()`, **raw storage and lazy per-variable loading per §5**, anomaly + quantise + mask + `qs2`. Settle the CAPE encoding (D8). Round-trip unit tests. | 1–2 d | — |
| 3 | **FOD 7th edition** | Rewrite `util/thinFOD.R` for `FPA_FOD_20260615`. **Verify column names first.** Re-derive `OPERATION_DAYS`, `FIRE_SIZE_CLASS`. **Measure resident size early** — it is the biggest unknown in §3. | 0.5–1 d | — |
| 4 | **Precip re-encode** | Extend `util/gridINT.R` → uint8 @ 2%, keep 0.5°, land mask, `qs2`, extend to 2024. | 0.5 d | D5 |
| 5 | **`app.R` refactor** | One `filteredFires()` reactive, one `fire_wx_map()` carrying the §6.1 filtering and the pinned colour scale. | 2 d | 2, 4 |
| 6 | **Validation** | R2-vs-ERA5 overlap over 1992–2020; quantisation round-trip; visual diff old vs new. | 1 d | 1, 2 |
| 7 | **Docs + deploy** | `Data/README.md`, `util/build_data.R` entry point, `renv::snapshot()`, deploy test. | 0.5 d | all |

**Total: ~7–9 working days**, with CDS queue time running under phases 0.5 and 2–4.

`ecmwfr`, `ncdf4`, `qs2` and `png` are not in `renv.lock`. Install them, but **do not
`renv::snapshot()` until phase 7** — only `qs2` is an app runtime dependency; the rest are
build-time only.

---

## 8. Coupled refactor (why phase 5 is 2 days)

From the earlier review of `app.R`:

- The filter chain (state → year → operation days → month → cause → size class → percentile) is
  copy-pasted **three times** — `fireMap` (L162–192), `fireDaysTable` (L356–383), `weatherMaps`
  (L434–460). They have already drifted: `fireSummaryPlot` (L297) ignores year, month, cause and
  operation-day filters entirely.
- The ~25-line ggplot block appears twice, byte-identical apart from the data source.
- `FIRE_SIZE_RANK` is computed *after* filtering (L187, L304, L378), so the percentile is relative
  to the current subset rather than the full record. **Open question 4.**
- `weatherMaps` L422 silently drops the 1000 mb option — **resolved by D6**, which removes the
  level.
- The contour colour scale is unpinned — see §6.2.

Note for phase 5: `subset()` on `OPERATION_DAYS` drops fires with no `CONT_DATE`, because the
comparison yields `NA`. That is current behaviour and `era5_compare.R` reproduces it deliberately.
Decide whether it is intended before collapsing the chains.

---

## 9. Risks

| | Risk | Status |
|---|---|---|
| R1 | R2 discontinued | **CLOSED** 2026-08-07. Migration required. |
| R2 | **ERA5 ≠ R2.** Different model, resolution, topography. Maps will not match published figures. | **OPEN.** Phase 6 overlap comparison. Budget time to look at it seriously. |
| R3 | ERA5 `z` is geopotential (m² s⁻²), not height | **CLOSED.** `/ 9.80665` verified; 500 mb lands in range at all three grids. Assert stays in the build script. |
| R4 | CDS `grid` may not be honoured | **CLOSED.** Honoured at 1.0/0.5/0.25°. |
| R5 | CDS queue times unpredictable | **OPEN.** Mitigated by moving phase 1 first. |
| R6 | FPA-FOD 7th ed. column names may differ | **OPEN.** Inspect schema before writing phase 3. |
| R7 | `qs2` must build on the deploy target | **OPEN.** Depends on open question 6. |
| R8 | Longitude convention (0–360 vs ±180) | **CLOSED.** `area` returns ±180; extent asserted. |
| R9 | 1000 mb below ground over the interior West | **CLOSED** by D6 — level dropped. |
| R10 | ~~Deployed RAM ceiling~~ | **CLOSED 2026-08-07.** The app's Connect runtime panel shows **Max RAM (GiB) = 0 — no limit**. The 1 GB previously hit is the **bundle** cap on disk, which the design meets at ~275 MB. RAM is not policy-constrained. |
| R13 | **Server citizenship.** Max processes is overridden to 7 and RAM is uncapped, so 7 warm processes each hold their own copy of everything at the top of `app.R`. Nothing stops a runaway process from degrading the shared server. | **NEW, OPEN.** Reduce Max processes to 2–3, set a Max RAM override as a safety net, and keep lazy loading — now justified by startup time and courtesy rather than a hard cap. |
| R14 | **Cold starts.** Initial timeout is overridden 60 → 240 s because startup loads 276 MB of GeoTIFFs and FOD; Idle timeout is 5 s, so processes die almost immediately and most visitors pay that cost. | **NEW, OPEN.** Fixed by the same lazy `qs2` loading. *Acceptance test for phase 5: Initial timeout returns to the 60 s default.* Then raise Idle timeout so warm processes survive short gaps. |
| R11 | **Derived daily statistics are computed at retrieval, not archived.** Re-running the same request later can return different values as ERA5T is replaced by ERA5. | **NEW, OPEN.** Build the archive once, checksum it, never regenerate. Makes the "rebuild from scratch" path in `Data/README.md` non-deterministic in a way the pressure-level pull is not — say so in the README. |
| R12 | **The derived product is young and moving.** ECMWF fixed an incorrect time alignment on 2026-07-30 affecting `10m_wind_gust_since_previous_post_processing` and the max/min 2 m temperature variables — values were shifted +1 h against the requested time zone. | **NEW, OPEN.** Our pull post-dates the fix. Record the build date in `meta`; check the CDS known-issues page before any rebuild. |

---

## 10. Open questions for Mike

1. ~~D1 resolution~~ — **closed: 1.0°**
2. **D2** — ERA5 vs CORe: does provenance (US federal vs ECMWF) matter for your audience or funding?
   This is the last open decision that could change the acquisition plan.
3. ~~Snapshot hour~~ — **closed: 18Z for heights, MST daily statistics for the D8 variables**
4. Is the **fire size percentile** meant to rank within the current filtered subset, or against the
   full record? (§8) Affects phase 5 only.
5. ~~Keep 1000 mb~~ — **closed: keep, masked below ground**
6. ~~Where does the deployed app live~~ — **closed: Posit Connect at
   `viz.datascience.arizona.edu`.** Bundle cap 1 GB on disk (the one previously hit); runtime RAM
   uncapped. Design lands at ~275 MB of data, so **disk is comfortable and RAM is not
   policy-constrained.** R7 still applies — `qs2` must install on that server. See R13/R14 for what
   the runtime settings do imply.
7. **How should the six new variables surface in the UI?** They do not fit the existing
   height-level selector. Options: a second "overlay" selector alongside the height contours, a
   separate tab, or a small-multiples panel. Not blocking phases 1–4, but it shapes phase 5.

---

## Appendix A — phase 0 artifacts

| File | What it does |
|---|---|
| `util/era5_common.R` | Shared helpers with no plotting dependencies, so phase 1 can run on a headless box. See `SERVER_SETUP.md`. |
| `build/` | Build-server entry points, systemd units, bootstrap and transfer scripts. Phase 1 onward runs on the M710q, not the laptop. |
| `util/era5_compare.R` | D1 gate. Ranks AZ fire days with `fireMap`'s logic, pulls ERA5 at three grids (resumable), validates units/extent/grid, renders the comparison figures. |
| `util/bench_1deg.R` | Codec size, load time, resident RAM; accessor vs `terra` path; render cost at three grid combinations. |
| `util/bench_render_opts.R` | Render optimisation ladder, layer ablation, build-vs-draw split, pixel-diff correctness check. |
| `util/probe_derived.R` | Seven-variant probe of the derived daily-statistics entry: `area`, `grid`, request keys, zip/netCDF delivery, local time zone, and the pressure-levels daily entry. |
| `Data/scratch/probe_derived/probe_derived_results.csv` | The D8/D9 evidence. |
| `Data/scratch/D1_REPORT.md` | Grid-honoured verification, height ranges. |
| `Data/scratch/BENCH_1DEG.md` | Startup / access / render numbers. |
| `Data/scratch/BENCH_RENDER.md` | The §6.1 ladder. |
| `Data/scratch/d1_*.png` | The D1 decision figures. |

---

## Appendix B — sources

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
