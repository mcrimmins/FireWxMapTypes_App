# util/build_era5.R
# -----------------------------------------------------------------------------
# PHASE 1 — acquire the full ERA5 record from the Copernicus CDS.
#
# WHY THIS PULLS HOURLY DATA AND AGGREGATES LOCALLY
# The obvious route was `derived-era5-single-levels-daily-statistics`, which
# computes daily max/min/mean server-side. Measured on 2026-08-10 it is not
# viable at this scale:
#
#   ERA5 hourly pressure levels, full year, 3 levels ....... 00:02:07
#   ERA5 daily statistics, 1 variable x 6 months .......... 02:00:24
#
# ~57x apart, and CDS caps a user at ONE concurrent MARS request, so the derived
# route serialises to roughly 38 days for this record. The daily-statistics
# queue was 2,641 deep with 60 running; its "large request" sub-pool (anything
# over two variables or one month) was 2,153 deep with 40 running.
#
# Pulling hourly and aggregating here is ~30 hours instead, and removes three
# problems rather than just being faster:
#   * scope R11 disappears — hourly ERA5 is permanently archived, so a rebuild
#     is reproducible. The derived product is computed at retrieval and is not.
#   * scope R12 disappears — the 2026-07-30 time-alignment bug was in the
#     derived adaptor.
#   * D10's sampling caveat disappears for anything pulled at 24 hours: the
#     daily max is exact, not 2-3% low.
# It also makes extra statistics free later — daily min temperature, an
# afternoon-only window — without re-pulling anything.
#
# HOURS PER VARIABLE (see the table in BCFG). Only the statistic decides this:
# a maximum needs dense sampling near the peak, a mean of a smooth field does
# not. Gust is at 24 h because util/bench_gust_sampling.R MEASURED 13-18% low
# bias at 3-hourly on short-peak days. CAPE is at 24 h on the same physics,
# unmeasured. The rest are reasoned from diurnal smoothness.
#
# PAYLOAD
#   intermediate, deleted after phase 2 ....... ~6.9 GB  (Data/era5_raw/)
#   shipped in the deploy bundle .............. ~293 MB  (unchanged by any of this)
#
# 232 requests: 33 pressure-level + 198 hourly single-level + 1 static.
#
# RUNTIME: unattended, ~30 hours, dominated by the one-concurrent-request cap.
# FULLY RESUMABLE — completed files are skipped on integrity check, not on mere
# existence, so a truncated download is refetched. Safe to interrupt.
#
# HOW TO RUN — interactively (project root):
#   source("util/build_era5.R")                 # dry run, prints the plan
#   BCFG$dry_run <- FALSE; BCFG$years <- 2020   # smoke-test one year
#   build_main()
# then reset BCFG$years <- 1992:2024 and let it run.
#
# HOW TO RUN — unattended on the build server:
#   Rscript build/run_phase1.R                  # or the systemd unit
# which sources this file with ERA5_BUILD_RUN_ON_SOURCE = FALSE, so nothing
# happens until it calls build_main() itself.
#
# MAC / drafted with Claude, 2026-08
# -----------------------------------------------------------------------------

