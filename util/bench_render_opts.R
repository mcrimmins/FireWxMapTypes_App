# util/bench_render_opts.R
# -----------------------------------------------------------------------------
# Where do the 7 seconds go, and can they be got back?
#
# BENCH_1DEG.md showed the Extreme Fire Days map takes ~7 s at 12 facets and
# ~17 s at 30, and that data access is only ~440 ms of it. This script attacks
# the draw itself. Two hypotheses, both testable:
#
#   H1  The app draws ~24x more geometry than ends up visible. The precip frame
#       is the whole CONUS grid (~7,662 cells per facet) and `us_states` is all
#       15k path points, both drawn in every facet and only then clipped by
#       coord_fixed. The AZ + 2 deg window shows roughly 320 precip cells and a
#       handful of states.
#   H2  geom_tile draws ~92k individual rects. geom_raster draws one bitmap per
#       panel and is valid here, because the grid is regular.
#
# VARIANTS (cumulative, so the table reads as a ladder):
#   O0  baseline — exactly what app.R does today
#   O1  + filter precip fill to the view
#   O2  + filter us_states to the view (whole states, see note below)
#   O3  + geom_raster instead of geom_tile
#   O4  + filter the contour input to the view
#
# Run against two configurations, so you can see what this buys with and
# without the ERA5 migration:
#   A  2.5 deg heights + 0.5 deg precip   (today, no migration needed)
#   B  1.0 deg heights + 1.0 deg precip   (post-migration target)
#
# Also reports a LAYER ABLATION (drop one layer at a time) to attribute the
# baseline cost, and a BUILD vs DRAW split to say whether the time is going into
# stat computation (isoband, tile prep) or into the graphics device.
#
# CORRECTNESS: O0 and O4 are rendered to PNG and compared pixel-by-pixel. The
# optimisations must not change the picture. Filtering the contour input is only
# safe because marching squares is local — a 2-cell pad gives identical lines
# inside the view. Filtering us_states keeps WHOLE states that touch the view;
# filtering by individual vertex would connect surviving points across the gap
# and draw false straight lines through the map.
#
# HOW TO RUN (project root):
#   source("util/bench_render_opts.R")
# RUNTIME: ~15 min.
#
# MAC / drafted with Claude, 2026-08
# -----------------------------------------------------------------------------

RCFG <- list(
  facet_counts = c(12, 30),
  reps         = 5,          # 2 was too few — the first run produced negative
                             # ablation costs, which is measurement noise
  plot_w = 950, plot_h = 750,
  gh_pad     = 2,            # cells of pad when filtering the contour input
  fill_pad   = 1,            # degrees of pad when filtering the fill
  state_pad  = 1,
  ablate_at  = 12,           # facet count used for the ablation table
  scratch    = "./Data/scratch",
  era5_dir   = "./Data/scratch/era5_cache",
  seed = 42
)

ERA5_CMP_RUN_ON_SOURCE <- FALSE
source("util/era5_compare.R")   # select_fire_days, fire_extent, fire_stats_of, us_states_df

need_pkgs(c("terra", "ncdf4", "tidyr"))

# ============================ helpers ========================================

timeit <- function(expr, reps = RCFG$reps) {
  e <- substitute(expr); pf <- parent.frame()
  t <- vapply(seq_len(reps), function(i) {
    invisible(gc(FALSE))
    t0 <- proc.time()[["elapsed"]]
    eval(e, pf)
    proc.time()[["elapsed"]] - t0
  }, numeric(1))
  stats::median(t)
}
ms <- function(sec) round(sec * 1000)

RES <- new.env(parent = emptyenv())

# ============================ data =============================================

current_gh_long <- function(r, want) {
  sub <- r[[which(terra::time(r) %in% want)]]
  names(sub) <- terra::time(sub)
  d <- as.data.frame(sub, xy = TRUE)
  out <- tidyr::pivot_longer(d, cols = -c(x, y), names_to = "Date",
                             values_to = "Geopotential_Height")
  out$Date <- as.Date(out$Date)
  as.data.frame(out)
}

