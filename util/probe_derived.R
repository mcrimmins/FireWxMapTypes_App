# util/probe_derived.R
# -----------------------------------------------------------------------------
# Does `derived-era5-single-levels-daily-statistics` honour `area` and `grid`?
#
# WHY THIS EXISTS
# `era5_compare.R` proved that server-side regridding works for
# `reanalysis-era5-pressure-levels`. That result does NOT transfer: the derived
# daily-statistics entry is a different dataset with a different adaptor. It
# requests GRIB from the parent entry, opens it with xarray, aggregates with
# earthkit-transforms, and writes netCDF — and whether it forwards `area` /
# `grid` to that inner request is undocumented. ECMWF's own API example includes
# neither key, and the "Spatial grid" section of the docs only states the native
# 0.25 deg resolution.
#
# The answer decides whether the derived variables are cheap or expensive:
#   honoured    -> ~18 MB per variable at 1.0 deg, request and go
#   area only   -> CONUS at 0.25 deg, regrid locally, ~16x the transfer
#   neither     -> GLOBAL 0.25 deg per variable per day. 12,054 days x 1.04 M
#                  cells is not viable; fall back to the hourly entry, which we
#                  know does honour both.
#
# ALSO CHECKS
#   * that the documented request keys work as published
#     (daily_statistic / time_zone / frequency)
#   * the delivery format (docs say netCDF inside a zip, one file per variable)
#   * whether a local time zone shift (utc-07:00, MST) is accepted
#   * optionally, the same questions for the pressure-levels daily entry
#
# REFERENCE
#   https://confluence.ecmwf.int/display/CKB/ERA5+family+post-processed+daily+statistics+documentation
#   Note: ECMWF fixed an incorrect time alignment for
#   *_since_previous_post_processing variables on 2026-07-30. Data pulled before
#   that date is shifted +1 h against the requested time zone.
#
# HOW TO RUN (project root):
#   source("util/probe_derived.R")
# RUNTIME: 6 small requests. Minutes, dominated by CDS queue.
# RESUMABLE: downloads are cached under Data/scratch/probe_derived/.
#
# MAC / drafted with Claude, 2026-08
# -----------------------------------------------------------------------------

PCFG <- list(
  area      = c(60, -140, 20, -60),   # N, W, S, E
  grid      = c(1.0, 1.0),
  test_date = as.Date("2020-06-15"),
  probe_var = "2m_temperature",
  multi_var = c("2m_temperature", "10m_u_component_of_wind"),
  statistic = "daily_max",            # daily_mean | daily_max | daily_min | daily_sum
  time_zone = "utc+00:00",
  local_tz  = "utc-07:00",            # MST, for the local-day test
  frequency = "1_hourly",
  dir       = "./Data/scratch/probe_derived",
  test_pressure_levels = TRUE
)

ERA5_CMP_RUN_ON_SOURCE <- FALSE
source("util/era5_compare.R")   # setup_cds, msg, need_pkgs, ecmwfr_major

need_pkgs(c("ecmwfr", "ncdf4"))

# ============================ request shapes =================================

# Exactly ECMWF's published example, plus whatever the variant adds.
base_request <- function(vars = PCFG$probe_var, tz = PCFG$time_zone) {
  d <- PCFG$test_date
  list(
    dataset_short_name = "derived-era5-single-levels-daily-statistics",
    product_type    = "reanalysis",
    variable        = vars,
    year            = format(d, "%Y"),
    month           = format(d, "%m"),
    day             = format(d, "%d"),
    daily_statistic = PCFG$statistic,
    time_zone       = tz,
    frequency       = PCFG$frequency
  )
}

