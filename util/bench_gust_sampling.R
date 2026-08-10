# util/bench_gust_sampling.R
# -----------------------------------------------------------------------------
# How much does 3-hourly sampling understate the daily maximum wind gust?
#
# WHY
# The derived daily-statistics entry computes its statistic from a subsample of
# the underlying hourly data, set by `frequency`. Dropping 1_hourly -> 3_hourly
# cuts server-side reads to a third, which is the difference between roughly two
# days and roughly 14 hours for the phase 1 pull. The question is what it costs
# scientifically, and for wind gust specifically the answer is not obvious:
#
#   `10m_wind_gust_since_previous_post_processing` is ALREADY the maximum gust
#   within each hour. Daily max at 1_hourly is the max of 24 such maxima; at
#   3_hourly it is the max of 8, discarding two thirds of them. On a sustained
#   gradient-wind day the peak persists for hours and the subsample lands close.
#   On a convective outflow day the peak is a one- to two-hour spike, and you
#   have roughly a 1-in-3 chance of sampling it at all.
#
#   The convective case is the dry-thunderstorm fire day — the ignition
#   mechanism behind the AZ fire-count days this app ranks. So the concern is
#   not average bias, it is bias concentrated on exactly the days that matter.
#
# WHAT THIS DOES
# Pulls one month of FULL HOURLY gust from `reanalysis-era5-single-levels` (the
# archived hourly entry — no on-the-fly aggregation, so it is cheap and fast),
# then computes the daily maximum three ways and compares:
#   * every hour               <- ground truth
#   * the exact hours CDS would sample at 3_hourly
#   * the exact hours CDS would sample at 6_hourly
#
# The sampled hours are not arbitrary. Per ECMWF's documentation the adaptor
# builds them as [i + (time_shift %% frequency) for i in range(0, 24, freq)].
# With time_zone = utc-07:00 that is a shift of -7, so 3_hourly samples UTC
# hours 02,05,08,...,23 and 6_hourly samples 05,11,17,23. R's %% matches
# Python's for negative operands, so this reproduces it exactly.
#
# Two months are pulled by default: July (monsoon, convective) and April
# (spring gradient winds), so the two regimes can be separated empirically
# rather than asserted.
#
# HOW TO RUN (project root):
#   source("util/bench_gust_sampling.R")
# RUNTIME: two small requests (~744 fields each), minutes. Cached and resumable.
#
# MAC / drafted with Claude, 2026-08
# -----------------------------------------------------------------------------

GCFG <- list(
  months     = list(c(2020, 7), c(2020, 4)),   # monsoon, then spring gradient
  var        = "10m_wind_gust_since_previous_post_processing",
  area       = c(60, -140, 20, -60),
  grid       = c(1.0, 1.0),
  tz_shift_h = -7,               # matches D9, time_zone = utc-07:00
  freqs      = c(1, 3, 6),
  az_box     = c(-115, -109, 31, 37),   # lon_min, lon_max, lat_min, lat_max
  min_gust   = 10,               # m/s; ignore cell-days too calm to care about
  spiky_hours = 2,               # peak width <= this = convective-like
  sustained_hours = 6,           # peak width >= this = gradient-like
  dir        = "./Data/scratch/gust_probe"
)

ERA5_CMP_RUN_ON_SOURCE <- FALSE
source("util/era5_compare.R")
need_pkgs(c("ecmwfr", "ncdf4"))

# ============================ fetch ==========================================

hourly_request <- function(y, m) list(
  dataset_short_name = "reanalysis-era5-single-levels",
  product_type = "reanalysis",
  variable = GCFG$var,
  year  = as.character(y),
  month = sprintf("%02d", m),
  day   = sprintf("%02d", 1:31),
  time  = sprintf("%02d:00", 0:23),      # all 24 hours — this is the point
  area  = GCFG$area, grid = GCFG$grid,
  data_format = "netcdf", download_format = "unarchived")

fetch_month <- function(y, m, user) {
  f <- file.path(GCFG$dir, sprintf("gust_%d%02d.nc", y, m))
  if (file.exists(f) && file.size(f) > 5000) { msg("  cached: ", basename(f)); return(f) }
  before <- list.files(GCFG$dir, full.names = TRUE)
  args <- list(request = c(hourly_request(y, m), list(target = basename(f))),
               transfer = TRUE, path = GCFG$dir, verbose = FALSE, time_out = 3600)
  if (!is.null(user)) args$user <- user
  out <- tryCatch(do.call(ecmwfr::wf_request, args), error = function(e) e)
  if (inherits(out, "error")) stop("CDS request failed: ", conditionMessage(out),
                                   call. = FALSE)
  got <- if (is.character(out) && file.exists(out)) out else {
    nw <- setdiff(list.files(GCFG$dir, full.names = TRUE), before)
    nw <- nw[!dir.exists(nw)]
    nw[order(file.mtime(nw), decreasing = TRUE)][1]
  }
  if (!identical(normalizePath(got), normalizePath(f, mustWork = FALSE)))
    file.rename(got, f)
  msg("  got ", basename(f), " (", round(file.size(f) / 1024), " KB)")
  f
}