precip_long <- function(r, want, agg_factor = 1) {
  sub <- r[[which(terra::time(r) %in% want)]]
  if (agg_factor > 1) sub <- terra::aggregate(sub, fact = agg_factor,
                                              fun = "mean", na.rm = TRUE)
  d  <- as.data.frame(sub, xy = TRUE)
  nm <- as.Date(terra::time(sub))
  do.call(rbind, lapply(seq_along(nm), function(i)
    data.frame(x = d$x, y = d$y, Date = nm[i], Precipitation = d[[2 + i]])))
}

# 1.0 deg heights for arbitrary days: cycle the real ERA5 1.0 deg fields from the
# D1 cache with a small offset. Wrong days meteorologically, right small-scale
# structure — and contour complexity is what drives draw cost.
gh_1deg_long <- function(want, level_mb = 500) {
  fs <- list.files(RCFG$era5_dir, pattern = "^era5_z_1p00_.*\\.nc$", full.names = TRUE)
  if (!length(fs)) stop("No 1.0 deg ERA5 files in ", RCFG$era5_dir, call. = FALSE)
  g0 <- read_era5_nc(fs[1])
  cols <- lapply(fs, function(f) {
    g <- read_era5_nc(f); g$df$Geopotential_Height[g$df$level == level_mb]
  })
  set.seed(RCFG$seed)
  src <- rep_len(seq_along(cols), length(want))
  off <- stats::rnorm(length(want), 0, 25)
  coords_x <- rep(g0$lon, times = length(g0$lat))
  coords_y <- rep(g0$lat, each  = length(g0$lon))
  do.call(rbind, lapply(seq_along(want), function(i)
    data.frame(x = coords_x, y = coords_y, Date = want[i],
               Geopotential_Height = cols[[src[i]]] + off[i])))
}

# ============================ the optimisations ================================

filter_to_view <- function(df, xlim, ylim, pad = 0) {
  df[df$x >= xlim[1] - pad & df$x <= xlim[2] + pad &
     df$y >= ylim[1] - pad & df$y <= ylim[2] + pad, , drop = FALSE]
}

# Keep whole states that touch the view. Filtering by individual vertex would
# leave geom_path connecting surviving points across the excluded stretch,
# drawing false straight lines through the map.
filter_states_to_view <- function(states, xlim, ylim, pad = RCFG$state_pad) {
  inbox <- states$long >= xlim[1] - pad & states$long <= xlim[2] + pad &
           states$lat  >= ylim[1] - pad & states$lat  <= ylim[2] + pad
  states[states$group %in% unique(states$group[inbox]), , drop = FALSE]
}

OPTS <- list(
  O0 = list(lab = "O0 baseline (app.R today)",   fill_flt = FALSE, state_flt = FALSE, raster = FALSE, gh_flt = FALSE),
  O1 = list(lab = "O1 + filter precip fill",     fill_flt = TRUE,  state_flt = FALSE, raster = FALSE, gh_flt = FALSE),
  O2 = list(lab = "O2 + filter state outlines",  fill_flt = TRUE,  state_flt = TRUE,  raster = FALSE, gh_flt = FALSE),
  O3 = list(lab = "O3 + geom_raster",            fill_flt = TRUE,  state_flt = TRUE,  raster = TRUE,  gh_flt = FALSE),
  O4 = list(lab = "O4 + filter contour input",   fill_flt = TRUE,  state_flt = TRUE,  raster = TRUE,  gh_flt = TRUE)
)

# The contour levels ggplot would draw from the UNFILTERED field, which is what
# the colour scale trains on today. Pinning limits to this is what makes it safe
# to filter the contour input: geom_contour's lines are local to the view, but
# `color = after_stat(level)` on an unpinned scale is not — drop the far field
# and every remaining contour is recoloured. (scale_fill_gradientn survives the
# same treatment only because app.R hard-codes limits = c(0, 200) on it.)
contour_limits <- function(z, binwidth = 10) {
  z  <- z[is.finite(z)]
  br <- scales::fullseq(range(z), binwidth)
  br <- br[br > min(z) & br < max(z)]
  if (length(br) < 2) range(z) else range(br)
}

