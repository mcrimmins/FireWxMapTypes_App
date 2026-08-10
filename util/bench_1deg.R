# util/bench_1deg.R
# -----------------------------------------------------------------------------
# Will the app be quick and responsive with 1.0 deg grids?
#
# Measures, on this machine, the three things that decide it:
#
#   1. STARTUP  — packed size on disk, qs2 load time, and resident RAM for three
#      storage backends (R integer matrix / int16 raw / int8 anomaly raw).
#      RAM, not speed, is the binding constraint at 1.0 deg: 3,321 cells x
#      12,053 days is 40 M values per level, which is 160 MB as R integers and
#      40 MB as int8 raw. Times three levels, that is the difference between
#      comfortably fitting a 1 GB instance and not fitting at all.
#
#   2. PER-RENDER DATA ACCESS — ms to go from "user moved a slider" to a long
#      data frame, comparing the current terra + 10,593-band GeoTIFF path
#      against the section-5 accessor, on the same dates.
#
#   3. RENDER — ms for the actual ggplot draw at 12 and 30 facets, at the app's
#      real plot size (950 x 750), for three scenarios:
#        S1  2.5 deg heights + 0.5 deg precip   (today)
#        S2  1.0 deg heights + 1.0 deg precip   (scope section 3 proposal)
#        S3  1.0 deg heights + 0.5 deg precip   (keeps the fill sharp)
#
# HOW REAL IS THIS:
#   * Codec sizes are calibrated on the REAL ERA5 1.0 deg fields already sitting
#     in Data/scratch/era5_cache from the D1 run — real spatial structure, so
#     the bytes/value figure is trustworthy. Only the record LENGTH is extrapolated.
#   * Fire points, dates, precip and the 2.5 deg heights are all real.
#   * The full-length 1.0 deg record is synthesised by tiling those real days,
#     so contour density (and therefore draw cost) is realistic, but do not read
#     anything meteorological into the S2/S3 pictures.
#
# HOW TO RUN (project root):
#   source("util/bench_1deg.R")
#
# PREREQ: renv::install("qs2")   # plus ecmwfr/ncdf4 from the D1 step
# RUNTIME: ~10-20 min, almost all of it zstd-19 packing (~440 MB pushed through
#          the compressor). That is a one-time BUILD cost, not an app cost, and
#          it is reported separately from everything else. Set
#          BCFG$test_delta <- FALSE and/or BCFG$compress_level <- 9 for a quick
#          pass; sizes will be slightly larger but the timings are unaffected.
# PEAK RAM: ~1.5 GB while packing — it holds a full-record double matrix plus
#          all three encodings at once, by design.
#
# MAC / drafted with Claude, 2026-08
# -----------------------------------------------------------------------------

BCFG <- list(
  nx = 81, ny = 41,                       # 1.0 deg over 140-60W / 20-60N
  date_start   = as.Date("1992-01-01"),
  date_end     = as.Date("2024-12-31"),   # 12,053 days, FPA-FOD 7th ed. record
  codec_level  = 500,                     # size/RAM tested on one level, x3 projected
  facet_counts = c(12, 30),               # app default 12; slider max 30
  reps         = 3,                       # each timing repeated, median reported
  plot_w = 950, plot_h = 750,             # app.R fireMap plotOutput size
  compress_level = 19,                    # zstd level used in the scope doc
  nthreads     = 4,                       # qs2 packing threads
  test_delta   = TRUE,                    # spatial x-delta size check (+2-4 min)
  anom_step    = 5,                       # metres per int8 step
  scratch  = "./Data/scratch",
  era5_dir = "./Data/scratch/era5_cache",
  seed = 42
)

ERA5_CMP_RUN_ON_SOURCE <- FALSE
source("util/era5_compare.R")   # reuse read_era5_nc, select_fire_days, map_layers

need_pkgs(c("qs2", "terra", "ncdf4"))

# ============================ helpers ========================================