# ============================ read ===========================================

read_hourly <- function(path) {
  nc <- ncdf4::nc_open(path); on.exit(ncdf4::nc_close(nc), add = TRUE)
  vn <- setdiff(names(nc$var),
                c("longitude","lon","latitude","lat","valid_time","time",
                  "number","expver"))
  vn <- if (length(vn)) vn[1] else names(nc$var)[1]
  v  <- nc$var[[vn]]
  dn <- vapply(v$dim, function(d) d$name, character(1))
  gx <- function(c1) { i <- which(dn %in% c1); if (length(i)) v$dim[[i[1]]]$vals else NULL }
  lon <- gx(c("longitude","lon")); lat <- gx(c("latitude","lat"))
  tv  <- gx(c("valid_time","time"))
  it  <- which(dn %in% c("valid_time","time"))
  tunit <- nc$dim[[dn[it]]]$units
  # ERA5 netCDF is usually "seconds since 1970-01-01"; handle hours too
  origin <- as.POSIXct(sub("^[a-z]+ since ", "", tunit), tz = "UTC")
  tim <- if (grepl("^hours", tunit)) origin + tv * 3600 else origin + tv
  arr <- ncdf4::ncvar_get(nc, vn, collapse_degen = FALSE)   # [lon, lat, time]
  list(lon = lon, lat = lat, time = tim, arr = arr, var = vn)
}

# ============================ the comparison =================================

# Hours CDS samples for a given frequency, reproducing the adaptor exactly.
cds_hours <- function(freq, shift = GCFG$tz_shift_h) {
  off <- shift %% freq            # R's %% matches Python's for negatives
  seq(off, 23, by = freq)
}

# cell x day matrix of a daily statistic, over LOCAL days.
# FUN = max reproduces daily_max; FUN = mean gives the daily mean of the hourly
# maxima, i.e. "how windy was the day overall" rather than "what was the peak".
daily_agg <- function(g, hours, FUN = max) {
  utc_h  <- as.integer(format(g$time, "%H"))
  keep   <- utc_h %in% hours
  locald <- as.Date(g$time + GCFG$tz_shift_h * 3600)
  d      <- locald[keep]
  a      <- g$arr[, , keep, drop = FALSE]
  dim(a) <- c(dim(a)[1] * dim(a)[2], dim(a)[3])
  days   <- sort(unique(d))
  out    <- vapply(days, function(dd) {
    cols <- which(d == dd)
    if (!length(cols)) rep(NA_real_, nrow(a))
    else suppressWarnings(apply(a[, cols, drop = FALSE], 1, FUN, na.rm = TRUE))
  }, numeric(nrow(a)))
  out[!is.finite(out)] <- NA_real_
  list(m = out, days = days)
}
daily_max <- function(g, hours) daily_agg(g, hours, max)

# How many hours in each local day sit within 20% of that day's peak. A peak
# lasting 1-2 hours is convective-like; 6+ hours is a sustained gradient event.
peak_width <- function(g, truth) {
  locald <- as.Date(g$time + GCFG$tz_shift_h * 3600)
  a <- g$arr; dim(a) <- c(dim(a)[1] * dim(a)[2], dim(a)[3])
  vapply(seq_along(truth$days), function(k) {
    cols <- which(locald == truth$days[k])
    if (!length(cols)) return(rep(NA_real_, nrow(a)))
    sub <- a[, cols, drop = FALSE]
    thr <- truth$m[, k] * 0.8
    rowSums(sub >= thr, na.rm = TRUE)
  }, numeric(nrow(a)))
}