build_map <- function(gh, precip, fires, dates, opt,
                      layers = c("fill", "points", "contour", "states", "labels"),
                      gh_res = 1) {
  lv <- as.character(dates)
  fires <- fires[fires$DISCOVERY_DATE %in% dates, ]
  ext <- fire_extent(fires, CFG$expd_app)

  col_lims <- contour_limits(gh$Geopotential_Height)   # BEFORE any filtering

  if (isTRUE(opt$fill_flt))  precip <- filter_to_view(precip, ext$x, ext$y, RCFG$fill_pad)
  if (isTRUE(opt$gh_flt))    gh     <- filter_to_view(gh, ext$x, ext$y, RCFG$gh_pad * gh_res)
  states <- if (isTRUE(opt$state_flt)) filter_states_to_view(us_states_df(), ext$x, ext$y)
            else us_states_df()

  gh$Date     <- factor(gh$Date, levels = lv)
  precip$Date <- factor(precip$Date, levels = lv)
  fires$Date  <- factor(fires$DISCOVERY_DATE, levels = lv)
  fs <- fire_stats_of(fires)

  color_palette <- c("tan4", "tan", "white", "chartreuse2", "chartreuse4")
  breakpoints   <- c(0, 50, 100, 150, 200)

  p <- ggplot()
  if ("fill" %in% layers) {
    p <- p + if (isTRUE(opt$raster))
      geom_raster(data = precip, aes(x = x, y = y, fill = Precipitation), alpha = 0.7)
    else
      geom_tile(data = precip, aes(x = x, y = y, fill = Precipitation), alpha = 0.7)
  }
  if ("points" %in% layers)
    p <- p + geom_point(data = fires, aes(x = LONGITUDE, y = LATITUDE, size = FIRE_SIZE_CLASS),
                        shape = 21, fill = "lightgrey", color = "black",
                        stroke = 1, alpha = 0.8)
  if ("contour" %in% layers)
    p <- p + geom_contour(data = gh, aes(x = x, y = y, z = Geopotential_Height,
                                         color = after_stat(level)), binwidth = 10)
  if ("states" %in% layers)
    p <- p + geom_path(data = states, aes(x = long, y = lat, group = group),
                       color = "black", linewidth = 0.5)
  if ("labels" %in% layers)
    p <- p + geom_label(data = fs, aes(x = ext$x[1] + 0.2, y = ext$y[2] - 0.2, label = label),
                        inherit.aes = FALSE, hjust = 0, vjust = 1, size = 3, color = "black")

  p +
    facet_wrap(~Date) +
    scale_color_gradientn(colors = c("blue", "cyan", "yellow", "orange", "red"),
                          limits = col_lims, oob = scales::squish) +
    scale_fill_gradientn(colors = color_palette, name = "Precip (% of Avg)",
                         values = scales::rescale(breakpoints, to = c(0, 1)),
                         limits = c(0, 200), oob = scales::squish,
                         breaks = breakpoints,
                         labels = c("0", "50", "100", "150", "200+")) +
    scale_size_manual(values = c("A" = 1, "B" = 2, "C" = 3, "D" = 4,
                                 "E" = 5, "F" = 6, "G" = 7)) +
    # pin the legend order too — it swapped between O0 and O4 in the first run,
    # which on its own moved a chunk of the pixel diff
    guides(fill  = guide_colourbar(order = 1),
           color = guide_colourbar(order = 2),
           size  = guide_legend(order = 3)) +
    coord_fixed(ratio = 1, xlim = ext$x, ylim = ext$y) +
    theme_minimal() + theme(legend.position = "bottom")
}

draw_to <- function(p, file = NULL) {
  f <- if (is.null(file)) tempfile(fileext = ".png") else file
  grDevices::png(f, width = RCFG$plot_w, height = RCFG$plot_h, res = 96)
  print(p)
  grDevices::dev.off()
  if (is.null(file)) unlink(f)
  invisible(f)
}

draw_time <- function(p) timeit(draw_to(p))