# Median wall-clock seconds over BCFG$reps evaluations. substitute/eval rather
# than a promise, so the expression genuinely re-runs each rep.
timeit <- function(expr, reps = BCFG$reps) {
  e <- substitute(expr); pf <- parent.frame()
  t <- vapply(seq_len(reps), function(i) {
    invisible(gc(FALSE))
    t0 <- proc.time()[["elapsed"]]
    eval(e, pf)
    proc.time()[["elapsed"]] - t0
  }, numeric(1))
  stats::median(t)
}

mb  <- function(bytes) round(bytes / 1024^2, 1)
ms  <- function(sec)   round(sec * 1000)
obj_mb <- function(x)  mb(as.numeric(utils::object.size(x)))

rss_mb <- function() {
  if (requireNamespace("ps", quietly = TRUE)) {
    return(mb(ps::ps_memory_info(ps::ps_handle())[["rss"]]))
  }
  NA_real_
}

BENCH <- new.env(parent = emptyenv())   # results collect here

record <- function(section, metric, value, unit = "", note = "") {
  BENCH$rows[[length(BENCH$rows) + 1]] <- data.frame(
    section = section, metric = metric, value = value, unit = unit, note = note,
    stringsAsFactors = FALSE)
  invisible(NULL)
}
BENCH$rows <- list()

# ============================ reference field ================================
# Real ERA5 1.0 deg fields from the D1 cache -> cells x days matrix, one level.

reference_field <- function(level_mb = BCFG$codec_level) {
  fs <- list.files(BCFG$era5_dir, pattern = "^era5_z_1p00_.*\\.nc$", full.names = TRUE)
  if (!length(fs)) {
    stop("No 1.0 deg ERA5 files in ", BCFG$era5_dir,
         ".\nRun the D1 download first: main(steps = 'download') in ",
         "util/era5_compare.R", call. = FALSE)
  }
  cols <- lapply(fs, function(f) {
    g <- read_era5_nc(f)
    g$df$Geopotential_Height[g$df$level == level_mb]
  })
  n <- unique(lengths(cols))
  if (length(n) != 1) stop("Inconsistent cell counts across cached files.", call. = FALSE)
  m <- matrix(unlist(cols), nrow = n)
  msg("Reference field: ", nrow(m), " cells x ", ncol(m), " real ERA5 days at ",
      level_mb, " mb (range ", round(min(m)), "-", round(max(m)), " m)")
  if (nrow(m) != BCFG$nx * BCFG$ny) {
    msg("  note: ", nrow(m), " cells, expected ", BCFG$nx * BCFG$ny,
        " — using the actual count")
    BCFG$nx <<- length(unique(round(read_era5_nc(fs[1])$lon, 6)))
    BCFG$ny <<- nrow(m) / BCFG$nx
  }
  m
}

# Extend the real days to the full record. Each synthetic day is a real day plus
# a smooth seasonal offset, so the field keeps real spatial structure (which is
# what both compression and contour cost respond to).
synth_record <- function(ref, dates) {
  nt <- length(dates)
  set.seed(BCFG$seed)
  src <- rep_len(seq_len(ncol(ref)), nt)
  doy <- as.integer(format(dates, "%j"))
  off <- 60 * sin(2 * pi * (doy - 15) / 365.25) + stats::rnorm(nt, 0, 12)
  m <- ref[, src, drop = FALSE]
  dimnames(m) <- NULL
  # column-at-a-time rather than sweep(): sweep would duplicate a 320 MB matrix,
  # this modifies in place (refcount is 1 here)
  for (k in seq_len(nt)) m[, k] <- m[, k] + off[k]
  m
}

# ============================ codecs =========================================
# Each returns list(store = <object>, decode = function(store, j) matrix).
# `j` is a vector of day (column) indices.

ncell_of <- function(store) store$ncell

codec_int <- function(m) {
  v <- matrix(as.integer(round(m)), nrow = nrow(m))
  list(kind = "R integer matrix", bytes_per_value = 4,
       store = list(data = v, ncell = nrow(m)),
       decode = function(s, j) s$data[, j, drop = FALSE])
}

