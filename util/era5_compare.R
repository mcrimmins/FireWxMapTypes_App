# util/era5_compare.R
# -----------------------------------------------------------------------------
# D1 RESOLUTION GATE — ERA5 geopotential height resolution comparison
# See ERA5_MIGRATION_SCOPE.md sections 4 (D1), 3 (size budget), 9 (R3, R4, R8, R9).
#
# What this does:
#   1. Picks the top AZ fire days from Data/FODthin.Rdata using the SAME ranking
#      logic as the fireMap output in app.R (L162-210).
#   2. Pulls ERA5 geopotential (z) at 500/700/1000 mb, 18Z, 20-60N / 140-60W,
#      from the Copernicus CDS via ecmwfr, at three grids: 1.0, 0.5, 0.25 deg.
#      Uses the CDS `grid` parameter for server-side regridding and REPORTS
#      WHETHER IT WAS HONOURED (open question R4 — determines whether the full
#      33-year pull is ~0.5 GB or ~7.5 GB).
#   3. Converts z (m2 s-2) -> geopotential height (m) by / 9.80665 and asserts
#      the 500 mb result lands in 4500-6100 m (R3).
#   4. Renders the app's existing map style (precip fill + height contours +
#      fire points + state outlines) at each resolution, plus the current R2
#      2.5 deg data as a baseline, to PNGs in Data/scratch/.
#   5. Tests whether binwidth = 10 in geom_contour still reads at finer grids.
#
# HOW TO RUN (RStudio, project root as working directory):
#   source("util/era5_compare.R")
# or, to run only some phases:
#   ERA5_CMP_RUN_ON_SOURCE <- FALSE; source("util/era5_compare.R")
#   main(steps = c("select"))
#   main(steps = c("download", "validate"))
#   main(steps = c("render"))
#
# RESUMABLE: every downloaded file is cached under Data/scratch/era5_cache/ and
# skipped on re-run if it opens cleanly. The selected day list is cached too, so
# re-runs use identical dates. Nothing is re-requested from CDS unnecessarily.
#
# PREREQ: neither ecmwfr nor ncdf4 is in renv.lock yet, so in the project:
#           renv::install(c("ecmwfr", "ncdf4"))
#         (ecmwfr >= 1.5 for the new CDS; 2.x preferred.) Do NOT renv::snapshot()
#         until after D1 is decided — these are build-time, not app, deps.
#         .Renviron already has CDS_KEY — that is picked up automatically.
#         On the new CDS (cds.climate.copernicus.eu) the key is a single
#         Personal Access Token. On the legacy CDS it was "UID:APIKEY".
#         You must also have accepted the ERA5 licence in your CDS profile,
#         otherwise requests fail with a licence error.
#
# MAC / drafted with Claude, 2026-08
# -----------------------------------------------------------------------------

# ============================ CONFIG =========================================

CFG <- list(
  # --- fire day selection (mirrors app.R fireMap defaults) ---
  states          = "AZ",
  n_days          = 10,          # ~10 days is all D1 needs
  sort_metric     = "count",     # "count" or "area" — app.R default is "count"
  month_range     = c(1, 12),
  cause           = "All",
  size_classes    = NULL,        # NULL = all classes (app default)
  pctile          = c(0, 100),
  seed            = 42,          # FIRE_SIZE_RANK uses ties.method="random"

  # --- ERA5 request ---
  levels_mb       = c(500, 700, 1000),
  resolutions     = c(1.0, 0.5, 0.25),
  hour_utc        = 18,
  # CDS `area` is N, W, S, E in +/-180 longitude convention (R8)
  area            = c(60, -140, 20, -60),
  dataset         = "reanalysis-era5-pressure-levels",

  # --- comparison / rendering ---
  include_r2_baseline = TRUE,    # reads Data/R2_hgt_*.tif — no download
  precip_var      = "precip90",  # "precip14" or "precip90" (app default 90)
  expd_app        = 2,           # app.R default extent padding, deg
  expd_wide       = 6,           # wider synoptic view for the res comparison
  n_compare_days  = 3,           # how many days get a per-day res comparison
  binwidths       = c(10, 30, 60),  # contour interval sweep

  # --- plumbing ---
  use_batch       = TRUE,        # parallel CDS submission if ecmwfr supports it
  batch_workers   = 4,
  force_reselect  = FALSE,       # TRUE re-runs the fire day ranking
  scratch         = "./Data/scratch",
  cache_dir       = "./Data/scratch/era5_cache",
  fig_dpi         = 130
)

if (!exists("ERA5_CMP_RUN_ON_SOURCE")) ERA5_CMP_RUN_ON_SOURCE <- TRUE

# G0, HGT_RANGE, msg, need_pkgs, %||%, require_project_root, ecmwfr_major,
# setup_cds and the notify* helpers now live in era5_common.R, which carries no
# plotting dependencies so that build_era5.R can use them on a headless server.
source("util/era5_common.R")

R2_LAB <- "2.50° (R2, current app)"   # baseline panel label
R2_TAG <- "2p50_R2"

# ============================ DEPENDENCIES ===================================
# This script — unlike the build pipeline — is a figure generator, so the
# plotting stack is a hard requirement here and only here.

suppressPackageStartupMessages({
  library(ggplot2)
  library(dplyr)
  library(maps)
})

res_tag <- function(r) sub("\\.", "p", sprintf("%.2f", r))       # 0.25 -> "0p25"
res_lab <- function(r) sprintf("%.2f°", r)                   # 0.25 -> "0.25°"

