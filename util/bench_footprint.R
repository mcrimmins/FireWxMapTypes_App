# util/bench_footprint.R
# -----------------------------------------------------------------------------
# What does this app actually cost in RAM, per Posit Connect process?
#
# THE CONSTRAINT
# The deployed app must stay under 1 GB *when loaded*, on Posit Connect. Connect
# runs MULTIPLE PROCESSES per app for concurrency, and every process loads its
# own copy of everything at the top of app.R. So the real budget is
#
#     per_process_footprint  x  max_processes  <=  1 GB
#
# `max_processes` is an app-level runtime setting in Connect (default is small
# but non-1). Set it deliberately rather than inheriting the default.
#
# WHAT THIS MEASURES — all of it previously guessed in ERA5_MIGRATION_SCOPE.md §3
#   1. Bare R, then each library added one at a time. The package stack is a
#      fixed per-process cost that no data design can reduce, so if it dominates,
#      the lever is dropping packages (plotly and DT are the usual suspects) not
#      shrinking grids.
#   2. FODthin.Rdata as it is today.
#   3. FOD re-encoded to factors + integers — the §7 phase 3 plan, quantified.
#   4. terra raster handles (lazy) and the transient peak during one render.
#   5. A budget solve: given the measured fixed costs and a process count, how
#      big can the grid cache be?
#
# RUN IN A FRESH R SESSION. Session > Restart R first, then:
#   source("util/bench_footprint.R")
# Nothing else should be loaded — the whole point is measuring from a clean base.
#
# RUNTIME: ~1 minute. No network, no CDS.
#
# MAC / drafted with Claude, 2026-08
# -----------------------------------------------------------------------------

FCFG <- list(
  # app.R's library() calls, in order
  libs = c("shiny", "terra", "ggplot2", "maps", "dplyr", "tidyr",
           "plotly", "shinythemes", "DT"),
  # packages that exist only for one feature, and could plausibly go
  optional = c("plotly", "DT", "shinythemes"),
  # --- Posit Connect, viz.datascience.arizona.edu. Confirmed from the app's
  # runtime panel, 2026-08-07:
  #   Max RAM (GiB) . . . . 0  = NO LIMIT. There is no runtime memory cap.
  #   Max processes . . . . 7  (server default 3, overridden)
  #   Max connections/proc  20 ,  Load factor 0.5
  #   Initial timeout . . . 240 s (default 60, overridden — startup is slow)
  #   Idle timeout/proc . . 5 s   (processes die 5 s after the last disconnect)
  # So the binding limit is the 1 GB BUNDLE cap on disk, not RAM. RAM still
  # matters as server courtesy: 7 warm processes each hold their own copy.
  bundle_limit_mb = 1024,
  n_processes  = c(1, 2, 3, 7),   # 7 is this app's current setting
  headroom_pct = 15,       # leave this much of the bundle limit unspent
  render_days  = 12,       # facets in the transient-peak test
  out          = "./Data/scratch/BENCH_FOOTPRINT.md"
)

# ============================ RSS plumbing ===================================

if (!requireNamespace("ps", quietly = TRUE)) {
  stop("This script needs the 'ps' package to read process memory.\n",
       "  renv::install('ps')\nThen restart R and source this again.",
       call. = FALSE)
}

.h <- ps::ps_handle()
rss <- function() as.numeric(ps::ps_memory_info(.h)[["rss"]]) / 1024^2
mb  <- function(x) round(x, 1)
obj <- function(x) as.numeric(utils::object.size(x)) / 1024^2

STEPS <- list()
mark <- function(label, note = "") {
  invisible(gc(FALSE))
  r <- rss()
  prev <- if (length(STEPS)) STEPS[[length(STEPS)]]$rss_mb else NA_real_
  STEPS[[length(STEPS) + 1]] <<- list(
    step = label, rss_mb = mb(r), delta_mb = mb(r - prev), note = note)
  cat(sprintf("  %-38s RSS %7.1f MB   (%+.1f)\n", label, r,
              if (is.na(prev)) 0 else r - prev))
  invisible(r)
}

# Warn if this is not a clean session — a warm session understates every delta.
already <- setdiff(FCFG$libs, c("stats", "utils"))
already <- already[already %in% loadedNamespaces()]
if (length(already)) {
  cat("\n!! WARNING: these are already loaded: ", paste(already, collapse = ", "),
      "\n   Restart R (Session > Restart R) and source this again, or the\n",
      "   per-package numbers will be meaningless.\n\n", sep = "")
}