codec_raw16 <- function(m) {
  v <- as.integer(round(m))
  r <- writeBin(v, raw(), size = 2L)
  list(kind = "int16 raw", bytes_per_value = 2,
       store = list(data = r, ncell = nrow(m)),
       decode = function(s, j) {
         n <- s$ncell
         out <- integer(n * length(j))
         for (k in seq_along(j)) {
           from <- (j[k] - 1L) * n * 2L + 1L
           out[((k - 1L) * n + 1L):(k * n)] <-
             readBin(s$data[from:(from + n * 2L - 1L)], "integer",
                     n = n, size = 2L, signed = TRUE)
         }
         matrix(out, nrow = n)
       })
}

codec_raw8_anom <- function(m, step = BCFG$anom_step) {
  ref <- rowMeans(m)                       # per-cell climatology
  a   <- round((m - ref) / step)
  clipped <- mean(abs(a) > 127)
  a[a >  127] <-  127
  a[a < -127] <- -127
  r <- as.raw(as.integer(a) + 128L)
  # round-trip error on a subsample of columns — the full matrix diff would cost
  # another 320 MB for no extra information
  jj  <- unique(round(seq(1, ncol(m), length.out = min(200, ncol(m)))))
  err <- max(abs(m[, jj] - (a[, jj] * step + ref)))
  list(kind = "int8 anomaly raw", bytes_per_value = 1,
       clipped = clipped, max_err_m = err,
       store = list(data = r, ref = ref, ncell = nrow(m), step = step),
       decode = function(s, j) {
         n <- s$ncell
         idx <- as.vector(outer(seq_len(n), (j - 1L) * n, "+"))
         matrix(as.integer(s$data[idx]) - 128L, nrow = n) * s$step + s$ref
       })
}

# Spatial x-delta — affects compressed size only, not RAM or decode cost.
xdelta <- function(m, nx, ny) {
  a <- array(as.integer(round(m)), c(nx, ny, ncol(m)))
  a[-1, , ] <- a[-1, , ] - a[-nx, , ]
  as.vector(a)
}

# ============================ 1. startup =====================================

bench_startup <- function(ref, dates) {
  msg("=== 1. STARTUP: size, load time, resident RAM ===")
  m <- synth_record(ref, dates)
  nval <- length(m)
  msg("Full record: ", nrow(m), " cells x ", ncol(m), " days = ",
      format(nval, big.mark = ","), " values per level")

  codecs <- list(codec_int(m), codec_raw16(m), codec_raw8_anom(m))
  rows <- list()

  for (cd in codecs) {
    f <- file.path(BCFG$scratch, paste0("bench_", gsub("[^a-z0-9]", "", tolower(cd$kind)), ".qs2"))
    pack_t <- timeit(qs2::qs_save(cd$store, f, compress_level = BCFG$compress_level,
                                  nthreads = BCFG$nthreads), reps = 1)
    sz <- file.size(f)
    load_t <- timeit(qs2::qs_read(f))
    resident <- as.numeric(utils::object.size(cd$store))

    rows[[length(rows) + 1]] <- data.frame(
      backend        = cd$kind,
      disk_MB        = mb(sz),
      bytes_per_val  = round(sz / nval, 3),
      pack_s         = round(pack_t, 1),
      load_s         = round(load_t, 2),
      resident_MB    = mb(resident),
      three_levels_MB = mb(resident * 3),
      lossy_to_m     = if (!is.null(cd$max_err_m)) round(cd$max_err_m, 1) else 0.5,
      stringsAsFactors = FALSE)

    if (!is.null(cd$clipped) && cd$clipped > 0) {
      msg("  int8 anomaly: ", round(cd$clipped * 100, 3),
          "% of values clipped at +/-127 steps (+/-", 127 * BCFG$anom_step, " m)")
      record("startup", "int8 clipping", round(cd$clipped * 100, 3), "%")
    }
  }

  # size-only variant: does the spatial delta still pay at 1.0 deg?
  if (isTRUE(BCFG$test_delta)) {
    fd <- file.path(BCFG$scratch, "bench_int16delta.qs2")
    qs2::qs_save(list(data = xdelta(m, BCFG$nx, BCFG$ny), ncell = nrow(m)),
                 fd, compress_level = BCFG$compress_level, nthreads = BCFG$nthreads)
    msg("  int16 + spatial x-delta, size only: ", mb(file.size(fd)), " MB (",
        round(file.size(fd) / nval, 3), " bytes/value)")
    record("startup", "int16 x-delta disk", mb(file.size(fd)), "MB")
  }

  rm(m); invisible(gc(FALSE))   # the 320 MB double matrix is no longer needed
  out <- do.call(rbind, rows)
  print(out, row.names = FALSE)
  BENCH$startup <- out
  BENCH$codecs  <- codecs
  invisible(out)
}