ensure_dirs <- function() {
  for (d in c(CFG$scratch, CFG$cache_dir)) {
    if (!dir.exists(d)) dir.create(d, recursive = TRUE)
  }
  invisible(TRUE)
}

# ==================== STEP 1: SELECT FIRE DAYS ===============================
# Mirrors app.R fireMap L162-210 exactly, including two behaviours that are easy
# to get wrong:
#   * subset() on OPERATION_DAYS drops rows where CONT_DATE is NA, because the
#     comparison yields NA. The app does this, so we do too.
#   * FIRE_SIZE_RANK is computed AFTER filtering, so the percentile is relative
#     to the filtered subset (see scope doc section 7 / open question 4).

load_fod <- function() {
  e <- new.env(parent = emptyenv())
  load("./Data/FODthin.Rdata", envir = e)
  fc <- get("fc", envir = e)
  fc$DISCOVERY_DATE <- as.Date(fc$DISCOVERY_DATE, "%m/%d/%Y")
  fc$CONT_DATE      <- as.Date(fc$CONT_DATE, "%m/%d/%Y")
  fc$OPERATION_DAYS <- as.numeric(fc$CONT_DATE - fc$DISCOVERY_DATE) + 1
  fc$DISCOVERY_YEAR <- as.numeric(format(fc$DISCOVERY_DATE, "%Y"))
  fc
}

select_fire_days <- function(cfg = CFG) {
  fc <- load_fod()

  # slider defaults, exactly as app.R computes them from the full record
  op_rng <- range(fc$OPERATION_DAYS, na.rm = TRUE)
  yr_rng <- range(fc$DISCOVERY_YEAR, na.rm = TRUE)
  size_classes <- cfg$size_classes %||% sort(unique(fc$FIRE_SIZE_CLASS))

  fireData <- subset(fc,
                     STATE %in% cfg$states &
                       DISCOVERY_YEAR  >= yr_rng[1] &
                       DISCOVERY_YEAR  <= yr_rng[2] &
                       OPERATION_DAYS  >= op_rng[1] &
                       OPERATION_DAYS  <= op_rng[2])

  fireData <- fireData %>%
    filter(format(DISCOVERY_DATE, "%m") %in%
             sprintf("%02d", cfg$month_range[1]:cfg$month_range[2]))

  if (!identical(cfg$cause, "All")) {
    fireData <- fireData %>% filter(NWCG_CAUSE_CLASSIFICATION == cfg$cause)
  }
  fireData <- fireData %>% filter(FIRE_SIZE_CLASS %in% size_classes)

  if (nrow(fireData) == 0) stop("No fire data for the selected filters.", call. = FALSE)

  set.seed(cfg$seed)   # ties.method = "random" — pin it so re-runs match
  fireData$FIRE_SIZE_RANK <-
    (rank(fireData$FIRE_SIZE, na.last = "keep", ties.method = "random") /
       nrow(fireData)) * 100

  fireData <- fireData %>%
    filter(FIRE_SIZE_RANK >= cfg$pctile[1], FIRE_SIZE_RANK <= cfg$pctile[2])

  fireDays <- fireData %>%
    group_by(DISCOVERY_DATE) %>%
    summarise(FireCount = n(), TotalArea = sum(FIRE_SIZE, na.rm = TRUE),
              .groups = "drop") %>%
    arrange(desc(FireCount))
  names(fireDays)[1] <- "Date"

  fireDays <- if (cfg$sort_metric == "count") {
    fireDays[order(fireDays$FireCount, decreasing = TRUE), ]
  } else {
    fireDays[order(fireDays$TotalArea, decreasing = TRUE), ]
  }

  selectDays <- unique(stats::na.omit(fireDays$Date))[seq_len(cfg$n_days)]
  selectDays <- selectDays[!is.na(selectDays)]

  fireSub <- fireData %>% filter(DISCOVERY_DATE %in% selectDays)
  fireSub$Date <- factor(fireSub$DISCOVERY_DATE, levels = as.character(selectDays))

  list(dates    = as.Date(selectDays),
       fires    = fireSub,
       day_rank = fireDays[seq_len(min(30, nrow(fireDays))), ])
}

days_file  <- function() file.path(CFG$scratch, "era5_compare_days.csv")
fires_file <- function() file.path(CFG$scratch, "era5_compare_fires.rds")

step_select <- function(cfg = CFG) {
  if (!cfg$force_reselect && file.exists(days_file()) && file.exists(fires_file())) {
    d <- utils::read.csv(days_file(), stringsAsFactors = FALSE)
    msg("Reusing cached day selection (", nrow(d), " days). ",
        "Set CFG$force_reselect <- TRUE to redo it.")
    return(list(dates = as.Date(d$Date), fires = readRDS(fires_file())))
  }
  msg("Ranking fire days: ", paste(cfg$states, collapse = "/"),
      ", metric = ", cfg$sort_metric, ", n = ", cfg$n_days)
  sel <- select_fire_days(cfg)
  utils::write.csv(
    data.frame(Date = format(sel$dates, "%Y-%m-%d"),
               Rank = seq_along(sel$dates)),
    days_file(), row.names = FALSE)
  saveRDS(sel$fires, fires_file())
  print(as.data.frame(sel$day_rank[seq_len(min(cfg$n_days, nrow(sel$day_rank))), ]))
  sel
}