BCFG <- list(
  years   = 1992:2024,
  area    = c(60, -140, 20, -60),   # N, W, S, E — ALWAYS set; omit it and
                                    # longitudes come back on 0-360 (R8)
  grid    = c(1.0, 1.0),

  # --- heights: D6/D7, 18Z instantaneous for continuity with the R2 record ---
  levels  = c(500, 700, 1000),
  hgt_hour = 18,

  # --- single-level variables: D8, aggregated locally over MST days (D9) ---
  tz_shift_h = -7,
  vars = list(
    list(id = "gust",  era5 = "10m_wind_gust_since_previous_post_processing",
         hours = 0:23,        stats = c("max", "mean"),
         why   = "MEASURED 13-18% low at 3-hourly on short-peak days"),
    list(id = "cape",  era5 = "convective_available_potential_energy",
         hours = 0:23,        stats = "max",
         why   = "convective and spiky, same physics as gust; unmeasured"),
    list(id = "t2",    era5 = "2m_temperature",
         hours = seq(0, 21, 3), stats = "max",
         why   = "smooth diurnal cycle; 21Z sample lands on 14 MST, near Tmax"),
    list(id = "d2",    era5 = "2m_dewpoint_temperature",
         hours = seq(0, 21, 3), stats = "min",
         why   = "smooth"),
    list(id = "pwat",  era5 = "total_column_water_vapour",
         hours = seq(0, 18, 6), stats = "mean",
         why   = "very smooth; a mean of 4 samples is fine"),
    list(id = "soilw", era5 = "volumetric_soil_water_layer_1",
         hours = seq(0, 18, 6), stats = "mean",
         why   = "changes over days, not hours")
  ),

  raw_dir   = "./Data/era5_raw",
  daily_dir = "./Data/era5_raw/daily",
  workers   = 1,        # CDS allows ONE concurrent MARS request per user;
                        # more just queues and confuses the log
  dry_run   = TRUE,
  keep_hourly = TRUE,   # FALSE deletes each hourly file once aggregated

  # --- unattended operation ---
  notify_every = 12,    # push a progress notification every N fetched jobs.
                        # ~12 jobs is ~1 h at the measured rate, which makes
                        # silence itself the failure signal: no message for two
                        # hours means the run is stuck or the box is gone.
  fail_streak  = 3,     # consecutive failed jobs before a high-priority alert.
                        # One failure is a transient CDS hiccup and the run is
                        # resumable; three in a row is a real problem (expired
                        # token, licence revoked, disk full).

  # MEASURED 2026-08-10: the CDS failed two unrelated requests (one
  # pressure-level, one single-level) inside a ~20 minute window, then accepted
  # byte-identical payloads afterwards — confirmed by submitting them straight to
  # the REST API with build/diagnose_cds.R, which got 5/5 successes on the exact
  # shape that had just failed twice. Transient server-side failure is normal
  # operation, not an exception.
  #
  # Without these passes, one such blip costs a full systemd restart cycle. Over
  # 232 requests that is a lot of churn for something that clears in minutes.
  retry_passes = 2,     # extra passes over whatever is still missing
  retry_wait_s = 180    # pause before each, to let a CDS wobble pass
)

# Helpers only — no plotting stack. See util/era5_common.R for why this is not
# era5_compare.R any more.
source("util/era5_common.R")   # setup_cds, msg, need_pkgs, G0, require_project_root, notify*

# xml2 is not declared by ecmwfr but is needed to parse CDS error responses.
# Without it a failure reports "Please install xml2 package" instead of the
# actual reason, which is how a cost-limit rejection gets misdiagnosed.
need_pkgs(c("ecmwfr", "ncdf4", "xml2"))

# Plausibility bands. These only warn — they exist to catch a unit error or a
# corrupted file, not to gate the build.
#
# soilw: physically 0-1, but the lower bound is -0.01 because server-side
# regridding from 0.25 deg to 1.0 deg interpolates, and interpolation near a
# hard floor undershoots it. Measured on 2020: min -0.0048 m3/m3, which is 0.5%
# of the range and clearly numerical rather than physical. Phase 2 (gridpack.R)
# should CLAMP to [0, 1] before quantising rather than encode a negative
# volumetric water content.
RANGES <- list(
  z_500 = c(4500, 6100), z_700 = c(2400, 3400), z_1000 = c(-500, 600),
  gust = c(0, 120), cape = c(0, 12000), t2 = c(200, 340),
  d2 = c(180, 320), pwat = c(0, 100), soilw = c(-0.01, 1))

# ============================ requests =======================================

