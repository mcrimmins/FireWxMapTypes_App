#!/usr/bin/env Rscript
# build/selftest.R
# -----------------------------------------------------------------------------
# Fast pre-flight for the build server. ~30 seconds, no CDS retrieval.
#
#   Rscript build/selftest.R           # everything except a real CDS download
#   Rscript build/selftest.R --cds     # + one tiny real retrieval (~1 min)
#
# WHY THIS EXISTS
# `run_phase1.R --dry-run` proves the plan is constructible. It does not touch
# CDS auth, the keyring, ntfy, libnetcdf or the disk — and those are exactly the
# things that differ between the laptop where this was written and a headless
# Ubuntu box. The alternative was finding out from a 36-minute smoke test, or
# worse, at hour 14 of the real run.
#
# Every check prints PASS / WARN / FAIL. Any FAIL exits 1.
# -----------------------------------------------------------------------------

options(warn = 1)
n_fail <- 0L; n_warn <- 0L

ok   <- function(what, detail = "") cat(sprintf("  \033[32mPASS\033[0m  %-34s %s\n", what, detail))
warn <- function(what, detail = "") { n_warn <<- n_warn + 1L
  cat(sprintf("  \033[33mWARN\033[0m  %-34s %s\n", what, detail)) }
bad  <- function(what, detail = "") { n_fail <<- n_fail + 1L
  cat(sprintf("  \033[31mFAIL\033[0m  %-34s %s\n", what, detail)) }
sect <- function(x) cat(sprintf("\n\033[1m%s\033[0m\n", x))

args <- commandArgs(trailingOnly = TRUE)
do_cds <- "--cds" %in% args