# ==================== STEP 2: DOWNLOAD ERA5 ==================================

nc_target <- function(res, date) {
  sprintf("era5_z_%s_%s.nc", res_tag(res), format(date, "%Y%m%d"))
}

# A cached file counts as done only if it opens and contains z with >0 cells.
nc_is_good <- function(path) {
  if (!file.exists(path) || file.size(path) < 1000) return(FALSE)
  ok <- tryCatch({
    nc <- ncdf4::nc_open(path)
    on.exit(ncdf4::nc_close(nc))
    any(c("z", "Z") %in% names(nc$var))
  }, error = function(e) FALSE)
  isTRUE(ok)
}

build_request <- function(res, date, variant = 1L) {
  base <- list(
    dataset_short_name = CFG$dataset,
    product_type   = "reanalysis",
    variable       = "geopotential",
    pressure_level = as.character(CFG$levels_mb),
    year   = format(date, "%Y"),
    month  = format(date, "%m"),
    day    = format(date, "%d"),
    time   = sprintf("%02d:00", CFG$hour_utc),
    area   = CFG$area,               # N, W, S, E  (+/-180)
    target = nc_target(res, date)
  )
  # Variants exist because the post-2024 CDS renamed some request keys and is
  # picky about types. They are tried in order until one succeeds.
  switch(variant,
    # 1: new CDS (data_format / download_format), numeric grid
    c(base, list(grid = c(res, res),
                 data_format = "netcdf", download_format = "unarchived")),
    # 2: new CDS, character grid (some adaptor versions want strings)
    c(base, list(grid = as.character(c(res, res)),
                 data_format = "netcdf", download_format = "unarchived")),
    # 3: legacy CDS key name
    c(base, list(grid = c(res, res), format = "netcdf")),
    # 4: no grid at all -> native 0.25 deg. If this is the ONLY variant that
    #    works, `grid` is not honoured and R4's fallback applies.
    c(base, list(data_format = "netcdf", download_format = "unarchived"))
  )
}

submit_one <- function(res, date, user, path) {
  target <- nc_target(res, date)
  dest   <- file.path(path, target)
  if (nc_is_good(dest)) {
    msg("  cached: ", target)
    return(list(ok = TRUE, variant = NA_integer_, cached = TRUE))
  }
  if (file.exists(dest)) unlink(dest)   # partial/corrupt — refetch

  for (v in 1:4) {
    req <- build_request(res, date, v)
    args <- list(request = req, transfer = TRUE, path = path,
                 verbose = FALSE, time_out = 3600)
    if (!is.null(user)) args$user <- user
    out <- tryCatch(do.call(ecmwfr::wf_request, args),
                    error = function(e) e)
    if (!inherits(out, "error") && nc_is_good(dest)) {
      msg("  got ", target, " (", round(file.size(dest) / 1024), " KB",
          ", request variant ", v, ")")
      return(list(ok = TRUE, variant = v, cached = FALSE))
    }
    if (inherits(out, "error")) {
      msg("  variant ", v, " failed: ", conditionMessage(out))
    }
  }
  msg("  !! all request variants failed for ", target)
  list(ok = FALSE, variant = NA_integer_, cached = FALSE)
}

step_download <- function(dates, cfg = CFG) {
  need_pkgs(c("ecmwfr", "ncdf4"))
  user <- setup_cds()

  # built by hand rather than expand.grid() so the Date class survives
  grid_pairs <- data.frame(
    res  = rep(cfg$resolutions, times = length(dates)),
    date = rep(dates, each = length(cfg$resolutions)))
  grid_pairs$target <- sprintf("era5_z_%s_%s.nc", res_tag(grid_pairs$res),
                               format(grid_pairs$date, "%Y%m%d"))
  grid_pairs$path   <- file.path(cfg$cache_dir, grid_pairs$target)
  pending <- grid_pairs[!vapply(grid_pairs$path, nc_is_good, logical(1)), ]

  msg(nrow(grid_pairs), " (resolution x day) files needed; ",
      nrow(pending), " still to fetch.")
  if (nrow(pending) == 0) return(invisible(grid_pairs))

  # --- try parallel batch submission first (much less wall clock in the queue)
  batched <- FALSE
  if (cfg$use_batch && "wf_request_batch" %in% getNamespaceExports("ecmwfr")) {
    msg("Submitting ", nrow(pending), " requests via wf_request_batch (workers = ",
        cfg$batch_workers, "). CDS queue time is the wall-clock risk here.")
    reqs <- lapply(seq_len(nrow(pending)),
                   function(i) build_request(pending$res[i], pending$date[i], 1L))
    args <- list(request_list = reqs, workers = cfg$batch_workers,
                 path = cfg$cache_dir)
    if (!is.null(user)) args$user <- user
    ok <- tryCatch({ do.call(ecmwfr::wf_request_batch, args); TRUE },
                   error = function(e) { msg("  batch failed: ",
                                             conditionMessage(e)); FALSE })
    if (ok) {
      still <- pending[!vapply(pending$path, nc_is_good, logical(1)), ]
      batched <- nrow(still) == 0
      pending <- still
      if (!batched && nrow(pending)) {
        msg("  ", nrow(pending), " file(s) missing after batch; ",
            "retrying those sequentially.")
      }
    }
  }

  # --- sequential fallback / mop-up, one request at a time, fully resumable
  if (nrow(pending)) {
    for (i in seq_len(nrow(pending))) {
      msg("[", i, "/", nrow(pending), "] ", res_lab(pending$res[i]), " ",
          format(pending$date[i], "%Y-%m-%d"))
      submit_one(pending$res[i], pending$date[i], user, cfg$cache_dir)
    }
  }

  done <- vapply(grid_pairs$path, nc_is_good, logical(1))
  msg(sum(done), "/", nrow(grid_pairs), " files present.")
  if (!all(done)) {
    msg("Missing: ", paste(basename(grid_pairs$path[!done]), collapse = ", "))
    msg("Re-run main(steps = 'download') — completed files are skipped.")
  }
  invisible(grid_pairs)
}