req_pressure <- function(y) list(
  dataset_short_name = "reanalysis-era5-pressure-levels",
  product_type   = "reanalysis",
  variable       = "geopotential",
  pressure_level = as.character(BCFG$levels),
  year  = as.character(y),
  month = sprintf("%02d", 1:12),
  day   = sprintf("%02d", 1:31),     # CDS ignores impossible combinations
  time  = sprintf("%02d:00", BCFG$hgt_hour),
  area  = BCFG$area, grid = BCFG$grid,
  data_format = "netcdf", download_format = "unarchived")

req_hourly <- function(v, y) list(
  dataset_short_name = "reanalysis-era5-single-levels",
  product_type = "reanalysis",
  variable = v$era5,
  year  = as.character(y),
  month = sprintf("%02d", 1:12),
  day   = sprintf("%02d", 1:31),
  time  = sprintf("%02d:00", v$hours),
  area  = BCFG$area, grid = BCFG$grid,
  data_format = "netcdf", download_format = "unarchived")

# Surface geopotential is time-invariant; any single timestamp will do. Used to
# mask 1000 mb where the level sits below the model terrain (D6).
req_orography <- function() list(
  dataset_short_name = "reanalysis-era5-single-levels",
  product_type = "reanalysis", variable = "geopotential",
  year = "2020", month = "01", day = "01", time = "00:00",
  area = BCFG$area, grid = BCFG$grid,
  data_format = "netcdf", download_format = "unarchived")

# nfields drives the progress estimate. Jobs differ by up to 24x in size — a
# 24-hour gust year against a 6-hourly soil-water year — so a naive
# "jobs remaining x time per job" ETA overstates by 2-3x.
new_job <- function(id, kind, req, extra = list()) {
  nf <- switch(kind,
    pressure = 365.25 * length(req$pressure_level),
    hourly   = 365.25 * length(req$time),
    1)
  c(list(id = id, kind = kind, req = req, nfields = nf,
         path = file.path(BCFG$raw_dir, paste0(id, ".nc"))), extra)
}

build_jobs <- function() {
  jobs <- lapply(BCFG$years, function(y)
    new_job(sprintf("hgt_%d", y), "pressure", req_pressure(y)))
  for (v in BCFG$vars)
    for (y in BCFG$years)
      jobs[[length(jobs) + 1]] <-
        new_job(sprintf("%s_%d", v$id, y), "hourly", req_hourly(v, y),
                list(vdef = v))
  jobs[[length(jobs) + 1]] <- new_job("orography", "static", req_orography())
  jobs
}

# ============================ integrity ======================================

file_ok <- function(job) {
  p <- job$path
  if (!file.exists(p) || file.size(p) < 2048) return(FALSE)
  tryCatch({
    nc <- ncdf4::nc_open(p); on.exit(ncdf4::nc_close(nc))
    length(nc$var) > 0
  }, error = function(e) FALSE)
}
pending_jobs <- function(jobs) jobs[!vapply(jobs, file_ok, logical(1))]

# ============================ preflight ======================================

cds_http <- function(path, key = Sys.getenv("CDS_KEY"), timeout = 20) {
  url <- paste0("https://cds.climate.copernicus.eu/api", path)
  if (requireNamespace("httr", quietly = TRUE)) {
    r <- tryCatch(httr::GET(url, httr::add_headers(`PRIVATE-TOKEN` = key),
                            httr::timeout(timeout)), error = function(e) e)
    if (inherits(r, "error")) return(list(status = NA, err = conditionMessage(r)))
    return(list(status = httr::status_code(r)))
  }
  list(status = NA, err = "httr not available")
}