VARIANTS <- list(
  list(id = "V1_bare",
       note = "documented example, no spatial subsetting — GLOBAL 0.25 deg",
       req  = function() base_request()),
  list(id = "V2_area",
       note = "+ area (CONUS crop)",
       req  = function() c(base_request(), list(area = PCFG$area))),
  list(id = "V3_area_grid",
       note = "+ area + grid = 1.0 deg — the one that matters",
       req  = function() c(base_request(), list(area = PCFG$area, grid = PCFG$grid))),
  list(id = "V4_grid_chr",
       note = "+ area + grid as character, in case the adaptor is type-fussy",
       req  = function() c(base_request(),
                           list(area = PCFG$area, grid = as.character(PCFG$grid)))),
  list(id = "V5_multivar",
       note = "two variables at once — expect one .nc per variable inside the zip",
       req  = function() c(base_request(vars = PCFG$multi_var),
                           list(area = PCFG$area, grid = PCFG$grid))),
  list(id = "V6_localtz",
       note = "time_zone = utc-07:00 (MST), i.e. a local fire day not a UTC day",
       req  = function() c(base_request(tz = PCFG$local_tz),
                           list(area = PCFG$area, grid = PCFG$grid)))
)

# ============================ inspection =====================================

is_zip <- function(f) {
  con <- file(f, "rb"); on.exit(close(con))
  identical(readBin(con, "raw", 2), as.raw(c(0x50, 0x4b)))   # "PK"
}

# Generic: report grid geometry for whatever variable the file holds.
inspect_nc <- function(f) {
  nc <- ncdf4::nc_open(f); on.exit(ncdf4::nc_close(nc), add = TRUE)
  coord_like <- c("longitude", "lon", "x", "latitude", "lat", "y",
                  "time", "valid_time", "number", "expver",
                  "pressure_level", "level")
  vn <- setdiff(names(nc$var), coord_like)
  vn <- if (length(vn)) vn[1] else names(nc$var)[1]
  v  <- nc$var[[vn]]
  dn <- vapply(v$dim, function(d) d$name, character(1))
  gx <- function(cands) {
    i <- which(dn %in% cands)
    if (length(i)) v$dim[[i[1]]]$vals else NA_real_
  }
  lon <- gx(c("longitude", "lon", "x"))
  lat <- gx(c("latitude", "lat", "y"))
  list(
    var  = vn,
    nx   = length(lon), ny = length(lat),
    dx   = if (length(lon) > 1) abs(diff(sort(lon))[1]) else NA_real_,
    dy   = if (length(lat) > 1) abs(diff(sort(lat))[1]) else NA_real_,
    xmin = min(lon), xmax = max(lon), ymin = min(lat), ymax = max(lat),
    dims = paste(dn, collapse = ",")
  )
}

# Downloads may be a zip of one-nc-per-variable, or a bare nc.
unpack <- function(f, into) {
  if (!is_zip(f)) return(f)
  if (dir.exists(into)) unlink(into, recursive = TRUE)
  dir.create(into, recursive = TRUE)
  utils::unzip(f, exdir = into)
  list.files(into, pattern = "\\.nc$", full.names = TRUE, recursive = TRUE)
}

# ============================ runner =========================================

# ecmwfr 2.x does not reliably write to `request$target` — it returns the path it
# actually used. Trust the return value, and fall back to "whatever file appeared
# in the directory while we were waiting" if it gives us something unusable.
fetch_one <- function(id, req, user) {
  dest <- file.path(PCFG$dir, paste0(id, ".dl"))
  if (file.exists(dest)) { msg("    cached"); return(dest) }

  before <- list.files(PCFG$dir, full.names = TRUE, recursive = TRUE)
  args <- list(request = c(req, list(target = paste0(id, ".zip"))),
               transfer = TRUE, path = PCFG$dir, verbose = FALSE,
               time_out = 3600)
  if (!is.null(user)) args$user <- user
  out <- tryCatch(do.call(ecmwfr::wf_request, args), error = function(e) e)
  if (inherits(out, "error")) return(out)

  got <- NULL
  if (is.character(out) && length(out) == 1 && file.exists(out)) {
    got <- out
  } else {
    after <- setdiff(list.files(PCFG$dir, full.names = TRUE, recursive = TRUE),
                     before)
    after <- after[!dir.exists(after)]
    if (length(after)) got <- after[order(file.mtime(after), decreasing = TRUE)][1]
  }
  if (is.null(got) || !file.exists(got)) {
    return(simpleError(paste0(
      "request returned without an identifiable file. wf_request returned: ",
      paste(utils::capture.output(str(out)), collapse = " "))))
  }
  msg("    downloaded as ", basename(got), " (", round(file.size(got) / 1024), " KB)")
  file.rename(got, dest)
  dest
}