cat("FireWx build server self-test\n")
cat(sprintf("%s | R %s | %s\n", Sys.info()[["nodename"]], getRversion(),
            format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")))

# --- 1. location -------------------------------------------------------------
sect("1. Project")
if (!file.exists("util/era5_common.R")) {
  bad("working directory", normalizePath(".", mustWork = FALSE))
  cat("\nRun from the repo root. Nothing else can be checked.\n"); quit(status = 1L)
}
ok("working directory", normalizePath(".", mustWork = FALSE))
source("util/era5_common.R")
ok("util/era5_common.R sourced", "helpers available")

# --- 2. environment ----------------------------------------------------------
sect("2. Environment (.Renviron)")
# R reads .Renviron from the working directory AT STARTUP. If these are empty
# but the file exists, R was started somewhere else — the single most common
# way this setup fails silently.
if (!file.exists(".Renviron")) bad(".Renviron", "not found in repo root")
key <- Sys.getenv("CDS_KEY")
if (nzchar(key)) ok("CDS_KEY", sprintf("%d chars", nchar(key)))
else bad("CDS_KEY", "empty — is R being started from the repo root?")

if (ntfy_enabled()) ok("NTFY_TOPIC", sprintf("set (%d chars)", nchar(Sys.getenv("NTFY_TOPIC"))))
else warn("NTFY_TOPIC", "unset — notifications will be silent no-ops")

prof <- Sys.getenv("RENV_PROFILE")
if (identical(prof, "build")) ok("RENV_PROFILE", "build")
else warn("RENV_PROFILE", sprintf("'%s' — expected 'build' on the server", prof))

lp <- .libPaths()[1]
if (grepl("profiles/build", lp, fixed = TRUE)) ok("active library", lp)
else warn("active library", lp)

# --- 3. packages -------------------------------------------------------------
sect("3. R packages")
want <- c(ecmwfr = "2.0.0", ncdf4 = "0", xml2 = "0", qs2 = "0", terra = "0", httr = "0")
for (p in names(want)) {
  if (!requireNamespace(p, quietly = TRUE)) {
    bad(p, "not installed — run build/bootstrap.R")
  } else {
    v <- as.character(utils::packageVersion(p))
    if (utils::packageVersion(p) < want[[p]])
      warn(p, sprintf("%s (expected >= %s)", v, want[[p]]))
    else ok(p, v)
  }
}
# xml2 gets its own line because its absence does not look like its absence: a
# CDS rejection surfaces as "Please install xml2 package" instead of the reason.
if (!requireNamespace("xml2", quietly = TRUE))
  cat("        ^ without xml2, CDS errors are misreported as an xml2 problem\n")

# --- 4. netCDF round trip ----------------------------------------------------
sect("4. netCDF (libnetcdf)")
if (requireNamespace("ncdf4", quietly = TRUE)) {
  tf <- tempfile(fileext = ".nc")
  res <- tryCatch({
    d  <- ncdf4::ncdim_def("x", "", 1:4)
    nc <- ncdf4::nc_create(tf, ncdf4::ncvar_def("v", "", d, prec = "double"))
    ncdf4::ncvar_put(nc, "v", c(1, 2, 3, 4)); ncdf4::nc_close(nc)
    nc <- ncdf4::nc_open(tf); on.exit(ncdf4::nc_close(nc), add = TRUE)
    identical(as.numeric(ncdf4::ncvar_get(nc, "v")), c(1, 2, 3, 4))
  }, error = function(e) e)
  if (isTRUE(res)) ok("write + read round trip", "libnetcdf working")
  else bad("write + read round trip",
           if (inherits(res, "error")) conditionMessage(res) else "value mismatch")
  unlink(tf)
} else bad("ncdf4", "not installed")

# --- 5. disk and paths -------------------------------------------------------
sect("5. Disk")
raw <- "./Data/era5_raw"
dir.create(file.path(raw, "daily"), recursive = TRUE, showWarnings = FALSE)
tf <- file.path(raw, ".selftest_write")
if (isTRUE(tryCatch({ writeLines("x", tf); file.exists(tf) }, error = function(e) FALSE))) {
  ok("Data/era5_raw writable"); unlink(tf)
} else bad("Data/era5_raw writable", "check permissions")

df <- tryCatch(system2("df", c("-Pk", shQuote(normalizePath(raw, mustWork = FALSE))),
                       stdout = TRUE), error = function(e) NULL)
if (length(df) >= 2) {
  free_gb <- as.numeric(strsplit(trimws(df[2]), "\\s+")[[1]][4]) / 1024^2
  # ~6.9 GB of hourly netCDF + ~2 GB of daily .rds, both resident at peak.
  if (free_gb >= 15) ok("free space", sprintf("%.1f GB (need ~9 GB)", free_gb))
  else if (free_gb >= 9) warn("free space", sprintf("%.1f GB — enough, no margin", free_gb))
  else bad("free space", sprintf("%.1f GB — need ~9 GB at peak", free_gb))
} else warn("free space", "could not run df")

mem <- tryCatch(as.numeric(sub(".*: *", "",
  grep("^MemTotal", readLines("/proc/meminfo", warn = FALSE), value = TRUE))) / 1024^2,
  error = function(e) NA_real_)
if (!is.na(mem)) {
  # Aggregation holds all years of a variable's daily matrices before writing:
  # ~320 MB per statistic, gust carries two. Peak ~1.5-2 GB.
  if (mem >= 7) ok("RAM", sprintf("%.1f GB", mem))
  else warn("RAM", sprintf("%.1f GB — add swap; peak is ~2 GB", mem))
}

# --- 6. timezone assumption --------------------------------------------------
sect("6. Timezone (D9, MST = constant UTC-7)")
# Asserts the actual claim: because read_nc_cells() builds its origin with
# tz="UTC", as.Date() cannot pick up the machine's locale. R 4.3 changed
# as.Date.POSIXct() to use the object's own zone, so this is worth proving on
# the machine rather than assuming.
t_utc <- as.POSIXct("2020-07-15 06:00:00", tz = "UTC")   # 23:00 MST on the 14th
got   <- as.Date(t_utc + (-7) * 3600)
if (identical(got, as.Date("2020-07-14")))
  ok("MST day boundary", "06Z -> local 14 Jul, TZ-independent")
else bad("MST day boundary", sprintf("got %s, expected 2020-07-14", got))
ok("system timezone", Sys.timezone() %||% "unset")

# --- 7. ntfy -----------------------------------------------------------------
sect("7. Push notifications (ntfy)")
if (!ntfy_enabled()) {
  warn("delivery", "skipped — NTFY_TOPIC unset")
} else {
  cat(sprintf("        server: %s\n", Sys.getenv("NTFY_SERVER", "https://ntfy.sh")))
  sent <- notify(sprintf(
    "Self-test from %s at %s.\nIf you are reading this on your phone, the whole notification path works: progress, failure alerts and the systemd OnFailure hook all use it.",
    Sys.info()[["nodename"]], format(Sys.time(), "%H:%M:%S")),
    title = "FireWx self-test", priority = "default", tags = "test_tube")
  if (isTRUE(sent)) ok("delivery", "HTTP accepted — CHECK YOUR PHONE")
  else bad("delivery", "POST failed — check NTFY_TOPIC / network / curl")
}
# The systemd OnFailure notifier reads .Renviron with grep, not R. Verify the
# lines it needs are in a shape `grep | tr -d ' '` can parse.
if (file.exists(".Renviron")) {
  rl <- readLines(".Renviron", warn = FALSE)
  if (any(grepl("^\\s*NTFY_TOPIC\\s*=", rl))) ok("OnFailure unit can read topic")
  else if (ntfy_enabled())
    warn("OnFailure unit can read topic",
         "NTFY_TOPIC not literally in .Renviron — the systemd notifier will be silent")
}

# --- 8. CDS ------------------------------------------------------------------
sect("8. Copernicus CDS")
if (n_fail > 0) {
  warn("CDS checks", "skipped — fix the failures above first")
} else {
  ERA5_BUILD_RUN_ON_SOURCE <- FALSE
  loaded <- tryCatch({ source("util/build_era5.R"); TRUE }, error = function(e) e)
  if (!isTRUE(loaded)) {
    bad("source util/build_era5.R", conditionMessage(loaded))
  } else {
    ok("util/build_era5.R sourced", sprintf("%d jobs planned", length(build_jobs())))

    # THE HANG RISK. ecmwfr 2.x stores the token via keyring; headless Linux has
    # no Secret Service, and keyring's file backend blocks on an interactive
    # password prompt — under systemd that is an unattended run stuck forever at
    # second zero with no output. setup_cds() selects the "env" backend, and a
    # time limit here turns a hang into a reportable failure.
    r <- tryCatch({
      setTimeLimit(elapsed = 60, transient = TRUE)
      on.exit(setTimeLimit(elapsed = Inf), add = TRUE)
      setup_cds(); TRUE
    }, error = function(e) e)
    if (isTRUE(r)) {
      ok("setup_cds()", sprintf("keyring backend: %s",
                                getOption("keyring_backend") %||% "default"))
    } else {
      m <- conditionMessage(r)
      bad("setup_cds()", m)
      if (grepl("time limit|elapsed", m, ignore.case = TRUE))
        cat("        ^ it HUNG. That is the keyring prompt. Set in .Renviron:\n",
            "          R_KEYRING_BACKEND=env\n", sep = "")
    }

    if (isTRUE(tryCatch(preflight(), error = function(e) FALSE)))
      ok("CDS reachable + token accepted")
    else bad("CDS preflight", "see the output above")

    if (do_cds) {
      # One hour, one variable, four grid cells. Seconds of MARS time. This is
      # the only check that proves licence acceptance, which the HTTP preflight
      # cannot see.
      cat("        submitting one tiny retrieval ...\n")
      p <- file.path(BCFG$raw_dir, "selftest.nc")
      unlink(p)
      rr <- tryCatch(ecmwfr::wf_request(request = list(
          dataset_short_name = "reanalysis-era5-single-levels",
          product_type = "reanalysis", variable = "2m_temperature",
          year = "2020", month = "01", day = "01", time = "00:00",
          area = c(35, -112, 33, -110), grid = c(1.0, 1.0),
          data_format = "netcdf", download_format = "unarchived",
          target = "selftest.nc"),
        transfer = TRUE, path = BCFG$raw_dir, verbose = FALSE, time_out = 900),
        error = function(e) e)
      if (inherits(rr, "error")) bad("live retrieval", conditionMessage(rr))
      else {
        f <- if (is.character(rr) && file.exists(rr)) rr else p
        if (file.exists(f) && file.size(f) > 2048) {
          g <- tryCatch(read_nc_cells(f), error = function(e) NULL)
          if (!is.null(g)) ok("live retrieval", sprintf(
            "%d x %d cells, var '%s', %.1f K", length(g$lon), length(g$lat),
            g$var, mean(g$arr, na.rm = TRUE)))
          else bad("live retrieval", "file downloaded but would not parse")
          unlink(f)
        } else bad("live retrieval", "no usable file produced")
      }
    } else {
      cat("        (re-run with --cds to submit one real request, which is the\n",
          "         only way to verify ERA5 licence acceptance)\n", sep = "")
    }
  }
}

# --- summary -----------------------------------------------------------------
cat(sprintf("\n%s  %d failure(s), %d warning(s)\n",
            if (n_fail == 0) "\033[32mREADY\033[0m" else "\033[31mNOT READY\033[0m",
            n_fail, n_warn))
if (n_fail == 0)
  cat("Next: Rscript build/run_phase1.R 2020   # one-year smoke test, ~36 min\n")
quit(status = if (n_fail > 0) 1L else 0L, save = "no")