preflight <- function() {
  cat("\n--- CDS PREFLIGHT ---\n")
  key <- Sys.getenv("CDS_KEY")
  cat("1. CDS_KEY: ", if (nzchar(key)) sprintf("%d chars", nchar(key)) else "MISSING", "\n", sep = "")
  if (!nzchar(key)) return(invisible(FALSE))
  cat("2. CDS API ... ")
  r <- cds_http("/retrieve/v1/datasets")
  if (is.na(r$status)) {
    cat("UNREACHABLE\n   ", r$err, "\n",
        "   -> DNS/proxy/VPN or a CDS outage. Check https://status.ecmwf.int/\n", sep = "")
    return(invisible(FALSE))
  }
  cat("HTTP ", r$status,
      if (r$status == 404) "  (endpoint not public — fine, the server answered)" else "",
      "\n", sep = "")
  if (r$status %in% c(401, 403)) {
    cat("   -> token rejected. Refresh it at cds.climate.copernicus.eu/profile\n",
        "      and re-accept the ERA5 licences while you are there.\n", sep = "")
    return(invisible(FALSE))
  }
  cat("--- preflight passed ---\n\n")
  invisible(TRUE)
}

# ============================ fetching =======================================

fetch_one <- function(job, user) {
  before <- list.files(BCFG$raw_dir, full.names = TRUE)
  args <- list(request = c(job$req, list(target = basename(job$path))),
               transfer = TRUE, path = BCFG$raw_dir, verbose = FALSE,
               time_out = 7200)
  if (!is.null(user)) args$user <- user
  out <- tryCatch(do.call(ecmwfr::wf_request, args), error = function(e) e)
  if (inherits(out, "error")) { msg("  ! ", job$id, ": ", conditionMessage(out)); return(FALSE) }
  # ecmwfr 2.x does not reliably honour request$target
  got <- if (is.character(out) && length(out) == 1 && file.exists(out)) out else {
    nw <- setdiff(list.files(BCFG$raw_dir, full.names = TRUE), before)
    nw <- nw[!dir.exists(nw)]
    if (length(nw)) nw[order(file.mtime(nw), decreasing = TRUE)][1] else NULL
  }
  if (is.null(got)) { msg("  ! ", job$id, ": no file produced"); return(FALSE) }
  if (!identical(normalizePath(got, mustWork = FALSE),
                 normalizePath(job$path, mustWork = FALSE)))
    file.rename(got, job$path)
  file_ok(job)
}