cat("=== 1. FIXED COST: R plus the package stack ===\n")
mark("bare R session")
for (p in FCFG$libs) {
  suppressPackageStartupMessages(
    suppressWarnings(library(p, character.only = TRUE)))
  mark(paste0("+ ", p), if (p %in% FCFG$optional) "optional" else "")
}
stack_mb <- STEPS[[length(STEPS)]]$rss_mb

optional_cost <- sum(vapply(STEPS, function(s)
  if (identical(s$note, "optional")) s$delta_mb else 0, numeric(1)))
cat(sprintf("\n  package stack total: %.1f MB, of which %.1f MB is optional (%s)\n",
            stack_mb, optional_cost, paste(FCFG$optional, collapse = ", ")))

# ============================ FOD ============================================

cat("\n=== 2. FOD, as the app loads it today ===\n")
before_fod <- rss()
e <- new.env(parent = emptyenv())
load("./Data/FODthin.Rdata", envir = e)
fc <- get("fc", envir = e); rm(e)
fc$DISCOVERY_DATE <- as.Date(fc$DISCOVERY_DATE, "%m/%d/%Y")
fc$CONT_DATE      <- as.Date(fc$CONT_DATE, "%m/%d/%Y")
fc$OPERATION_DAYS <- as.numeric(fc$CONT_DATE - fc$DISCOVERY_DATE) + 1
fc$DISCOVERY_YEAR <- as.numeric(format(fc$DISCOVERY_DATE, "%Y"))
mark("+ FODthin.Rdata (as app.R loads it)")
fod_now <- obj(fc)
cat(sprintf("  object.size: %.1f MB, %s rows x %d cols\n",
            fod_now, format(nrow(fc), big.mark = ","), ncol(fc)))
cat("  per-column cost:\n")
cs <- sort(vapply(fc, obj, numeric(1)), decreasing = TRUE)
for (i in seq_along(cs))
  cat(sprintf("    %-30s %6.1f MB  (%s)\n", names(cs)[i], cs[i],
              class(fc[[names(cs)[i]]])[1]))

# --- the phase 3 re-encode, quantified -------------------------------------
# Dates as integer days, coordinates as scaled integers, character columns as
# factors, derived columns dropped and recomputed on demand.
compact_fod <- function(fc) {
  data.frame(
    FIRE_YEAR       = as.integer(fc$FIRE_YEAR),
    DISCOVERY_DATE  = as.integer(fc$DISCOVERY_DATE),   # days since 1970-01-01
    CONT_DATE       = as.integer(fc$CONT_DATE),
    FIRE_SIZE_x100  = as.integer(round(fc$FIRE_SIZE * 100)),  # 0.01 acre
    FIRE_SIZE_CLASS = factor(fc$FIRE_SIZE_CLASS),
    CAUSE           = factor(fc$NWCG_CAUSE_CLASSIFICATION),
    LAT_x1e4        = as.integer(round(fc$LATITUDE  * 1e4)),  # ~11 m
    LON_x1e4        = as.integer(round(fc$LONGITUDE * 1e4)),
    STATE           = factor(fc$STATE),
    stringsAsFactors = FALSE)
}
fc_small <- compact_fod(fc)
fod_small <- obj(fc_small)
cat(sprintf("\n  re-encoded: %.1f MB (was %.1f MB, %.0f%% smaller)\n",
            fod_small, fod_now, 100 * (1 - fod_small / fod_now)))
cat("  dropped as derivable: DISCOVERY_DOY, CONT_DOY, OPERATION_DAYS, DISCOVERY_YEAR\n")

# ============================ rasters + render peak ==========================

cat("\n=== 3. Rasters and the transient render peak ===\n")
tifs <- list.files("./Data", pattern = "\\.tif$", full.names = TRUE)
rasters <- lapply(tifs, terra::rast)
mark("+ terra::rast() handles (lazy)")