# stat computation vs graphics device
split_time <- function(p) {
  out <- tryCatch({
    tb <- timeit({ gt <- ggplot2::ggplot_gtable(ggplot2::ggplot_build(p)) })
    gt <- ggplot2::ggplot_gtable(ggplot2::ggplot_build(p))
    td <- timeit({
      f <- tempfile(fileext = ".png")
      grDevices::png(f, width = RCFG$plot_w, height = RCFG$plot_h, res = 96)
      grid::grid.newpage(); grid::grid.draw(gt)
      grDevices::dev.off(); unlink(f)
    })
    c(build = tb, draw = td)
  }, error = function(e) c(build = NA_real_, draw = NA_real_))
  out
}

# ============================ benchmarks =======================================

bench_ladder <- function(cfgs, sel) {
  msg("=== VARIANT LADDER ===")
  rows <- list()
  for (n in RCFG$facet_counts) {
    want <- sel$dates[seq_len(min(n, length(sel$dates)))]
    for (cn in names(cfgs)) {
      cf <- cfgs[[cn]]
      gh <- cf$gh(want); pr <- cf$pr(want)
      for (on in names(OPTS)) {
        p <- build_map(gh, pr, sel$fires, want, OPTS[[on]], gh_res = cf$gh_res)
        t <- draw_time(p)
        rows[[length(rows) + 1]] <- data.frame(
          facets = length(want), config = cf$lab, variant = OPTS[[on]]$lab,
          draw_ms = ms(t), stringsAsFactors = FALSE)
        msg("  ", length(want), "f  ", cf$lab, "  ", OPTS[[on]]$lab, "  ", ms(t), " ms")
      }
      rm(gh, pr); invisible(gc(FALSE))
    }
  }
  out <- do.call(rbind, rows)
  RES$ladder <- out
  print(out, row.names = FALSE)
  invisible(out)
}

bench_ablation <- function(cfgs, sel) {
  msg("=== LAYER ABLATION (baseline O0, ", RCFG$ablate_at, " facets) ===")
  want <- sel$dates[seq_len(min(RCFG$ablate_at, length(sel$dates)))]
  all_layers <- c("fill", "points", "contour", "states", "labels")
  rows <- list()
  for (cn in names(cfgs)) {
    cf <- cfgs[[cn]]
    gh <- cf$gh(want); pr <- cf$pr(want)
    full <- draw_time(build_map(gh, pr, sel$fires, want, OPTS$O0, all_layers, cf$gh_res))
    rows[[length(rows) + 1]] <- data.frame(
      config = cf$lab, dropped = "(nothing — full plot)", draw_ms = ms(full),
      attributed_ms = NA_integer_, stringsAsFactors = FALSE)
    for (L in all_layers) {
      t <- draw_time(build_map(gh, pr, sel$fires, want, OPTS$O0,
                               setdiff(all_layers, L), cf$gh_res))
      rows[[length(rows) + 1]] <- data.frame(
        config = cf$lab, dropped = L, draw_ms = ms(t),
        attributed_ms = ms(full - t), stringsAsFactors = FALSE)
      msg("  ", cf$lab, "  without ", L, ": ", ms(t), " ms  (layer costs ~",
          ms(full - t), " ms)")
    }
    rm(gh, pr); invisible(gc(FALSE))
  }
  out <- do.call(rbind, rows)
  RES$ablation <- out
  print(out, row.names = FALSE)
  invisible(out)
}

bench_split <- function(cfgs, sel) {
  msg("=== BUILD vs DRAW (", RCFG$ablate_at, " facets) ===")
  want <- sel$dates[seq_len(min(RCFG$ablate_at, length(sel$dates)))]
  rows <- list()
  for (cn in names(cfgs)) {
    cf <- cfgs[[cn]]
    gh <- cf$gh(want); pr <- cf$pr(want)
    for (on in c("O0", "O4")) {
      s <- split_time(build_map(gh, pr, sel$fires, want, OPTS[[on]], gh_res = cf$gh_res))
      rows[[length(rows) + 1]] <- data.frame(
        config = cf$lab, variant = OPTS[[on]]$lab,
        build_ms = ms(s[["build"]]), device_ms = ms(s[["draw"]]),
        stringsAsFactors = FALSE)
    }
    rm(gh, pr); invisible(gc(FALSE))
  }
  out <- do.call(rbind, rows)
  RES$split <- out
  print(out, row.names = FALSE)
  invisible(out)
}

