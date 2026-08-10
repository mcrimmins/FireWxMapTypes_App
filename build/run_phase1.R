#!/usr/bin/env Rscript
# build/run_phase1.R
# -----------------------------------------------------------------------------
# Unattended entry point for phase 1 (ERA5 acquisition + daily aggregation).
#
#   Rscript build/run_phase1.R                 # full record, 1992-2024
#   Rscript build/run_phase1.R 2020            # one year (smoke test)
#   Rscript build/run_phase1.R 1992:2000       # a range
#   Rscript build/run_phase1.R --dry-run       # print the plan, submit nothing
#
# MUST be run with the repo root as the working directory. R reads .Renviron
# from the working directory at startup, and that is where CDS_KEY and
# NTFY_TOPIC live. The systemd unit sets WorkingDirectory= for this reason.
#
# Exit codes:
#   0  everything present and aggregated
#   1  the run threw — an unhandled R error, reported by ntfy at urgent priority
#   2  the run completed but requests are still missing (resumable; systemd
#      restarts it and it picks up where it stopped)
# -----------------------------------------------------------------------------

options(warn = 1)                 # print warnings as they happen, not at the end
options(error = NULL)             # we do our own handling below

# --- working directory sanity ------------------------------------------------
if (!file.exists("util/build_era5.R")) {
  cat("run_phase1.R must be run from the repo root.\n",
      "  cwd: ", normalizePath(".", mustWork = FALSE), "\n", sep = "")
  quit(status = 1L)
}

# --- arguments ---------------------------------------------------------------
args    <- commandArgs(trailingOnly = TRUE)
dry     <- any(args %in% c("--dry-run", "-n"))
yrs_arg <- args[!grepl("^-", args)]

# --- load the pipeline without letting it run itself -------------------------
ERA5_BUILD_RUN_ON_SOURCE <- FALSE
source("util/build_era5.R")

BCFG$dry_run <- dry
if (length(yrs_arg)) {
  BCFG$years <- eval(parse(text = yrs_arg[1]))
  if (!is.numeric(BCFG$years) || any(BCFG$years < 1940)) {
    msg("Unparseable year argument: ", yrs_arg[1]); quit(status = 1L)
  }
}

# Delete the hourly netCDF once a variable is aggregated. Interactively the
# default is to keep them (they are useful to poke at); unattended over 33 years
# they are ~6.9 GB and there is nobody watching the disk.
# NOTE: aggregation reads every year of a variable in one pass, so deletion only
# happens after aggregate_all() — the peak on disk is still the full ~7 GB.
if (!dry && length(BCFG$years) > 3) BCFG$keep_hourly <- FALSE

msg("=== phase 1 run starting ===")
msg("host ", Sys.info()[["nodename"]], " | R ", as.character(getRversion()),
    " | TZ ", Sys.timezone(), " | pid ", Sys.getpid())
msg("years ", min(BCFG$years), "-", max(BCFG$years),
    " | dry_run ", BCFG$dry_run, " | keep_hourly ", BCFG$keep_hourly,
    " | ntfy ", if (ntfy_enabled()) "on" else "off")

t0 <- Sys.time()

res <- tryCatch(build_main(), error = function(e) e)

if (inherits(res, "error")) {
  m <- conditionMessage(res)
  msg("!!! build_main() failed: ", m)
  notify_fail(sprintf("Died after %s on %s.\n\n%s\n\nThe run is resumable — completed files are skipped on an integrity check, so restarting loses only the request in flight.",
                      fmt_dur(as.numeric(difftime(Sys.time(), t0, units = "secs"))),
                      Sys.info()[["nodename"]], m))
  quit(status = 1L, save = "no")
}

if (BCFG$dry_run) { msg("=== dry run complete ==="); quit(status = 0L, save = "no") }

# --- did it actually finish? -------------------------------------------------
# build_main() returns normally even when requests are missing, because failing
# a single CDS request is routine. Exiting non-zero here is what lets systemd's
# Restart=on-failure act as the retry loop.
still <- length(pending_jobs(build_jobs()))
msg("=== phase 1 run finished in ",
    fmt_dur(as.numeric(difftime(Sys.time(), t0, units = "secs"))),
    "; ", still, " request(s) outstanding ===")
quit(status = if (still > 0) 2L else 0L, save = "no")