# ==================== STEP 3: READ + VALIDATE ================================

# Reads one ERA5 netCDF into a tidy frame. Handles both the old (level/time)
# and new (pressure_level/valid_time) CDS dimension names, either dimension
# order, and descending latitude.
read_era5_nc <- function(path) {
  need_pkgs("ncdf4")
  nc <- ncdf4::nc_open(path)
  on.exit(ncdf4::nc_close(nc), add = TRUE)

  vname <- intersect(c("z", "Z"), names(nc$var))[1]
  if (is.na(vname)) stop("No 'z' variable in ", basename(path), call. = FALSE)
  v <- nc$var[[vname]]
  dnames <- vapply(v$dim, function(d) d$name, character(1))

  pick <- function(cands) {
    i <- which(dnames %in% cands)
    if (length(i)) i[1] else NA_integer_
  }
  ilon <- pick(c("longitude", "lon", "x"))
  ilat <- pick(c("latitude", "lat", "y"))
  ilev <- pick(c("pressure_level", "level", "plev", "isobaricInhPa"))
  if (is.na(ilon) || is.na(ilat)) {
    stop("Could not identify lon/lat dims in ", basename(path),
         " (dims: ", paste(dnames, collapse = ", "), ")", call. = FALSE)
  }

  lon <- v$dim[[ilon]]$vals
  lat <- v$dim[[ilat]]$vals
  lev <- if (!is.na(ilev)) v$dim[[ilev]]$vals else CFG$levels_mb[1]
  if (max(lev, na.rm = TRUE) > 2000) lev <- lev / 100   # Pa -> hPa

  arr <- ncdf4::ncvar_get(nc, vname, collapse_degen = FALSE)
  nd  <- length(dim(arr))

  slice_level <- function(k) {
    idx <- lapply(seq_len(nd), function(i) {
      if (i == ilon || i == ilat) seq_len(dim(arr)[i])
      else if (!is.na(ilev) && i == ilev) k
      else 1L                       # time, or any other degenerate dim
    })
    m <- do.call(`[`, c(list(arr), idx, list(drop = TRUE)))
    if (ilat < ilon) m <- t(m)      # force [lon, lat]
    m
  }

  out <- lapply(seq_along(lev), function(k) {
    m <- slice_level(k)
    data.frame(
      x     = rep(lon, times = length(lat)),
      y     = rep(lat, each  = length(lon)),
      level = as.integer(round(lev[k])),
      # R3: z is geopotential (m2 s-2). Divide by standard gravity for metres.
      Geopotential_Height = as.vector(m) / G0
    )
  })

  list(df  = do.call(rbind, out),
       lon = lon, lat = lat, lev = lev,
       nx  = length(lon), ny = length(lat))
}