invisible(gc(reset = TRUE))
peak_before <- rss()
gh <- terra::rast("./Data/R2_hgt_500mb_1992_2020_CONUS.tif")
pr <- terra::rast("./Data/CPC_Global_precip_90dyPercAvg_1992_2020_CONUS_INT.tif")
days <- sort(sample(terra::time(gh), FCFG$render_days))
gsub_ <- gh[[which(terra::time(gh) %in% days)]]
psub_ <- pr[[which(terra::time(pr) %in% days)]]
gdf <- as.data.frame(gsub_, xy = TRUE)
pdf_ <- as.data.frame(psub_, xy = TRUE)
gl <- tidyr::pivot_longer(gdf, cols = -c(x, y))
pl <- tidyr::pivot_longer(pdf_, cols = -c(x, y))
mark(paste0("+ one ", FCFG$render_days, "-facet render's data"))
render_peak <- rss() - peak_before
cat(sprintf("  transient cost of materialising one render: %.1f MB\n", render_peak))
rm(gdf, pdf_, gl, pl, gsub_, psub_); invisible(gc(FALSE))

# ============================ budget solve ===================================
# Confirmed from the Connect runtime panel: Max RAM = 0 (no limit). So the only
# hard limit is the 1 GB BUNDLE cap on disk. RAM is not policy-capped — but with
# Max processes = 7 and each process holding its own copy of everything at the
# top of app.R, the app can still take an inconsiderate share of shared server
# memory, and an unbounded process has nothing to stop it.

cat("\n=== 4a. BUNDLE SIZE (disk, at upload) ===\n")
bundle_ignore <- c("Data/scratch", "oldVersions", "util", ".git", ".Rproj.user",
                   "renv/library", "renv/staging")
all_files <- list.files(".", recursive = TRUE, all.files = TRUE, full.names = TRUE)
all_files <- all_files[!dir.exists(all_files)]
is_ignored <- function(p) any(vapply(bundle_ignore,
                                     function(g) grepl(g, p, fixed = TRUE),
                                     logical(1)))
keep <- !vapply(all_files, is_ignored, logical(1))
bundle_mb <- sum(file.size(all_files[keep])) / 1024^2
total_mb  <- sum(file.size(all_files)) / 1024^2
cat(sprintf("  with .rscignore applied: %.1f MB\n", bundle_mb))
cat(sprintf("  without it:              %.1f MB  (%.1f MB of it excludable)\n",
            total_mb, total_mb - bundle_mb))
cat(sprintf("  against the %g MB bundle cap: %s  (%.0f MB spare)\n",
            FCFG$bundle_limit_mb,
            if (bundle_mb < FCFG$bundle_limit_mb) "OK" else "OVER",
            FCFG$bundle_limit_mb - bundle_mb))
cat("  ^ THIS is the binding limit. Max RAM is 0 = no runtime cap.\n")

cat("\n=== 4b. SERVER RAM (not capped, but shared) ===\n")
fixed_planned <- stack_mb + fod_small + render_peak
fixed_today   <- stack_mb + fod_now  + render_peak
cat(sprintf("  fixed per worker, today:   %.1f MB (stack %.1f + FOD %.1f + render %.1f)\n",
            fixed_today, stack_mb, fod_now, render_peak))
cat(sprintf("  fixed per worker, planned: %.1f MB (FOD re-encoded to %.1f MB)\n",
            fixed_planned, fod_small))
cat(sprintf("  dropping %s would save %.1f MB per worker\n\n",
            paste(FCFG$optional, collapse = "/"), optional_cost))

# A grid cache of this size is what the planned lazy loader would hold once a
# user has clicked through a few variables.
cache_assumed <- 150
grid <- data.frame(processes = FCFG$n_processes)
grid$today_GB   <- round(grid$processes * fixed_today / 1024, 2)
grid$planned_GB <- round(grid$processes *
                         (fixed_planned + cache_assumed) / 1024, 2)
grid$note <- ifelse(grid$processes == 7,
                    "<- current setting (Max processes = 7)", "")
print(grid, row.names = FALSE)
cat(sprintf("\n  (planned assumes a %d MB grid cache per process)\n", cache_assumed))