# ============================ 2. data access =================================

# The section-5 accessor, as it would actually be written.
read_grid_long <- function(codec, dates_all, want, coords) {
  j <- match(as.integer(want), as.integer(dates_all))
  j <- j[!is.na(j)]
  if (!length(j)) return(NULL)
  vals <- codec$decode(codec$store, j)
  data.frame(
    x     = rep(coords$x, times = length(j)),
    y     = rep(coords$y, times = length(j)),
    Date  = rep(dates_all[j], each = nrow(vals)),
    Geopotential_Height = as.vector(vals))
}

# The current path, verbatim from app.R L223-227.
current_gh_long <- function(r, want) {
  sub <- r[[which(terra::time(r) %in% want)]]
  names(sub) <- terra::time(sub)
  d <- as.data.frame(sub, xy = TRUE)
  tidyr::pivot_longer(d, cols = -c(x, y), names_to = "Date",
                      values_to = "Geopotential_Height")
}

bench_access <- function(dates_all, sel_dates, coords) {
  msg("=== 2. PER-RENDER DATA ACCESS ===")
  need_pkgs("tidyr")
  r25 <- terra::rast("./Data/R2_hgt_500mb_1992_2020_CONUS.tif")
  rows <- list()

  for (n in BCFG$facet_counts) {
    want <- sel_dates[seq_len(min(n, length(sel_dates)))]
    want_old <- want[want <= as.Date("2020-12-31")]   # R2 file stops in 2020

    t_old <- timeit(current_gh_long(r25, want_old))
    n_old <- nrow(current_gh_long(r25, want_old))

    for (cd in BENCH$codecs) {
      t_new <- timeit(read_grid_long(cd, dates_all, want, coords))
      n_new <- nrow(read_grid_long(cd, dates_all, want, coords))
      rows[[length(rows) + 1]] <- data.frame(
        facets = n, path = paste0("new: ", cd$kind),
        rows_out = n_new, ms = ms(t_new), stringsAsFactors = FALSE)
    }
    rows[[length(rows) + 1]] <- data.frame(
      facets = n, path = "current: terra + GeoTIFF + pivot_longer",
      rows_out = n_old, ms = ms(t_old), stringsAsFactors = FALSE)
  }

  out <- do.call(rbind, rows)
  out <- out[order(out$facets, out$ms), ]
  print(out, row.names = FALSE)
  BENCH$access <- out
  invisible(out)
}

# ============================ 3. render ======================================

precip_long <- function(r, want, agg_factor = 1) {
  sub <- r[[which(terra::time(r) %in% want)]]
  if (agg_factor > 1) sub <- terra::aggregate(sub, fact = agg_factor, fun = "mean",
                                              na.rm = TRUE)
  d  <- as.data.frame(sub, xy = TRUE)
  nm <- as.Date(terra::time(sub))
  do.call(rbind, lapply(seq_along(nm), function(i)
    data.frame(x = d$x, y = d$y, Date = nm[i], Precipitation = d[[2 + i]])))
}

build_plot <- function(gh, precip, fires, dates, title) {
  lv <- as.character(dates)
  gh$Date     <- factor(gh$Date, levels = lv)
  precip$Date <- factor(precip$Date, levels = lv)
  fires$Date  <- factor(fires$DISCOVERY_DATE, levels = lv)
  fires <- fires[!is.na(fires$Date), ]
  ext <- fire_extent(fires, CFG$expd_app)
  ggplot() +
    map_layers(precip, fires, fire_stats_of(fires), ext$x, ext$y) +
    geom_contour(data = gh, aes(x = x, y = y, z = Geopotential_Height,
                                color = after_stat(level)), binwidth = 10) +
    facet_wrap(~Date) +
    labs(title = title, x = "Longitude", y = "Latitude",
         color = "Geopotential Height (m)", size = "Fire Size Class")
}