# Builds the grid-honoured report — the answer to R4.
step_validate <- function(dates, cfg = CFG) {
  rows  <- list()
  probs <- character(0)

  for (res in cfg$resolutions) {
    # vectorised rather than vapply(dates, ...) — lapply-family calls strip the
    # Date class from their elements, which would silently break the filenames
    files <- file.path(cfg$cache_dir,
                       sprintf("era5_z_%s_%s.nc", res_tag(res),
                               format(dates, "%Y%m%d")))
    files <- files[file.exists(files)]
    if (!length(files)) {
      probs <- c(probs, paste0(res_lab(res), ": no files downloaded"))
      next
    }
    g <- read_era5_nc(files[1])

    dx <- if (length(g$lon) > 1) abs(diff(sort(g$lon))[1]) else NA_real_
    dy <- if (length(g$lat) > 1) abs(diff(sort(g$lat))[1]) else NA_real_
    exp_nx <- round(abs(cfg$area[4] - cfg$area[2]) / res) + 1
    exp_ny <- round(abs(cfg$area[1] - cfg$area[3]) / res) + 1
    honoured <- isTRUE(abs(dx - res) < 1e-6 && abs(dy - res) < 1e-6)

    # R8 — longitude convention. CDS `area` is +/-180; anything above 180 means
    # the request came back on a 0-360 grid and every map would be empty.
    if (any(g$lon > 180)) {
      probs <- c(probs, paste0(res_lab(res),
                               ": longitudes exceed 180 — 0-360 convention, ",
                               "the domain crop is wrong"))
    }
    if (abs(min(g$lon) - cfg$area[2]) > res || abs(max(g$lon) - cfg$area[4]) > res ||
        abs(min(g$lat) - cfg$area[3]) > res || abs(max(g$lat) - cfg$area[1]) > res) {
      probs <- c(probs, sprintf("%s: extent [%.2f, %.2f, %.2f, %.2f] does not match requested area",
                                res_lab(res), min(g$lon), max(g$lon),
                                min(g$lat), max(g$lat)))
    }

    # R3 — height range assertions, per level
    for (lv in cfg$levels_mb) {
      vals <- g$df$Geopotential_Height[g$df$level == lv]
      if (!length(vals)) {
        probs <- c(probs, paste0(res_lab(res), ": level ", lv, " mb absent"))
        next
      }
      rng <- range(vals, na.rm = TRUE)
      chk <- HGT_RANGE[[as.character(lv)]]
      if (!is.null(chk) && (rng[1] < chk$lo || rng[2] > chk$hi)) {
        m <- sprintf("%s %d mb: heights %.0f-%.0f m outside expected %d-%d m%s",
                     res_lab(res), lv, rng[1], rng[2], chk$lo, chk$hi,
                     if (isTRUE(chk$hard)) "  <-- HARD FAIL (check the /9.80665 conversion)" else "")
        if (isTRUE(chk$hard)) stop(m, call. = FALSE) else probs <- c(probs, m)
      }
      rows[[length(rows) + 1]] <- data.frame(
        resolution = res_lab(res), requested_deg = res,
        actual_dx = dx, actual_dy = dy,
        nx = g$nx, ny = g$ny, expected_nx = exp_nx, expected_ny = exp_ny,
        grid_honoured = honoured,
        level_mb = lv, hgt_min_m = round(rng[1]), hgt_max_m = round(rng[2]),
        file_kb = round(file.size(files[1]) / 1024),
        n_files = length(files),
        total_mb = round(sum(file.size(files)) / 1024^2, 2)
      )
    }
  }

  gridrep <- do.call(rbind, rows)
  if (is.null(gridrep)) stop("Nothing to validate — no files downloaded.", call. = FALSE)
  utils::write.csv(gridrep, file.path(cfg$scratch, "d1_grid_report.csv"),
                   row.names = FALSE)

  cat("\n----- GRID / UNIT VALIDATION -----\n")
  print(gridrep, row.names = FALSE)
  if (length(probs)) {
    cat("\nWARNINGS:\n"); cat(paste0("  - ", probs, collapse = "\n"), "\n")
  } else {
    cat("\nNo warnings. Extent, longitude convention and height ranges all check out.\n")
  }

  # --- the R4 answer, spelled out ---
  hon <- unique(gridrep[, c("resolution", "requested_deg", "actual_dx", "grid_honoured")])
  cat("\n----- R4: IS THE CDS `grid` PARAMETER HONOURED? -----\n")
  for (i in seq_len(nrow(hon))) {
    cat(sprintf("  requested %-6s -> delivered %.3f deg  %s\n",
                hon$resolution[i], hon$actual_dx[i],
                if (isTRUE(hon$grid_honoured[i])) "HONOURED" else "NOT honoured"))
  }
  if (all(hon$grid_honoured)) {
    cat("  => Server-side regridding works. Full pull at the chosen resolution,\n",
        "     ~0.5 GB at 1.0 deg. No local regrid step needed (scope D3).\n", sep = "")
  } else {
    cat("  => `grid` is NOT being applied. The full pull must be done at native\n",
        "     0.25 deg (~7.5 GB one-time) and regridded locally, then discarded.\n",
        "     This is the R4 fallback — build it into util/build_era5.R.\n", sep = "")
  }
  invisible(gridrep)
}

# ==================== STEP 4: RENDER ==========================================

load_precip <- function(dates, cfg = CFG) {
  need_pkgs("terra")
  f <- switch(cfg$precip_var,
    precip14 = "./Data/CPC_Global_precip_14dyPercAvg_1992_2020_CONUS_INT.tif",
    precip90 = "./Data/CPC_Global_precip_90dyPercAvg_1992_2020_CONUS_INT.tif")
  r <- terra::rast(f)
  idx <- which(terra::time(r) %in% dates)
  if (!length(idx)) return(NULL)
  sub <- r[[idx]]
  d <- as.data.frame(sub, xy = TRUE)
  nm <- as.Date(terra::time(sub))
  names(d)[-(1:2)] <- format(nm, "%Y-%m-%d")
  out <- lapply(seq_along(nm), function(i) {
    data.frame(x = d$x, y = d$y, Date = nm[i],
               Precipitation = d[[2 + i]])
  })
  do.call(rbind, out)
}

load_r2 <- function(level_mb, dates) {
  need_pkgs("terra")
  f <- sprintf("./Data/R2_hgt_%dmb_1992_2020_CONUS.tif", level_mb)
  if (!file.exists(f)) return(NULL)
  r <- terra::rast(f)
  idx <- which(terra::time(r) %in% dates)
  if (!length(idx)) return(NULL)
  sub <- r[[idx]]
  d <- as.data.frame(sub, xy = TRUE)
  nm <- as.Date(terra::time(sub))
  out <- lapply(seq_along(nm), function(i) {
    data.frame(x = d$x, y = d$y, Date = nm[i],
               Geopotential_Height = d[[2 + i]])
  })
  do.call(rbind, out)
}

# All ERA5 heights for one level, all resolutions, all days, in one frame.
load_era5_long <- function(level_mb, dates, cfg = CFG) {
  out <- list()
  for (res in cfg$resolutions) {
    for (d in seq_along(dates)) {
      p <- file.path(cfg$cache_dir, nc_target(res, dates[d]))
      if (!nc_is_good(p)) next
      g <- read_era5_nc(p)
      sub <- g$df[g$df$level == level_mb, c("x", "y", "Geopotential_Height")]
      if (!nrow(sub)) next
      sub$Date <- dates[d]
      sub$Res  <- res_lab(res)
      out[[length(out) + 1]] <- sub
    }
  }
  if (!length(out)) return(NULL)
  do.call(rbind, out)
}