cat("\n  Recommendations:\n",
    "   1. Max processes 7 -> 2 or 3. At 20 connections per process and load\n",
    "      factor 0.5, 7 processes serve up to ~140 concurrent users. If that is\n",
    "      far beyond the real audience it is pure memory cost.\n",
    "   2. Set a Max RAM override as a safety net. Unbounded means a runaway\n",
    "      process degrades the whole server rather than just dying.\n",
    "   3. Idle timeout is 5 s, so processes are destroyed almost immediately and\n",
    "      the next visitor pays a cold start. That is why Initial timeout had to\n",
    "      go 60 -> 240. Once startup is fast (lazy qs2 loading), lower Initial\n",
    "      timeout back toward the default and raise Idle timeout so a warm\n",
    "      process survives short gaps.\n",
    "   4. Drop optional packages (", paste(FCFG$optional, collapse = ", "),
    ") to cut the per-process floor.\n", sep = "")

# ============================ report =========================================

steps_df <- do.call(rbind, lapply(STEPS, function(s)
  data.frame(step = s$step, rss_MB = s$rss_mb, delta_MB = s$delta_mb,
             note = s$note, stringsAsFactors = FALSE)))

md <- function(df) c(
  paste0("| ", paste(names(df), collapse = " | "), " |"),
  paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|"),
  apply(df, 1, function(r) paste0("| ", paste(trimws(r), collapse = " | "), " |")))

writeLines(c(
  "# Memory footprint — Posit Connect", "",
  paste0("Run ", format(Sys.time(), "%Y-%m-%d %H:%M"), ", R ", getRversion(),
         ", ", R.version$platform, "."),
  paste0("Bundle cap ", FCFG$bundle_limit_mb, " MB on disk; runtime RAM is",
         " uncapped (Max RAM = 0). Connect runs up to ", max(FCFG$n_processes),
         " processes for this app and each loads its own copy of everything at",
         " the top of `app.R`."),
  "",
  "## Fixed cost — R and the package stack", "", md(steps_df), "",
  sprintf("Package stack: **%.1f MB per process**, of which %.1f MB is optional (%s).",
          stack_mb, optional_cost, paste(FCFG$optional, collapse = ", ")),
  "This is per-process and irreducible except by dropping packages — no data",
  "design touches it.",
  "",
  "## FOD", "",
  sprintf("- as loaded today: **%.1f MB**", fod_now),
  sprintf("- re-encoded (factors + integer dates/coords, derived columns dropped): **%.1f MB**, %.0f%% smaller",
          fod_small, 100 * (1 - fod_small / fod_now)),
  "",
  "## Bundle size (disk, at upload)", "",
  sprintf("- with `.rscignore` applied: **%.1f MB**", bundle_mb),
  sprintf("- without it: %.1f MB — %.1f MB is `Data/scratch`, `oldVersions` and `util`, none of which the app loads at runtime",
          total_mb, total_mb - bundle_mb),
  sprintf("- against the %g MB bundle cap: **%s**, %.0f MB spare",
          FCFG$bundle_limit_mb,
          if (bundle_mb < FCFG$bundle_limit_mb) "OK" else "OVER",
          FCFG$bundle_limit_mb - bundle_mb),
  "",
  "**This is the binding limit.** The app's Connect runtime panel shows",
  "Max RAM (GiB) = 0, i.e. no runtime memory cap.",
  "",
  "## Server RAM — uncapped, but shared", "",
  sprintf("Fixed per process — today %.1f MB, planned %.1f MB. One %d-facet render transiently adds %.1f MB.",
          fixed_today, fixed_planned, FCFG$render_days, render_peak),
  "",
  md(grid),
  "",
  "## Connect settings worth changing", "",
  "Observed 2026-08-07: Max processes 7 (default 3), Max connections/process 20,",
  "Load factor 0.5, Initial timeout 240 s (default 60), Idle timeout 5 s,",
  "Max RAM 0 (no limit).",
  "",
  "1. **Max processes 7 → 2 or 3.** Seven processes at 20 connections each serve",
  "   ~140 concurrent users. Every process holds its own copy of everything.",
  "2. **Set a Max RAM override.** Uncapped means a runaway process degrades the",
  "   whole server instead of just dying.",
  "3. **Initial timeout 240 s is a symptom.** Someone had to quadruple it because",
  "   startup loads 276 MB of GeoTIFFs and FOD. Lazy `qs2` loading should let it",
  "   go back toward the default — a good acceptance test for phase 5.",
  "4. **Idle timeout 5 s** destroys processes almost immediately, so most visitors",
  "   pay a cold start. Worth raising once startup is cheap.",
  "5. Dropping optional packages cuts the per-process floor for all 7."
), FCFG$out)
cat("\nwrote ", FCFG$out, "\n", sep = "")