draw_time <- function(p) {
  timeit({
    f <- tempfile(fileext = ".png")
    grDevices::png(f, width = BCFG$plot_w, height = BCFG$plot_h, res = 96)
    print(p)
    grDevices::dev.off()
    unlink(f)
  })
}

bench_render <- function(dates_all, sel_dates, coords, fires) {
  msg("=== 3. RENDER (", BCFG$plot_w, "x", BCFG$plot_h, " png, as Shiny draws it) ===")
  r25  <- terra::rast("./Data/R2_hgt_500mb_1992_2020_CONUS.tif")
  rprc <- terra::rast(switch(CFG$precip_var,
    precip14 = "./Data/CPC_Global_precip_14dyPercAvg_1992_2020_CONUS_INT.tif",
    precip90 = "./Data/CPC_Global_precip_90dyPercAvg_1992_2020_CONUS_INT.tif"))
  cd <- BENCH$codecs[[which(vapply(BENCH$codecs, function(z)
    z$kind == "int8 anomaly raw", logical(1)))]]

  rows <- list()
  for (n in BCFG$facet_counts) {
    want <- sel_dates[seq_len(min(n, length(sel_dates)))]
    want <- want[want <= as.Date("2020-12-31")]       # so all three use one date set

    gh25 <- current_gh_long(r25, want)
    gh25$Date <- as.Date(gh25$Date)
    gh10 <- read_grid_long(cd, dates_all, want, coords)
    pr05 <- precip_long(rprc, want, agg_factor = 1)
    pr10 <- precip_long(rprc, want, agg_factor = 2)

    scen <- list(
      S1 = list(lab = "S1 today: 2.5 deg hgt + 0.5 deg precip", gh = gh25, pr = pr05),
      S2 = list(lab = "S2       1.0 deg hgt + 1.0 deg precip", gh = gh10, pr = pr10),
      S3 = list(lab = "S3       1.0 deg hgt + 0.5 deg precip", gh = gh10, pr = pr05))

    for (nm in names(scen)) {
      s <- scen[[nm]]
      p <- build_plot(s$gh, s$pr, fires, want, s$lab)
      t <- draw_time(p)
      rows[[length(rows) + 1]] <- data.frame(
        facets = length(want), scenario = s$lab,
        gh_rows = nrow(s$gh), precip_rows = nrow(s$pr),
        total_rows = nrow(s$gh) + nrow(s$pr),
        draw_ms = ms(t), stringsAsFactors = FALSE)
      msg("  ", length(want), " facets  ", s$lab, "  ", ms(t), " ms")
    }
    rm(gh25, gh10, pr05, pr10); invisible(gc(FALSE))
  }

  out <- do.call(rbind, rows)
  print(out, row.names = FALSE)
  BENCH$render <- out
  invisible(out)
}

# ============================ report =========================================