precip_label <- function(v) {
  switch(v, precip14 = "14-day Precip (% of Avg)",
            precip90 = "90-day Precip (% of Avg)")
}

# The app's map layers, factored out so every figure below is byte-identical in
# style to app.R L268-289 / L508-529.
map_layers <- function(precip_df, fire_df, fire_stats, xlim, ylim) {
  color_palette <- c("tan4", "tan", "white", "chartreuse2", "chartreuse4")
  breakpoints   <- c(0, 50, 100, 150, 200)
  list(
    geom_tile(data = precip_df, aes(x = x, y = y, fill = Precipitation), alpha = 0.7),
    geom_point(data = fire_df,
               aes(x = LONGITUDE, y = LATITUDE, size = FIRE_SIZE_CLASS),
               shape = 21, fill = "lightgrey", color = "black",
               stroke = 1, alpha = 0.8),
    geom_path(data = us_states_df(), aes(x = long, y = lat, group = group),
              color = "black", linewidth = 0.5),
    if (!is.null(fire_stats))
      geom_label(data = fire_stats,
                 aes(x = xlim[1] + 0.2, y = ylim[2] - 0.2, label = label),
                 inherit.aes = FALSE, hjust = 0, vjust = 1, size = 3,
                 color = "black") else NULL,
    scale_color_gradientn(colors = c("blue", "cyan", "yellow", "orange", "red")),
    scale_fill_gradientn(
      colors = color_palette, name = precip_label(CFG$precip_var),
      values = scales::rescale(breakpoints, to = c(0, 1)),
      limits = c(0, 200), oob = scales::squish,
      breaks = breakpoints, labels = c("0", "50", "100", "150", "200+")),
    scale_size_manual(values = c("A" = 1, "B" = 2, "C" = 3, "D" = 4,
                                 "E" = 5, "F" = 6, "G" = 7)),
    coord_fixed(ratio = 1, xlim = xlim, ylim = ylim),
    theme_minimal(),
    theme(legend.position = "bottom")
  )
}

.us_states_cache <- NULL
us_states_df <- function() {
  if (is.null(.us_states_cache)) {
    # map_data() lives in ggplot2, not maps — maps supplies the underlying
    # database that ggplot2::map_data() reads, which is why `library(maps)`
    # is still required here.
    d <- ggplot2::map_data("state")
    d$region <- tools::toTitleCase(d$region)
    .us_states_cache <<- d
  }
  .us_states_cache
}

fire_extent <- function(fire_df, expd) {
  list(x = c(min(fire_df$LONGITUDE, na.rm = TRUE) - expd,
             max(fire_df$LONGITUDE, na.rm = TRUE) + expd),
       y = c(min(fire_df$LATITUDE,  na.rm = TRUE) - expd,
             max(fire_df$LATITUDE,  na.rm = TRUE) + expd))
}

fire_stats_of <- function(fire_df, by = "Date") {
  s <- fire_df %>% group_by(.data[[by]]) %>%
    summarise(FireCount = n(), TotalArea = sum(FIRE_SIZE, na.rm = TRUE),
              .groups = "drop")
  s$label <- paste0(s$TotalArea, " / ", s$FireCount)
  s
}

# Replicate a frame across the levels of a facet variable, so that layers which
# are constant across facets (precip fill, fire points) appear in every panel.
# Always returns `col` as a factor with the full level set and in the given
# order, and copes with 0-row inputs (a day with no fires, say) which plain
# `df[[col]] <- v` would reject.
rep_across <- function(df, col, values) {
  values <- as.character(values)
  if (nrow(df) == 0) {
    df[[col]] <- factor(character(0), levels = values)
    return(df)
  }
  out <- do.call(rbind, lapply(values, function(v) { df[[col]] <- v; df }))
  out[[col]] <- factor(out[[col]], levels = values)
  out
}

save_png <- function(p, file, w, h) {
  path <- file.path(CFG$scratch, file)
  ggsave(path, p, width = w, height = h, dpi = CFG$fig_dpi, limitsize = FALSE)
  msg("  wrote ", path)
  path
}

# --- Figure A: the app's own top-N-day map, one file per level per resolution
fig_topdays <- function(level_mb, gh_all, r2_df, precip_df, fires, dates, cfg = CFG) {
  ext <- fire_extent(fires, cfg$expd_app)
  fs  <- fire_stats_of(fires)
  sources <- split(gh_all, gh_all$Res)
  tags    <- setNames(res_tag(cfg$resolutions), res_lab(cfg$resolutions))
  if (!is.null(r2_df)) {
    sources[[R2_LAB]] <- r2_df
    tags[R2_LAB] <- R2_TAG
  }

  for (nm in names(sources)) {
    gh <- sources[[nm]]
    gh$Date <- factor(gh$Date, levels = as.character(dates))
    pr <- precip_df; pr$Date <- factor(pr$Date, levels = as.character(dates))
    p <- ggplot() +
      map_layers(pr, fires, fs, ext$x, ext$y) +
      geom_contour(data = gh,
                   aes(x = x, y = y, z = Geopotential_Height,
                       color = after_stat(level)), binwidth = 10) +
      facet_wrap(~Date) +
      labs(title = sprintf("%d mb geopotential height & AZ fire locations — %s",
                           level_mb, nm),
           subtitle = "binwidth = 10 m (current app setting)",
           x = "Longitude", y = "Latitude",
           color = "Geopotential Height (m)", size = "Fire Size Class")
    save_png(p, sprintf("d1_topdays_%dmb_%s.png", level_mb, tags[[nm]]), 14, 11)
  }
}