analyse_month <- function(g, label) {
  pw   <- peak_width(g, daily_agg(g, cds_hours(1), max))
  rows <- list()

  # Domain-wide means hide regional structure: the July map shows the bias
  # concentrated over the monsoon Southwest and Sierra Madre while most of the
  # domain is unaffected. The app defaults to AZ, so report that box separately.
  cx <- rep(g$lon, times = length(g$lat))
  cy <- rep(g$lat, each  = length(g$lon))
  regions <- list(
    domain = rep(TRUE, length(cx)),
    AZ_box = cx >= GCFG$az_box[1] & cx <= GCFG$az_box[2] &
             cy >= GCFG$az_box[3] & cy <= GCFG$az_box[4])

  # Compare BOTH daily statistics. A max can only be hurt by discarding
  # samples; a mean is a fair sample of the day, so it should be near-unbiased.
  # If that holds, daily-mean gust is available at 3_hourly for free.
  for (st in c("max", "mean")) {
    FUN   <- get(st)
    truth <- daily_agg(g, cds_hours(1), FUN)
    for (fq in setdiff(GCFG$freqs, 1)) {
     est <- daily_agg(g, cds_hours(fq), FUN)
     for (rg in names(regions)) {
      rmask <- matrix(rep(regions[[rg]], ncol(truth$m)), nrow = nrow(truth$m))
      ok  <- is.finite(truth$m) & is.finite(est$m) &
             truth$m >= GCFG$min_gust & rmask
      if (sum(ok) < 50) next
      d_abs <- (truth$m - est$m)[ok]
      d_rel <- 100 * d_abs / truth$m[ok]
      w     <- pw[ok]
      top   <- truth$m[ok] >= stats::quantile(truth$m[ok], 0.90, na.rm = TRUE)

      rows[[length(rows) + 1]] <- data.frame(
        month = label, region = rg, stat = st, freq = paste0(fq, "_hourly"),
        hours_sampled = paste(sprintf("%02d", cds_hours(fq)), collapse = ","),
        n_cell_days = length(d_abs),
        bias_pct     = round(mean(d_rel), 2),          # signed: + = understates
        abs_err_pct  = round(mean(abs(d_rel)), 2),     # typical error either way
        p90_pct      = round(stats::quantile(d_rel, 0.90), 2),
        p99_pct      = round(stats::quantile(d_rel, 0.99), 2),
        mean_ms      = round(mean(d_abs), 2),
        max_ms       = round(max(d_abs), 2),
        pct_over10   = round(100 * mean(d_rel > 10), 2),
        top_decile_bias_pct = round(mean(d_rel[top]), 2),
        spiky_bias_pct      = round(mean(d_rel[w <= GCFG$spiky_hours]), 2),
        sustained_bias_pct  = round(mean(d_rel[w >= GCFG$sustained_hours]), 2),
        stringsAsFactors = FALSE)
     }
    }
  }
  list(tab = do.call(rbind, rows), truth = daily_agg(g, cds_hours(1), max),
       pw = pw)
}

# ============================ driver =========================================