fetch_jobs <- function(jobs, user) {
  todo <- pending_jobs(jobs)
  msg(length(jobs), " jobs total; ", length(todo), " to fetch.")
  if (!length(todo)) return(invisible(TRUE))
  t0 <- Sys.time()
  nf   <- vapply(todo, function(j) j$nfields, numeric(1))
  done_f <- 0
  n_fail <- 0L; streak <- 0L

  notify_start(sprintf(
    "%d of %d jobs to fetch (%s already present).\nYears %d-%d, ~%s of fields.",
    length(todo), length(jobs), length(jobs) - length(todo),
    min(BCFG$years), max(BCFG$years), format(round(sum(nf)), big.mark = ",")))

  for (i in seq_along(todo)) {
    el  <- as.numeric(difftime(Sys.time(), t0, units = "mins"))
    rem <- if (done_f > 0) el / done_f * (sum(nf) - done_f) else NA_real_
    eta <- if (done_f > 0)
      sprintf(", ~%.0f min left (%.0f%% of fields)", rem, 100 * done_f / sum(nf)) else ""
    msg("[", i, "/", length(todo), "] ", todo[[i]]$id, " (",
        format(round(nf[i]), big.mark = ","), " fields)", eta)

    ok <- isTRUE(fetch_one(todo[[i]], user))
    done_f <- done_f + nf[i]

    if (ok) {
      streak <- 0L
    } else {
      n_fail <- n_fail + 1L; streak <- streak + 1L
      if (streak >= BCFG$fail_streak) {
        notify_warn(sprintf(
          paste0("%d jobs failed in a row (last: %s).\n",
                 "%d/%d done, %d failures total.\n",
                 "The run continues — it is resumable — but check the log:\n",
                 "  journalctl --user -u firewx-build -n 60"),
          streak, todo[[i]]$id, i, length(todo), n_fail))
        streak <- 0L   # re-arm rather than alert on every subsequent job
      }
    }

    if (i %% BCFG$notify_every == 0 && i < length(todo)) {
      notify_progress(sprintf(
        "%d/%d jobs, %.0f%% of fields.\nElapsed %s, ~%s left.\n%s\n%s failures so far.",
        i, length(todo), 100 * done_f / sum(nf), fmt_dur(el * 60),
        if (is.na(rem)) "?" else fmt_dur(rem * 60),
        disk_line(), n_fail))
    }
  }

  # --- retry passes ----------------------------------------------------------
  # Cheap, bounded, and in-run: a CDS blip that clears in minutes should not need
  # a systemd restart to recover from. Deliberately NOT an inner retry loop
  # around fetch_one() — pausing between whole passes gives a struggling adaptor
  # time to recover, where an immediate retry would just fail again.
  for (pass in seq_len(BCFG$retry_passes %||% 0)) {
    left <- pending_jobs(jobs)
    if (!length(left)) break
    msg("retry pass ", pass, "/", BCFG$retry_passes, ": ", length(left),
        " job(s) outstanding — waiting ", BCFG$retry_wait_s, "s first")
    Sys.sleep(BCFG$retry_wait_s)
    for (j in left) {
      msg("  retry ", j$id)
      fetch_one(j, user)
    }
  }

  el_s <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  msg("Fetched ", format(round(sum(nf)), big.mark = ","), " fields in ",
      round(el_s / 60), " min (", round(sum(nf) / el_s, 1), " fields/s)")
  still <- pending_jobs(jobs)
  if (length(still)) {
    # ecmwfr collapses every server-side rejection into one message: "Request has
    # failed, please check the online request queue for more details!" — which
    # means the actual reason (cost limit, licence, malformed key, transient
    # adaptor fault) is only visible in the web queue. Name the jobs and the URL
    # rather than leaving the reader to reconstruct both from the scrollback.
    msg(length(still), " still missing: ",
        paste(vapply(still, `[[`, character(1), "id"), collapse = ", "))
    msg("  Reason is not in this log — ecmwfr does not surface it. See:")
    msg("    https://cds.climate.copernicus.eu/requests")
    msg("  Re-running resumes: completed files are skipped on an integrity")
    msg("  check, so only these are re-requested.")
  }
  invisible(length(still) == 0)
}

# Free space on the volume holding the raw directory. Cheap, and the single most
# useful thing to have in a progress message: ~7 GB of intermediates is the one
# resource this build can silently exhaust.
disk_line <- function() {
  out <- tryCatch(
    system2("df", c("-Ph", shQuote(normalizePath(BCFG$raw_dir, mustWork = FALSE))),
            stdout = TRUE, stderr = FALSE),
    error = function(e) NULL)
  if (length(out) < 2) return("disk: unknown")
  f <- strsplit(trimws(out[2]), "\\s+")[[1]]
  sprintf("disk: %s free of %s (%s used)", f[4], f[2], f[5])
}

# ============================ reading ========================================

# Returns values as [ncell x ntime] with cells in expand.grid(lon, lat) order.
read_nc_cells <- function(path) {
  nc <- ncdf4::nc_open(path); on.exit(ncdf4::nc_close(nc), add = TRUE)
  coordish <- c("longitude","lon","x","latitude","lat","y","time","valid_time",
                "number","expver","pressure_level","level")
  vn <- setdiff(names(nc$var), coordish)
  vn <- if (length(vn)) vn[1] else names(nc$var)[1]
  v  <- nc$var[[vn]]
  dn <- vapply(v$dim, function(d) d$name, character(1))
  idx <- function(c1) { i <- which(dn %in% c1); if (length(i)) i[1] else NA_integer_ }
  ilon <- idx(c("longitude","lon","x")); ilat <- idx(c("latitude","lat","y"))
  itim <- idx(c("valid_time","time"));   ilev <- idx(c("pressure_level","level"))
  arr <- ncdf4::ncvar_get(nc, vn, collapse_degen = FALSE)
  ord <- c(ilon, ilat, ilev, itim); ord <- ord[!is.na(ord)]
  arr <- aperm(arr, ord)

  lon <- v$dim[[ilon]]$vals; lat <- v$dim[[ilat]]$vals
  tv  <- if (!is.na(itim)) v$dim[[itim]]$vals else 0
  tu  <- if (!is.na(itim)) nc$dim[[dn[itim]]]$units else "seconds since 1970-01-01"
  org <- as.POSIXct(sub("^[a-z]+ since ", "", tu), tz = "UTC")
  tim <- if (grepl("^hours", tu)) org + tv * 3600 else org + tv

  list(var = vn, lon = lon, lat = lat, time = tim,
       lev = if (!is.na(ilev)) v$dim[[ilev]]$vals else NULL,
       arr = arr, ncell = length(lon) * length(lat))
}