# --- Figure B: one day, all resolutions side by side (the actual D1 deliverable)
fig_byres <- function(level_mb, gh_all, r2_df, precip_df, fires, day, cfg = CFG) {
  gh <- gh_all[gh_all$Date == day, ]
  if (!is.null(r2_df)) {
    r2d <- r2_df[r2_df$Date == day, ]
    if (nrow(r2d)) { r2d$Res <- R2_LAB; gh <- rbind(gh, r2d[names(gh)]) }
  }
  if (!nrow(gh)) return(invisible(NULL))
  lv <- c(R2_LAB, res_lab(sort(cfg$resolutions, decreasing = TRUE)))
  gh$Res <- factor(gh$Res, levels = lv[lv %in% unique(gh$Res)])

  fd <- fires[fires$DISCOVERY_DATE == day, ]
  ext <- fire_extent(if (nrow(fd)) fd else fires, cfg$expd_wide)
  pr  <- precip_df[precip_df$Date == day, ]

  resl <- levels(gh$Res)
  p <- ggplot() +
    map_layers(rep_across(pr, "Res", resl),
               rep_across(fd, "Res", resl), NULL, ext$x, ext$y) +
    geom_contour(data = gh,
                 aes(x = x, y = y, z = Geopotential_Height,
                     color = after_stat(level)), binwidth = 10) +
    facet_wrap(~Res, ncol = 2) +
    labs(title = sprintf("%d mb geopotential height — %s", level_mb, format(day)),
         subtitle = sprintf("Resolution comparison, binwidth = 10 m. %d fires, %s acres.",
                            nrow(fd), format(sum(fd$FIRE_SIZE, na.rm = TRUE))),
         x = "Longitude", y = "Latitude",
         color = "Geopotential Height (m)", size = "Fire Size Class")
  save_png(p, sprintf("d1_byres_%dmb_%s.png", level_mb, format(day, "%Y%m%d")), 13, 11)
}

# --- Figure C: resolution x contour interval. Answers "does binwidth=10 still
#     read at 0.5 and 0.25?" in one look — rows are grids, columns intervals.
fig_binwidth <- function(level_mb, gh_all, r2_df, precip_df, fires, day, cfg = CFG) {
  gh <- gh_all[gh_all$Date == day, ]
  if (!is.null(r2_df)) {
    r2d <- r2_df[r2_df$Date == day, ]
    if (nrow(r2d)) { r2d$Res <- R2_LAB; gh <- rbind(gh, r2d[names(gh)]) }
  }
  if (!nrow(gh)) return(invisible(NULL))
  lv <- c(R2_LAB, res_lab(sort(cfg$resolutions, decreasing = TRUE)))
  gh$Res <- factor(gh$Res, levels = lv[lv %in% unique(gh$Res)])

  fd  <- fires[fires$DISCOVERY_DATE == day, ]
  ext <- fire_extent(if (nrow(fd)) fd else fires, cfg$expd_wide)
  pr  <- precip_df[precip_df$Date == day, ]

  bws  <- cfg$binwidths
  resl <- levels(gh$Res)
  bwl  <- paste0("binwidth = ", bws, " m")   # one facet column per interval

  # geom_contour's binwidth can't be mapped as an aesthetic, so instead: one
  # contour layer per interval, each with its data restricted to the matching
  # facet column. Layers whose data has no rows in a facet simply don't draw.
  gh_rep  <- rep_across(gh, "BW", bwl)
  base_df <- function(df) rep_across(rep_across(df, "Res", resl), "BW", bwl)

  p <- ggplot() + map_layers(base_df(pr), base_df(fd), NULL, ext$x, ext$y)
  for (j in seq_along(bws)) {
    p <- p + geom_contour(data = gh_rep[gh_rep$BW == bwl[j], ],
                          aes(x = x, y = y, z = Geopotential_Height,
                              color = after_stat(level)), binwidth = bws[j])
  }
  p <- p + facet_grid(Res ~ BW) +
    labs(title = sprintf("%d mb — contour interval vs grid resolution, %s",
                         level_mb, format(day)),
         subtitle = "Does binwidth = 10 m (left column, current app setting) still read at finer grids?",
         x = "Longitude", y = "Latitude",
         color = "Geopotential Height (m)", size = "Fire Size Class")
  save_png(p, sprintf("d1_binwidth_%dmb_%s.png", level_mb, format(day, "%Y%m%d")),
           5 * length(bws), 4.5 * length(resl))
}