run_variant <- function(v, user) {
  msg("--- ", v$id, ": ", v$note)
  dest <- fetch_one(v$id, v$req(), user)
  if (inherits(dest, "error")) {
    m <- conditionMessage(dest)
    msg("    REJECTED: ", m)
    return(data.frame(variant = v$id, ok = FALSE, note = v$note,
                      n_files = NA_integer_, kb = NA_real_,
                      nx = NA_integer_, ny = NA_integer_,
                      dx = NA_real_, dy = NA_real_, extent = NA_character_,
                      detail = substr(gsub("\\s+", " ", m), 1, 300),
                      stringsAsFactors = FALSE))
  }

  ncs <- unpack(dest, file.path(PCFG$dir, paste0(v$id, "_x")))
  if (!length(ncs)) {
    return(data.frame(variant = v$id, ok = FALSE, note = v$note,
                      n_files = 0L, kb = round(file.size(dest) / 1024),
                      nx = NA_integer_, ny = NA_integer_, dx = NA_real_,
                      dy = NA_real_, extent = NA_character_,
                      detail = "downloaded but no .nc inside",
                      stringsAsFactors = FALSE))
  }
  g <- tryCatch(inspect_nc(ncs[1]), error = function(e) e)
  if (inherits(g, "error")) {
    msg("    downloaded but unreadable: ", conditionMessage(g))
    return(data.frame(variant = v$id, ok = FALSE, note = v$note,
                      n_files = length(ncs), kb = round(file.size(dest) / 1024),
                      nx = NA_integer_, ny = NA_integer_, dx = NA_real_,
                      dy = NA_real_, extent = NA_character_,
                      detail = paste("unreadable:", conditionMessage(g)),
                      stringsAsFactors = FALSE))
  }
  msg("    ", length(ncs), " nc file(s), ", round(file.size(dest) / 1024), " KB, ",
      g$nx, " x ", g$ny, " @ ", signif(g$dx, 4), " deg, var '", g$var, "'")

  data.frame(
    variant = v$id, ok = TRUE, note = v$note,
    n_files = length(ncs), kb = round(file.size(dest) / 1024),
    nx = g$nx, ny = g$ny, dx = g$dx, dy = g$dy,
    extent = sprintf("[%.2f, %.2f, %.2f, %.2f]", g$xmin, g$xmax, g$ymin, g$ymax),
    detail = paste0("dims: ", g$dims),
    stringsAsFactors = FALSE)
}

# The same two questions for the pressure-levels daily entry, since if that one
# works it would give daily-mean heights as well as the 18Z snapshot.
probe_pressure_daily <- function(user) {
  msg("--- V7_pl_daily: derived-era5-pressure-levels-daily-statistics, area + grid")
  d <- PCFG$test_date
  req <- list(
    dataset_short_name = "derived-era5-pressure-levels-daily-statistics",
    product_type = "reanalysis", variable = "geopotential",
    pressure_level = "500",
    year = format(d, "%Y"), month = format(d, "%m"), day = format(d, "%d"),
    daily_statistic = PCFG$statistic, time_zone = PCFG$time_zone,
    frequency = PCFG$frequency,
    area = PCFG$area, grid = PCFG$grid)
  dest <- fetch_one("V7_pl_daily", req, user)
  if (inherits(dest, "error")) {
    msg("    REJECTED: ", conditionMessage(dest))
    return(data.frame(variant = "V7_pl_daily", ok = FALSE,
                      note = "pressure-levels daily stats",
                      n_files = NA_integer_, kb = NA_real_, nx = NA_integer_,
                      ny = NA_integer_, dx = NA_real_, dy = NA_real_,
                      extent = NA_character_,
                      detail = substr(gsub("\\s+", " ",
                                           conditionMessage(dest)), 1, 300),
                      stringsAsFactors = FALSE))
  }
  ncs <- unpack(dest, file.path(PCFG$dir, "V7_pl_daily_x"))
  g <- inspect_nc(ncs[1])
  msg("    ", g$nx, " x ", g$ny, " @ ", signif(g$dx, 4), " deg")
  data.frame(variant = "V7_pl_daily", ok = TRUE,
             note = "pressure-levels daily stats", n_files = length(ncs),
             kb = round(file.size(dest) / 1024), nx = g$nx, ny = g$ny,
             dx = g$dx, dy = g$dy,
             extent = sprintf("[%.2f, %.2f, %.2f, %.2f]",
                              g$xmin, g$xmax, g$ymin, g$ymax),
             detail = paste0("dims: ", g$dims), stringsAsFactors = FALSE)
}

