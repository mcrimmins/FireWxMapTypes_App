# Data

Files in this directory are **not tracked in git** — the collection is ~276 MB and two
files exceed GitHub's 100 MB per-file hard limit. This README is the only tracked file
here, and it exists so the data can be located or regenerated.

`.gitignore` uses:

```
Data/*
!Data/README.md
```

The app expects these files to be present at runtime. `rsconnect::deployApp()` bundles
from disk rather than from git, so deployments include them normally.

---

## Contents

| File | Size | Description |
|---|---|---|
| `CPC_Global_precip_14dyPercAvg_1992_2020_CONUS_INT.tif` | 109 MB | 14-day precipitation percent-of-average, CONUS. Integer-scaled GeoTIFF. |
| `CPC_Global_precip_90dyPercAvg_1992_2020_CONUS_INT.tif` | 87 MB | 90-day precipitation percent-of-average, CONUS. Integer-scaled GeoTIFF. |
| `R2_hgt_500mb_1992_2020_CONUS.tif` | 15 MB | 500 mb geopotential height, CONUS. |
| `R2_hgt_700mb_1992_2020_CONUS.tif` | 15 MB | 700 mb geopotential height, CONUS. |
| `R2_hgt_1000mb_1992_2020_CONUS.tif` | 15 MB | 1000 mb geopotential height, CONUS. |
| `FODthin.Rdata` | 34 MB | Thinned wildfire occurrence records. |

Total: 6 files, 276 MB.

---

## Sources

### CPC precipitation percentiles

Derived from the **CPC Global Unified Gauge-Based Analysis of Daily Precipitation**
(NOAA PSL), 1992–2020 climatological baseline.

- Source: https://psl.noaa.gov/data/gridded/data.cpc.globalprecip.html
- Native resolution: 0.5° × 0.5°, daily
- Processing: TODO — describe the aggregation to 14-day and 90-day windows, the
  percent-of-average calculation against the 1992–2020 normals, the CONUS crop, and
  the integer scaling factor applied (the `_INT` suffix).
- Scaling factor: TODO — record the multiplier needed to recover float values.
- Generating script: TODO — path under `util/`, if one exists.

### NCEP/NCAR Reanalysis 2 geopotential heights

Derived from **NCEP-DOE Reanalysis 2** (NOAA PSL), 1992–2020.

- Source: https://psl.noaa.gov/data/gridded/data.ncep.reanalysis2.html
- Variable: geopotential height (`hgt`) at 500, 700, and 1000 mb
- Native resolution: 2.5° × 2.5°
- Processing: TODO — describe the temporal aggregation, any anomaly or standardization
  step, the CONUS crop, and the band structure of the resulting GeoTIFFs.
- Generating script: TODO — path under `util/`, if one exists.

### FODthin.Rdata

Thinned subset of a wildfire occurrence database — most likely the **Fire Program
Analysis Fire-Occurrence Database (FPA-FOD)**, Short (USFS Research Data Archive).

- Source: TODO — confirm and record the exact dataset and version DOI.
- Thinning criteria: TODO — record the filters applied (date range, fire size
  threshold, geographic extent, columns retained). Commit `3dd0a4c` "thinned data
  files" is the relevant history.
- Object name(s) loaded by `load()`: TODO
- Generating script: TODO — path under `util/`, if one exists.

---

## Regenerating

TODO — once the processing scripts are identified or rewritten during the overhaul,
document the run order here so a fresh clone can rebuild `Data/` from scratch. Ideally
this becomes a single `util/build_data.R` that downloads the source grids and writes
every file above.

## Obtaining a copy directly

TODO — record where a ready-made copy lives (university shared storage, OneDrive,
external drive) so a collaborator can skip regeneration.

---

## Notes

- Coordinate reference system: TODO — confirm and record for the GeoTIFFs.
- If any of these files are regenerated with a different scaling, extent, or CRS, the
  plotting code in `app.R` and `util/` will need matching updates.
- Last verified: 2026-08-07