step_render <- function(dates, fires, cfg = CFG) {
  need_pkgs(c("terra", "ncdf4", "scales"))
  precip_df <- load_precip(dates, cfg)
  if (is.null(precip_df)) {
    warning("No precipitation layers matched these dates; maps will have no fill.")
    precip_df <- data.frame(x = numeric(0), y = numeric(0),
                            Date = as.Date(character(0)),
                            Precipitation = numeric(0))
  }
  cmp_days <- dates[seq_len(min(cfg$n_compare_days, length(dates)))]

  for (lv in cfg$levels_mb) {
    msg("Rendering ", lv, " mb ...")
    gh_all <- load_era5_long(lv, dates, cfg)
    if (is.null(gh_all)) { msg("  no ERA5 data for ", lv, " mb — skipped"); next }
    r2_df <- if (isTRUE(cfg$include_r2_baseline)) load_r2(lv, dates) else NULL
    if (isTRUE(cfg$include_r2_baseline) && is.null(r2_df)) {
      msg("  (no R2 baseline available for ", lv, " mb)")
    }
    fig_topdays(lv, gh_all, r2_df, precip_df, fires, dates, cfg)
    for (d in cmp_days) {
      d <- as.Date(d, origin = "1970-01-01")
      fig_byres(lv, gh_all, r2_df, precip_df, fires, d, cfg)
      fig_binwidth(lv, gh_all, r2_df, precip_df, fires, d, cfg)
    }
    rm(gh_all, r2_df); gc(verbose = FALSE)
  }
  invisible(TRUE)
}

# ==================== REPORT =================================================

write_report <- function(dates, gridrep, cfg = CFG) {
  f <- file.path(cfg$scratch, "D1_REPORT.md")
  pngs <- sort(basename(list.files(cfg$scratch, pattern = "\\.png$")))
  hon  <- unique(gridrep[, c("resolution", "requested_deg", "actual_dx",
                         "actual_dy", "nx", "ny", "grid_honoured", "total_mb")])
  lines <- c(
    "# D1 — ERA5 resolution comparison",
    "",
    paste0("Generated ", format(Sys.time(), "%Y-%m-%d %H:%M"),
           " by `util/era5_compare.R`."),
    "",
    paste0("Domain ", cfg$area[3], "-", cfg$area[1], "N / ",
           abs(cfg$area[2]), "-", abs(cfg$area[4]), "W, ",
           cfg$hour_utc, "Z, levels ",
           paste(cfg$levels_mb, collapse = "/"), " mb."),
    paste0("Days: top ", length(dates), " ", paste(cfg$states, collapse = "/"),
           " fire days by ", cfg$sort_metric, " (same ranking as `fireMap`)."),
    "",
    "## Days used", "",
    paste0("- ", format(dates, "%Y-%m-%d")),
    "",
    "## R4 — was the CDS `grid` parameter honoured?", "",
    "| requested | delivered dx | delivered dy | nx | ny | honoured | MB downloaded |",
    "|---|---|---|---|---|---|---|",
    apply(hon, 1, function(r) sprintf("| %s | %s | %s | %s | %s | %s | %s |",
                                      r[["resolution"]], r[["actual_dx"]],
                                      r[["actual_dy"]], r[["nx"]], r[["ny"]],
                                      r[["grid_honoured"]], r[["total_mb"]])),
    "",
    if (all(gridrep$grid_honoured))
      "**Honoured.** Server-side regridding works; the full 33-year pull can be requested directly at the chosen resolution (scope D3, ~0.5 GB at 1.0°)."
    else
      "**Not honoured.** Fall back to R4's plan: pull native 0.25° (~7.5 GB one-time), regrid locally, discard the raw files.",
    "",
    "## R3 — geopotential -> height conversion", "",
    "`z` divided by 9.80665. Observed ranges:", "",
    "| resolution | level | min m | max m |", "|---|---|---|---|",
    apply(gridrep, 1, function(r) sprintf("| %s | %s mb | %s | %s |",
                                      r[["resolution"]], r[["level_mb"]],
                                      r[["hgt_min_m"]], r[["hgt_max_m"]])),
    "",
    "## Figures", "",
    "- `d1_topdays_*` — the app's own top-day facet map, one per level per grid.",
    "- `d1_byres_*` — one day, all grids side by side. **This is the D1 decision figure.**",
    "- `d1_binwidth_*` — grid (rows) x contour interval (columns).",
    "",
    paste0("- `", pngs, "`"),
    "",
    "## What to look at", "",
    "1. In `d1_byres_*`: does 0.5° show synoptic features 1.0° misses, or just wigglier contours around the same trough?",
    "2. In `d1_binwidth_*`: is 10 m still legible at 0.5°/0.25°, or does the interval need to scale?",
    "3. In the 1000 mb figures: do the contours go incoherent over the interior West? If so, drop the level (R9 / open question 5)."
  )
  writeLines(lines, f)
  msg("wrote ", f)
  f
}

# ==================== DRIVER =================================================

main <- function(steps = c("select", "download", "validate", "render"),
                 cfg = CFG) {
  require_project_root("Data/FODthin.Rdata")
  ensure_dirs()

  sel <- step_select(cfg)   # always cheap; needed by every later step
  dates <- sel$dates
  fires <- sel$fires
  msg("Days: ", paste(format(dates, "%Y-%m-%d"), collapse = ", "))

  if ("download" %in% steps) step_download(dates, cfg)

  gridrep <- NULL
  if ("validate" %in% steps) gridrep <- step_validate(dates, cfg)
  if ("render"   %in% steps) step_render(dates, fires, cfg)
  if (!is.null(gridrep)) write_report(dates, gridrep, cfg)

  msg("Done. Figures and report are in ", normalizePath(cfg$scratch, mustWork = FALSE))
  invisible(list(dates = dates, report = gridrep))
}

if (isTRUE(ERA5_CMP_RUN_ON_SOURCE)) main()