# ============================ verdict ========================================

verdict <- function(res) {
  got <- function(id) res[res$variant == id & res$ok, ]
  v3 <- got("V3_area_grid"); v4 <- got("V4_grid_chr"); v2 <- got("V2_area")
  gridv <- rbind(v3, v4)
  exp_nx <- round(abs(PCFG$area[4] - PCFG$area[2]) / PCFG$grid[1]) + 1
  exp_ny <- round(abs(PCFG$area[1] - PCFG$area[3]) / PCFG$grid[2]) + 1

  grid_ok <- nrow(gridv) > 0 &&
    any(abs(gridv$dx - PCFG$grid[1]) < 1e-6, na.rm = TRUE)
  area_ok <- (nrow(v2) > 0 && !is.na(v2$nx[1]) && v2$nx[1] < 1000) ||
             (nrow(gridv) > 0 && any(gridv$nx < 1000, na.rm = TRUE))

  cat("\n================ VERDICT ================\n")
  cat("expected at area + grid=1.0: ", exp_nx, " x ", exp_ny, " cells\n", sep = "")
  cat("`area`  honoured: ", if (area_ok) "YES" else "NO", "\n", sep = "")
  cat("`grid`  honoured: ", if (grid_ok) "YES" else "NO", "\n", sep = "")
  cat("\n")
  if (grid_ok && area_ok) {
    cat("=> Derived daily statistics are CHEAP. ~18 MB per variable at 1.0 deg.\n",
        "   Add the shortlist to build_era5.R as a second request loop.\n", sep = "")
  } else if (area_ok) {
    cat("=> `area` works, `grid` does not. CONUS at 0.25 deg is ~16x the cells;\n",
        "   transfer is tolerable but every variable needs a local regrid step.\n",
        "   Budget that into the build, or use the hourly entry instead.\n", sep = "")
  } else {
    cat("=> Neither honoured: every request returns a GLOBAL 0.25 deg field.\n",
        "   1.04 M cells x 12,054 days per variable is not viable. Use the\n",
        "   hourly single-levels entry (area + grid confirmed working there)\n",
        "   and lose the daily max/min, or aggregate hourly yourself.\n", sep = "")
  }
  cat("=========================================\n")
}

# ============================ driver =========================================

probe_main <- function() {
  check_project_root()
  if (!dir.exists(PCFG$dir)) dir.create(PCFG$dir, recursive = TRUE)
  user <- setup_cds()

  rows <- lapply(VARIANTS, run_variant, user = user)
  if (isTRUE(PCFG$test_pressure_levels)) {
    rows <- c(rows, list(probe_pressure_daily(user)))
  }
  res <- do.call(rbind, rows)

  cat("\n")
  print(res[, c("variant", "ok", "n_files", "kb", "nx", "ny", "dx", "extent")],
        row.names = FALSE)
  cat("\nRejection / dimension detail:\n")
  for (i in seq_len(nrow(res))) {
    cat("  ", res$variant[i], ": ", res$detail[i], "\n", sep = "")
  }
  verdict(res)

  utils::write.csv(res, file.path(PCFG$dir, "probe_derived_results.csv"),
                   row.names = FALSE)
  msg("wrote ", file.path(PCFG$dir, "probe_derived_results.csv"))
  invisible(res)
}

probe_main()