# ============================ aggregation ====================================

# Daily statistics over LOCAL (MST) days. Years are processed in order with a
# carry-over buffer, because an MST day spans two UTC days: the local day D runs
# 07Z on D to 07Z on D+1, so the last local day of each file is incomplete until
# the next file is read. Without the carry-over every 31 December would be wrong.
aggregate_variable <- function(v) {
  paths <- file.path(BCFG$raw_dir, sprintf("%s_%d.nc", v$id, BCFG$years))
  have  <- file.exists(paths)
  if (!any(have)) { msg("  no files for ", v$id); return(NULL) }
  paths <- paths[have]

  acc <- setNames(vector("list", length(v$stats)), v$stats)
  days_all <- list()
  carry_v <- NULL; carry_t <- NULL; lon <- NULL; lat <- NULL

  for (i in seq_along(paths)) {
    g <- read_nc_cells(paths[i])
    if (is.null(lon)) { lon <- g$lon; lat <- g$lat }
    a <- g$arr; dim(a) <- c(g$ncell, length(g$time))
    if (!is.null(carry_v)) { a <- cbind(carry_v, a); tim <- c(carry_t, g$time) }
    else tim <- g$time

    ld   <- as.Date(tim + BCFG$tz_shift_h * 3600)
    uniq <- sort(unique(ld))
    last_d <- uniq[length(uniq)]

    # Keep only local days with the FULL complement of samples. An MST day runs
    # 07Z-07Z, so a calendar-year file starts and ends mid-local-day: the first
    # local day holds 7 of 24 hours and the last holds 17. The carry-over below
    # completes the trailing one from the next file, but the very first day of
    # the record and the very last have no neighbour and must be dropped —
    # otherwise the archive opens and closes with a day built from a third of
    # its samples, and nothing in the data would say so.
    # (Arizona does not observe DST, so UTC-7 is constant and every complete
    # local day has exactly length(v$hours) samples.)
    expect <- length(v$hours)
    cnt    <- table(as.character(ld))
    done   <- sort(as.Date(names(cnt))[as.integer(cnt) == expect])
    if (i < length(paths)) done <- done[done != last_d]
    dropped <- as.Date(setdiff(uniq, c(done, last_d)), origin = "1970-01-01")
    if (length(dropped))
      msg("      dropped ", length(dropped), " incomplete local day(s): ",
          paste(format(dropped), collapse = ", "))

    for (st in v$stats) {
      m <- vapply(done, function(dd) {
        cols <- which(ld == dd)
        sub  <- a[, cols, drop = FALSE]
        switch(st,
          max  = Reduce(pmax, lapply(seq_len(ncol(sub)), function(k) sub[, k])),
          min  = Reduce(pmin, lapply(seq_len(ncol(sub)), function(k) sub[, k])),
          mean = rowMeans(sub, na.rm = TRUE))
      }, numeric(nrow(a)))
      acc[[st]][[length(acc[[st]]) + 1]] <- m
    }
    days_all[[length(days_all) + 1]] <- done

    if (i < length(paths)) {
      ci <- which(ld == uniq[length(uniq)])
      carry_v <- a[, ci, drop = FALSE]; carry_t <- tim[ci]
    }
    rm(a, g); invisible(gc(FALSE))
    msg("    ", v$id, " ", BCFG$years[have][i], ": ", length(done), " local days")
  }

  dates <- do.call(c, days_all)
  out <- list()
  for (st in v$stats) {
    mat <- do.call(cbind, acc[[st]])
    rng <- range(mat, na.rm = TRUE)
    lim <- RANGES[[v$id]]
    if (!is.null(lim) && (rng[1] < lim[1] || rng[2] > lim[2]))
      msg("    ! ", v$id, "_", st, " range ", signif(rng[1], 4), "-",
          signif(rng[2], 4), " outside expected ", lim[1], "-", lim[2])
    f <- file.path(BCFG$daily_dir, sprintf("%s%s_daily.rds", v$id, st))
    saveRDS(list(id = paste0(v$id, st), era5 = v$era5, stat = st,
                 hours_utc = v$hours, tz_shift_h = BCFG$tz_shift_h,
                 lon = lon, lat = lat, dates = dates, data = mat,
                 built = Sys.time()), f)
    msg("    wrote ", basename(f), " (", ncol(mat), " days, ",
        round(as.numeric(utils::object.size(mat)) / 1024^2), " MB)")
    out[[st]] <- data.frame(variable = v$id, stat = st, ndays = ncol(mat),
                            ncell = nrow(mat), vmin = signif(rng[1], 6),
                            vmax = signif(rng[2], 6), file = basename(f),
                            stringsAsFactors = FALSE)
  }
  do.call(rbind, out)
}