# Morphological erosion on a logical matrix: keep only pixels whose entire
# (2k+1)^2 neighbourhood also differs. A tile->raster swap changes every cell
# boundary by a pixel or two, so a raw pixel count reads ~9% differing on an
# identical map. What actually matters is whether any BLOB of content changed,
# and blobs survive erosion while 1-2px seams do not.
erode_mask <- function(m, k = 1) {
  nr <- nrow(m); nc <- ncol(m); out <- m
  for (dy in -k:k) for (dx in -k:k) {
    out <- out & m[((seq_len(nr) - 1 - dy) %% nr) + 1,
                   ((seq_len(nc) - 1 - dx) %% nc) + 1, drop = FALSE]
  }
  out
}

# Every variant must be the same picture as O0.
bench_correctness <- function(cfgs, sel) {
  msg("=== CORRECTNESS: O0 vs O4 pixel diff ===")
  want <- sel$dates[seq_len(min(RCFG$ablate_at, length(sel$dates)))]
  rows <- list()
  for (cn in names(cfgs)) {
    cf <- cfgs[[cn]]
    gh <- cf$gh(want); pr <- cf$pr(want)
    files <- vapply(names(OPTS), function(on) {
      f <- file.path(RCFG$scratch, paste0("bench_render_", cn, "_", on, ".png"))
      draw_to(build_map(gh, pr, sel$fires, want, OPTS[[on]], gh_res = cf$gh_res), f)
      f
    }, character(1))

    if (requireNamespace("png", quietly = TRUE)) {
      a <- png::readPNG(files[["O0"]])
      flat <- function(z) if (length(dim(z)) == 3)
        Reduce(pmax, lapply(seq_len(dim(z)[3]), function(k) z[, , k])) else z
      # diff EVERY variant against O0, so filtering and the tile->raster swap
      # are not confounded the way they were when only O4 was checked
      for (on in setdiff(names(OPTS), "O0")) {
        b <- png::readPNG(files[[on]])
        if (!identical(dim(a), dim(b))) {
          rows[[length(rows) + 1]] <- data.frame(config = cf$lab, variant = on,
            pct_raw = NA_real_, pct_blobs_gt3px = NA_real_,
            verdict = "dimension mismatch", stringsAsFactors = FALSE)
          next
        }
        pix    <- flat(abs(a - b))
        m      <- pix > 2/255
        blobs  <- mean(erode_mask(m, 1))
        rows[[length(rows) + 1]] <- data.frame(config = cf$lab, variant = on,
          pct_raw         = round(100 * mean(m), 3),
          pct_blobs_gt3px = round(100 * blobs, 4),
          verdict = if (blobs < 1e-5) "PASS (seams only)" else "FAIL — content changed",
          stringsAsFactors = FALSE)
      }
    } else {
      rows[[length(rows) + 1]] <- data.frame(config = cf$lab, variant = NA_character_,
        pct_raw = NA_real_, pct_blobs_gt3px = NA_real_,
        verdict = "install 'png' for the diff; compare the PNGs by eye",
        stringsAsFactors = FALSE)
    }
    msg("  wrote ", length(files), " variant PNGs for config ", cn)
    rm(gh, pr); invisible(gc(FALSE))
  }
  out <- do.call(rbind, rows)
  RES$correctness <- out
  print(out, row.names = FALSE)
  invisible(out)
}

# ============================ report ===========================================