write_bench_report <- function() {
  f <- file.path(BCFG$scratch, "BENCH_1DEG.md")
  st <- BENCH$startup; ac <- BENCH$access; rn <- BENCH$render

  md_table <- function(df) {
    c(paste0("| ", paste(names(df), collapse = " | "), " |"),
      paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|"),
      apply(df, 1, function(r) paste0("| ", paste(trimws(r), collapse = " | "), " |")))
  }

  best <- st[which.min(st$three_levels_MB), ]
  cur  <- ac[grepl("^current", ac$path) & ac$facets == BCFG$facet_counts[1], ]
  new  <- ac[grepl("int8", ac$path) & ac$facets == BCFG$facet_counts[1], ]
  s1   <- rn[grepl("^S1", rn$scenario), ]
  s2   <- rn[grepl("^S2", rn$scenario), ]
  s3   <- rn[grepl("^S3", rn$scenario), ]

  lines <- c(
    "# 1.0 deg responsiveness benchmark", "",
    paste0("Run ", format(Sys.time(), "%Y-%m-%d %H:%M"), " on ",
           R.version$platform, ", R ", getRversion(), "."),
    paste0("Grid ", BCFG$nx, " x ", BCFG$ny, " = ", BCFG$nx * BCFG$ny,
           " cells; record ", format(BCFG$date_start), " to ", format(BCFG$date_end),
           " (", as.integer(BCFG$date_end - BCFG$date_start) + 1L, " days)."),
    paste0("Codec sizes calibrated on real ERA5 1.0 deg fields from the D1 cache; ",
           "record length extrapolated."),
    "",
    "## 1. Startup — one level", "", md_table(st), "",
    paste0("Lowest-RAM backend: **", best$backend, "**, ", best$resident_MB,
           " MB per level, ", best$three_levels_MB, " MB for all three, ",
           best$disk_MB, " MB on disk, ", best$load_s, " s to load."),
    "",
    "## 2. Per-render data access", "", md_table(ac), "",
    if (nrow(cur) && nrow(new))
      paste0("At ", BCFG$facet_counts[1], " facets the accessor is ",
             round(cur$ms / max(new$ms, 1), 1), "x faster than the current ",
             "terra + GeoTIFF + pivot_longer path (", new$ms, " ms vs ",
             cur$ms, " ms).") else "",
    "",
    "## 3. Render", "", md_table(rn), "",
    if (nrow(s1) && nrow(s2))
      paste0("S2 vs S1 draw time: ", paste(sprintf("%d facets %+d ms",
             as.integer(s2$facets), as.integer(s2$draw_ms - s1$draw_ms)),
             collapse = "; "), ".") else "",
    if (nrow(s3) && nrow(s1))
      paste0("S3 vs S1 draw time: ", paste(sprintf("%d facets %+d ms",
             as.integer(s3$facets), as.integer(s3$draw_ms - s1$draw_ms)),
             collapse = "; "), ".") else "",
    "",
    "## Caveats", "",
    "- The full-length 1.0 deg record is synthesised from real ERA5 days, so",
    "  compression may be flattered slightly; contour density is realistic.",
    "- Resident RAM here is `object.size` of the grid objects only. Add the FOD",
    "  data frame, R itself, and the shiny/terra/ggplot stack for a deploy figure.",
    "- Draw time is a cold draw each rep; Shiny caches nothing between renders,",
    "  so this is the right comparison."
  )
  writeLines(lines, f)
  msg("wrote ", f)
  f
}

# ============================ driver =========================================

bench_main <- function() {
  check_project_root(); ensure_dirs()
  r0 <- rss_mb()
  if (!is.na(r0)) msg("Process RSS at start: ", r0, " MB")

  dates_all <- seq(BCFG$date_start, BCFG$date_end, by = "day")
  msg("Record length: ", length(dates_all), " days")

  ref <- reference_field()
  g   <- read_era5_nc(list.files(BCFG$era5_dir, pattern = "^era5_z_1p00_",
                                 full.names = TRUE)[1])
  coords <- list(x = rep(g$lon, times = length(g$lat)),
                 y = rep(g$lat, each  = length(g$lon)))

  # real fire days + points, same ranking as the app
  sel <- select_fire_days(utils::modifyList(CFG, list(n_days = max(BCFG$facet_counts))))
  msg("Using ", length(sel$dates), " real AZ fire days for the render test")

  bench_startup(ref, dates_all)
  bench_access(dates_all, sel$dates, coords)
  bench_render(dates_all, sel$dates, coords, sel$fires)

  r1 <- rss_mb()
  if (!is.na(r1)) {
    msg("Process RSS at end: ", r1, " MB (started at ", r0, ")")
    record("startup", "process RSS end", r1, "MB")
  } else {
    msg("Install 'ps' for a real process-RSS reading: renv::install('ps')")
  }

  write_bench_report()
  msg("Done.")
  invisible(BENCH)
}

bench_main()