aggregate_all <- function() {
  if (!dir.exists(BCFG$daily_dir)) dir.create(BCFG$daily_dir, recursive = TRUE)
  msg("Aggregating hourly files to daily statistics over MST days ...")
  do.call(rbind, lapply(BCFG$vars, function(v) {
    msg("  ", v$id, " (", paste(v$stats, collapse = "/"), ", ",
        length(v$hours), " h/day) — ", v$why)
    aggregate_variable(v)
  }))
}

# ============================ driver =========================================

build_main <- function() {
  # NOT check_project_root(): that demanded Data/FODthin.Rdata, a 34 MB file
  # this build never opens and a fresh server clone does not have.
  require_project_root()
  t_start <- Sys.time()
  for (d in c(BCFG$raw_dir, BCFG$daily_dir))
    if (!dir.exists(d)) dir.create(d, recursive = TRUE)
  jobs <- build_jobs()

  n_by <- table(vapply(jobs, `[[`, character(1), "kind"))
  hrs  <- vapply(BCFG$vars, function(v) length(v$hours), numeric(1))
  mb_y <- sum(hrs) * 365 * 7.8 / 1024        # ~7.8 KB per field, measured
  msg(length(jobs), " requests: ",
      paste(sprintf("%s=%d", names(n_by), n_by), collapse = ", "))
  msg("Years ", min(BCFG$years), "-", max(BCFG$years), ", ", BCFG$grid[1],
      " deg, heights ", BCFG$hgt_hour, "Z, daily stats over MST (UTC",
      BCFG$tz_shift_h, ")")
  msg("Projected intermediate download: ~",
      round((mb_y * length(BCFG$years) + 6.7 * length(BCFG$years)) / 1024, 1),
      " GB. Shipped bundle is unaffected (~293 MB).")

  if (isTRUE(BCFG$dry_run)) {
    cat("\n--- DRY RUN ---\n")
    cat("\nvariable  hours/day  stats        rationale\n")
    for (v in BCFG$vars)
      cat(sprintf("  %-7s %6d     %-11s %s\n", v$id, length(v$hours),
                  paste(v$stats, collapse = "+"), v$why))
    for (k in unique(vapply(jobs, `[[`, character(1), "kind"))) {
      j <- jobs[[which(vapply(jobs, `[[`, character(1), "kind") == k)[1]]]
      cat("\n### ", j$id, "\n", sep = ""); str(j$req, max.level = 1, give.attr = FALSE)
    }
    cat("\n", sum(vapply(jobs, file_ok, logical(1))), " of ", length(jobs),
        " already present.\nSet BCFG$dry_run <- FALSE and call build_main().\n", sep = "")
    return(invisible(jobs))
  }

  user <- setup_cds()
  if (!isTRUE(preflight())) {
    msg("Preflight failed — not submitting ", length(jobs), " requests.")
    return(invisible(NULL))
  }
  fetch_jobs(jobs, user)

  present <- jobs[vapply(jobs, file_ok, logical(1))]
  if (!length(present)) { msg("Nothing downloaded."); return(invisible(NULL)) }

  rep <- aggregate_all()

  # heights and orography keep their own verification (R3, R8)
  msg("Verifying pressure-level files ...")
  hj <- Filter(function(j) identical(j$kind, "pressure") && file_ok(j), jobs)
  if (!length(hj)) {
    # Previously this fell through to print(NULL), which renders as a bare "NULL"
    # in the log and reads like a crash rather than "the height request failed
    # and there is nothing to check".
    msg("  none present — the pressure-level request(s) did not complete.")
    msg("  R3 (geopotential -> height) and R8 (longitude convention) are ",
        "therefore UNVERIFIED.")
  } else {
    hp <- do.call(rbind, lapply(hj[seq_len(min(3, length(hj)))], function(j) {
      g <- read_nc_cells(j$path); h <- g$arr / G0
      data.frame(job = j$id, nx = length(g$lon), ny = length(g$lat),
                 dx = abs(diff(sort(g$lon))[1]),
                 lon_ok = !any(g$lon > 180),
                 hmin = round(min(h, na.rm = TRUE)), hmax = round(max(h, na.rm = TRUE)),
                 stringsAsFactors = FALSE)
    }))
    print(hp, row.names = FALSE)
  }

  if (!is.null(rep)) {
    cat("\n----- DAILY AGGREGATES -----\n"); print(rep, row.names = FALSE)
    utils::write.csv(rep, file.path(BCFG$daily_dir, "manifest.csv"), row.names = FALSE)
  }
  if (!isTRUE(BCFG$keep_hourly)) {
    unlink(list.files(BCFG$raw_dir, pattern = "^(gust|cape|t2|d2|pwat|soilw)_\\d{4}\\.nc$",
                      full.names = TRUE))
    msg("Deleted hourly intermediates (keep_hourly = FALSE).")
  }

  missing <- length(pending_jobs(jobs))
  el <- as.numeric(difftime(Sys.time(), t_start, units = "secs"))
  body <- sprintf("Years %d-%d in %s.\n%d/%d requests present.\n%s\n%s",
                  min(BCFG$years), max(BCFG$years), fmt_dur(el),
                  length(jobs) - missing, length(jobs), disk_line(),
                  if (is.null(rep)) "No daily aggregates written." else
                    paste(sprintf("%s%s: %d days", rep$variable, rep$stat, rep$ndays),
                          collapse = "\n"))
  if (missing > 0) notify_warn(paste0(body, "\n\n", missing,
      " request(s) still missing — re-run to resume."))
  else notify_done(body)

  msg("Next: util/gridpack.R (phase 2) quantises Data/era5_raw/daily/*.rds to qs2.")
  invisible(rep)
}

# Sourcing this file runs the dry run, which is the interactive workflow on the
# laptop. build/run_phase1.R sets this FALSE and calls build_main() itself, so
# an unattended run never depends on what the bottom of a sourced file happens
# to do.
if (!exists("ERA5_BUILD_RUN_ON_SOURCE")) ERA5_BUILD_RUN_ON_SOURCE <- TRUE
if (isTRUE(ERA5_BUILD_RUN_ON_SOURCE)) build_main()