gust_main <- function() {
  check_project_root()
  if (!dir.exists(GCFG$dir)) dir.create(GCFG$dir, recursive = TRUE)
  user <- setup_cds()

  all_tab <- list(); maps <- list()
  for (ym in GCFG$months) {
    label <- sprintf("%d-%02d", ym[1], ym[2])
    msg("Fetching hourly gust for ", label, " ...")
    f <- fetch_month(ym[1], ym[2], user)
    g <- read_hourly(f)
    msg("  ", length(g$lon), " x ", length(g$lat), " cells, ",
        length(g$time), " hourly steps")
    a <- analyse_month(g, label)
    all_tab[[length(all_tab) + 1]] <- a$tab

    # per-cell mean relative bias at 3_hourly, for the map
    est <- daily_max(g, cds_hours(3))
    ok  <- is.finite(a$truth$m) & is.finite(est$m) & a$truth$m >= GCFG$min_gust
    rel <- 100 * (a$truth$m - est$m) / a$truth$m
    rel[!ok] <- NA
    maps[[label]] <- data.frame(
      x = rep(g$lon, times = length(g$lat)),
      y = rep(g$lat, each  = length(g$lon)),
      bias = rowMeans(rel, na.rm = TRUE), month = label)
  }

  tab <- do.call(rbind, all_tab)
  cat("\n============ DAILY GUST STATISTIC: SAMPLING BIAS ============\n")
  cat("Error relative to using every hour, as a percentage.\n")
  cat("Positive bias = the subsample came in low.\n\n")
  print(tab[order(tab$region, tab$stat, tab$freq, tab$month),
            c("month","region","stat","freq","n_cell_days","bias_pct",
              "abs_err_pct","p90_pct","p99_pct","pct_over10",
              "top_decile_bias_pct","spiky_bias_pct","sustained_bias_pct")],
        row.names = FALSE)
  az <- tab[tab$region == "AZ_box" & tab$stat == "max" & tab$freq == "3_hourly", ]
  if (nrow(az)) {
    cat("\n  AZ box, daily max at 3_hourly: bias ",
        paste(sprintf("%s %.2f%%", az$month, az$bias_pct), collapse = ", "),
        "; windiest decile ",
        paste(sprintf("%s %.2f%%", az$month, az$top_decile_bias_pct),
              collapse = ", "), "\n", sep = "")
  }
  mx <- tab[tab$stat == "max"  & tab$freq == "3_hourly" & tab$region == "domain", ]
  mn <- tab[tab$stat == "mean" & tab$freq == "3_hourly" & tab$region == "domain", ]
  if (nrow(mx) && nrow(mn)) {
    cat("\n  At 3_hourly: daily MAX biased ", round(mean(mx$bias_pct), 2),
        "%, daily MEAN biased ", round(mean(mn$bias_pct), 2), "%.\n", sep = "")
    cat("  -> ", if (abs(mean(mn$bias_pct)) < 2)
           "mean gust is safe at 3_hourly; only the max needs every hour."
         else "both statistics are affected; keep 1_hourly.", "\n", sep = "")
  }
  cat("\nhours sampled:\n")
  hs <- unique(tab[, c("freq", "hours_sampled")])
  for (i in seq_len(nrow(hs)))
    cat("  ", hs$freq[i], ": ", hs$hours_sampled[i], " UTC\n", sep = "")

  mp <- do.call(rbind, maps)
  p <- ggplot(mp, aes(x = x, y = y, fill = bias)) +
    geom_raster() +
    geom_path(data = us_states_df(), aes(x = long, y = lat, group = group),
              inherit.aes = FALSE, colour = "black", linewidth = 0.3) +
    scale_fill_viridis_c(option = "B", direction = -1,
                         name = "mean underestimate (%)") +
    coord_fixed(xlim = range(mp$x), ylim = range(mp$y)) +
    facet_wrap(~month) +
    labs(title = "Daily max 10 m gust: 3-hourly sampling vs every hour",
         subtitle = paste0("Underestimate as % of the true daily maximum, ",
                           "cell-days above ", GCFG$min_gust, " m/s"),
         x = "Longitude", y = "Latitude") +
    theme_minimal() + theme(legend.position = "bottom")
  pf <- "./Data/scratch/gust_sampling_bias.png"
  ggsave(pf, p, width = 13, height = 6, dpi = 130)
  msg("wrote ", pf)

  out <- "./Data/scratch/BENCH_GUST_SAMPLING.md"
  md <- function(df) c(
    paste0("| ", paste(names(df), collapse = " | "), " |"),
    paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|"),
    apply(df, 1, function(r) paste0("| ", paste(trimws(r), collapse = " | "), " |")))
  writeLines(c(
    "# Daily max wind gust — sampling frequency bias", "",
    paste0("Run ", format(Sys.time(), "%Y-%m-%d %H:%M"), "."),
    paste0("Domain ", GCFG$area[3], "-", GCFG$area[1], "N / ",
           abs(GCFG$area[2]), "-", abs(GCFG$area[4]), "W at ", GCFG$grid[1],
           " deg. Local day = UTC", GCFG$tz_shift_h, "."),
    paste0("Cell-days below ", GCFG$min_gust, " m/s excluded."),
    "",
    "`10m_wind_gust_since_previous_post_processing` is already an hourly",
    "maximum, so this measures the cost of taking the max of 8 hourly maxima",
    "instead of 24 — using the exact UTC hours the CDS adaptor would sample.",
    "",
    md(tab), "",
    "## Columns", "",
    "- `stat` — **max** is the daily peak gust; **mean** is the daily average of",
    "  the hourly maxima, i.e. how windy the day was overall. A max can only be",
    "  hurt by discarding samples; a mean is a fair sample of the day and should",
    "  be near-unbiased. If that holds, daily-mean gust is free at 3_hourly.",
    "- `bias_pct` — signed. Positive means the subsample came in low.",
    "- `abs_err_pct` — typical error in either direction, which is the number",
    "  that matters for a mean, where errors cancel in `bias_pct`.",
    "- `top_decile_bias_pct` — bias on the windiest 10% of cell-days. A benign",
    "  overall mean with a large value here means the bias concentrates exactly",
    "  where it does damage.",
    "- `spiky_bias_pct` — days whose peak lasts <= 2 hours (convective outflow).",
    "- `sustained_bias_pct` — days whose peak lasts >= 6 hours (gradient wind).",
    "",
    "## Why there is no easier daily wind product", "",
    "ERA5 archives `10m_u_component_of_wind`, `10m_v_component_of_wind` and the",
    "two gust variables — but **no scalar 10 m wind speed**. Taking daily means",
    "of u and v and then computing sqrt(u^2 + v^2) gives the mean *vector* wind,",
    "not the mean wind *speed*: on a day when the wind backs through a frontal",
    "passage the components cancel and it can read near zero while the wind blew",
    "hard all day. Mean speed can only be had by computing hourly speed first",
    "and then averaging, which the derived entry cannot do — it aggregates each",
    "variable independently.",
    "",
    "The gust variable is therefore the practical route to a daily wind field,",
    "and this table decides which statistic and frequency to take it at.",
    "",
    "See `gust_sampling_bias.png` for the spatial pattern."
  ), out)
  msg("wrote ", out)
  invisible(tab)
}

gust_main()