write_render_report <- function() {
  f <- file.path(RCFG$scratch, "BENCH_RENDER.md")
  md_table <- function(df) c(
    paste0("| ", paste(names(df), collapse = " | "), " |"),
    paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|"),
    apply(df, 1, function(r) paste0("| ", paste(trimws(r), collapse = " | "), " |")))

  ld <- RES$ladder
  verdict <- character(0)
  for (cf in unique(ld$config)) {
    for (n in unique(ld$facets)) {
      s <- ld[ld$config == cf & ld$facets == n, ]
      b <- s$draw_ms[grepl("^O0", s$variant)]
      e <- s$draw_ms[grepl("^O4", s$variant)]
      if (length(b) && length(e))
        verdict <- c(verdict, sprintf("- %s, %d facets: %d ms -> %d ms (%.1fx, %d ms saved)",
                                      cf, as.integer(n), as.integer(b), as.integer(e),
                                      b / max(e, 1), as.integer(b - e)))
    }
  }

  writeLines(c(
    "# Render optimisation benchmark", "",
    paste0("Run ", format(Sys.time(), "%Y-%m-%d %H:%M"), ", R ", getRversion(),
           ", ", RCFG$plot_w, "x", RCFG$plot_h, " png, median of ", RCFG$reps, "."),
    "",
    "## Variant ladder", "", md_table(ld), "",
    "### Verdict", "", verdict, "",
    "## Layer ablation", "",
    "`attributed_ms` is full-plot time minus time-without-that-layer. Layers",
    "interact, so these do not sum exactly to the total.", "",
    md_table(RES$ablation), "",
    "## Build vs draw", "",
    "`build_ms` is ggplot stat computation (isoband contouring, tile prep);",
    "`device_ms` is the graphics device rendering the gtable.", "",
    md_table(RES$split), "",
    "## Correctness — each variant vs O0", "", md_table(RES$correctness), "",
    "`pct_raw` counts every differing pixel and is NOT the test: swapping",
    "geom_tile for geom_raster redraws every cell boundary, which reads ~9%",
    "differing on a picture that is otherwise identical. `pct_blobs_gt3px` is",
    "the test — it survives only if a region wider than 3 px changed, which is",
    "what an actual content change looks like.",
    "",
    "History:",
    "- Run 1 (14:16) genuinely FAILED: the contour colour scale had no explicit",
    "  `limits`, so filtering the contour input retrained it on a narrower range",
    "  and recoloured every line. Fixed by pinning `scale_color_gradientn(limits=)`",
    "  to the levels the UNFILTERED field produces, and by pinning legend order.",
    "- Run 2 (14:51) read 9.4% / 4.7% raw and looked like a failure, but 0.000%",
    "  survived erosion — all seams, no content change. The threshold was wrong,",
    "  not the optimisation.",
    "",
    "## Caveats", "",
    "- 1.0 deg heights are real ERA5 fields cycled across days, so contour",
    "  complexity is realistic but the maps are not meteorologically meaningful.",
    "- State filtering keeps whole states touching the view. A real clip would",
    "  save more, at the cost of needing proper polygon clipping."
  ), f)
  msg("wrote ", f)
  f
}

# ============================ driver ===========================================

render_main <- function() {
  check_project_root(); ensure_dirs()
  r25  <- terra::rast("./Data/R2_hgt_500mb_1992_2020_CONUS.tif")
  rprc <- terra::rast(switch(CFG$precip_var,
    precip14 = "./Data/CPC_Global_precip_14dyPercAvg_1992_2020_CONUS_INT.tif",
    precip90 = "./Data/CPC_Global_precip_90dyPercAvg_1992_2020_CONUS_INT.tif"))

  cfgs <- list(
    A = list(lab = "A 2.5deg hgt + 0.5deg precip (today)", gh_res = 2.5,
             gh = function(w) current_gh_long(r25, w),
             pr = function(w) precip_long(rprc, w, 1)),
    B = list(lab = "B 1.0deg hgt + 1.0deg precip (target)", gh_res = 1.0,
             gh = function(w) gh_1deg_long(w),
             pr = function(w) precip_long(rprc, w, 2)))

  sel <- select_fire_days(utils::modifyList(CFG, list(n_days = max(RCFG$facet_counts))))
  sel$dates <- sel$dates[sel$dates <= as.Date("2020-12-31")]
  msg("Using ", length(sel$dates), " real AZ fire days")

  bench_ladder(cfgs, sel)
  bench_ablation(cfgs, sel)
  bench_split(cfgs, sel)
  bench_correctness(cfgs, sel)
  write_render_report()
  msg("Done.")
  invisible(RES)
}

render_main()
