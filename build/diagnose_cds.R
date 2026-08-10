#!/usr/bin/env Rscript
# build/diagnose_cds.R
# -----------------------------------------------------------------------------
# Find out WHY a CDS request fails, and — with --ladder — which property of the
# request is responsible.
#
#   Rscript build/diagnose_cds.R                  # submit the 2020 hgt request, dump the error
#   Rscript build/diagnose_cds.R gust 2020        # any single-level variable
#   Rscript build/diagnose_cds.R hgt 2020 --ladder   # bisect: 5 variants, ~10 min
#
# WHY THIS EXISTS
# ecmwfr collapses every server-side rejection into one string:
#   "Request has failed, please check the online request queue for more details!"
# and the CDS web UI is not much better — "The job has failed" with no reason.
# This talks to the CDS REST API directly and prints the full job record.
#
# THE LADDER
# The 2026-08-10 failure had a specific shape: the pressure-level request failed
# at ~2 minutes while a single-level request EIGHT TIMES LARGER succeeded. So it
# is not volume. The ladder isolates which property matters by changing one
# thing at a time:
#
#   1 baseline      full year, 3 levels, netcdf   <- the failing request
#   2 one month     31 days,   3 levels, netcdf   <- is it the time span?
#   3 one level     full year, 1 level,  netcdf   <- is it the level count?
#   4 grib          full year, 3 levels, grib     <- is it netCDF conversion?
#   5 one day       1 day,     3 levels, netcdf   <- phase 0 did this and it worked
#
# Nothing is downloaded; each variant is submitted, polled to a terminal state,
# and then deleted. Read the summary table at the end from the bottom up: the
# first variant that succeeds tells you what to change in req_pressure().
# -----------------------------------------------------------------------------

if (!file.exists("util/build_era5.R")) stop("Run from the repo root.", call. = FALSE)
options(warn = 1)

ERA5_BUILD_RUN_ON_SOURCE <- FALSE
source("util/build_era5.R")
need_pkgs(c("httr", "jsonlite"))

args   <- commandArgs(trailingOnly = TRUE)
ladder <- "--ladder" %in% args
pos    <- args[!grepl("^-", args)]
what   <- if (length(pos) >= 1) pos[1] else "hgt"
year   <- if (length(pos) >= 2) as.integer(pos[2]) else 2020L

key  <- Sys.getenv("CDS_KEY")
if (!nzchar(key)) stop("CDS_KEY not set — run from the repo root.", call. = FALSE)
base <- "https://cds.climate.copernicus.eu/api/retrieve/v1"
hdr  <- httr::add_headers(`PRIVATE-TOKEN` = key, Accept = "application/json")

base_req <- if (identical(what, "hgt")) {
  req_pressure(year)
} else {
  v <- Filter(function(x) identical(x$id, what), BCFG$vars)
  if (!length(v)) stop("Unknown variable '", what, "'. One of: hgt, ",
                       paste(vapply(BCFG$vars, `[[`, character(1), "id"), collapse = ", "),
                       call. = FALSE)
  req_hourly(v[[1]], year)
}

# ============================ helpers ========================================

# Submit, poll to a terminal state, delete. Returns status and the raw job JSON.
submit_and_wait <- function(req, label, max_wait = 420, verbose = TRUE) {
  dataset <- req$dataset_short_name
  inputs  <- req[setdiff(names(req), "dataset_short_name")]
  t0 <- Sys.time()

  r <- tryCatch(httr::POST(sprintf("%s/processes/%s/execution", base, dataset),
                           hdr, body = list(inputs = inputs), encode = "json",
                           httr::timeout(60)), error = function(e) e)
  if (inherits(r, "error"))
    return(list(label = label, status = "POST error", secs = NA,
                detail = conditionMessage(r)))

  code <- httr::status_code(r)
  body <- httr::content(r, "text", encoding = "UTF-8")
  if (code >= 400)
    # 403 is almost always a licence; 400 is malformed and the body names the key.
    return(list(label = label, status = sprintf("HTTP %d", code), secs = NA,
                detail = body))

  job <- tryCatch(jsonlite::fromJSON(body), error = function(e) NULL)
  jid <- job$jobID %||% job$jobId %||% NA_character_
  if (is.na(jid))
    return(list(label = label, status = "no jobID", secs = NA, detail = body))
  if (verbose) cat("    jobID ", jid, "\n", sep = "")

  status <- job$status %||% "accepted"; jb <- body
  deadline <- Sys.time() + max_wait
  while (Sys.time() < deadline && status %in% c("accepted", "running")) {
    Sys.sleep(10)
    s <- tryCatch(httr::GET(sprintf("%s/jobs/%s", base, jid), hdr, httr::timeout(30)),
                  error = function(e) NULL)
    if (is.null(s)) next
    jb <- httr::content(s, "text", encoding = "UTF-8")
    pj <- tryCatch(jsonlite::fromJSON(jb), error = function(e) NULL)
    status <- pj$status %||% "?"
    if (verbose) cat("    ", format(Sys.time(), "%H:%M:%S"), " ", status, "\n", sep = "")
  }
  secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  detail <- jb
  if (identical(status, "failed")) {
    res <- tryCatch(httr::GET(sprintf("%s/jobs/%s/results", base, jid), hdr,
                              httr::timeout(30)), error = function(e) NULL)
    if (!is.null(res))
      detail <- paste0(jb, "\n--- results ---\n",
                       httr::content(res, "text", encoding = "UTF-8"))
  }
  # Tidy up: a diagnostic should not leave a trail of dead jobs in the queue.
  try(httr::DELETE(sprintf("%s/jobs/%s", base, jid), hdr, httr::timeout(30)),
      silent = TRUE)

  list(label = label, status = status, secs = secs, detail = detail)
}

# Pull the human-readable bit out of the CDS JSON, which is deeply nested and
# mostly boilerplate.
gist <- function(txt, n = 600) {
  if (is.null(txt) || !nzchar(txt)) return("")
  m <- regmatches(txt, gregexpr('"(message|detail|title|traceback)"\\s*:\\s*"(\\\\.|[^"])*"', txt))[[1]]
  out <- if (length(m)) paste(unique(m), collapse = " | ") else txt
  substr(gsub("\\\\n", " ", out), 1, n)
}

# ============================ licences =======================================

cat("dataset: ", base_req$dataset_short_name, "\n", sep = "")
cat("\n--- licences ---\n")
lic <- tryCatch(httr::GET(sprintf("%s/datasets/%s/licences", base,
                                  base_req$dataset_short_name),
                          hdr, httr::timeout(30)), error = function(e) e)
if (inherits(lic, "error")) {
  cat("could not query: ", conditionMessage(lic), "\n", sep = "")
} else {
  txt <- httr::content(lic, "text", encoding = "UTF-8")
  cat("HTTP ", httr::status_code(lic), "\n", sep = "")
  cat(substr(txt, 1, 1500), "\n")
  if (grepl('"accepted"\\s*:\\s*false', txt))
    cat("\n>>> A licence for this dataset is NOT accepted — that is the failure.\n",
        ">>> https://cds.climate.copernicus.eu/datasets/",
        base_req$dataset_short_name, "?tab=download\n", sep = "")
}

# ============================ single or ladder ===============================

if (!ladder) {
  cat("\n--- payload ---\n")
  cat(jsonlite::toJSON(base_req[setdiff(names(base_req), "dataset_short_name")],
                       auto_unbox = TRUE, pretty = TRUE), "\n")
  cat("\n--- submit ---\n")
  r <- submit_and_wait(base_req, "baseline")
  cat("\nstatus: ", r$status, "  (", round(r$secs), " s)\n\n", sep = "")
  cat("--- full job record ---\n", r$detail, "\n", sep = "")
  quit(status = if (identical(r$status, "successful")) 0L else 1L, save = "no")
}

variants <- list(
  list(lab = "1 baseline  full year, 3 lev, netcdf", f = function(q) q),
  list(lab = "2 one month 31 days,   3 lev, netcdf",
       f = function(q) { q$month <- "01"; q }),
  list(lab = "3 one level full year, 1 lev, netcdf",
       f = function(q) { q$pressure_level <- "500"; q }),
  list(lab = "4 grib      full year, 3 lev, grib",
       f = function(q) { q$data_format <- "grib"; q }),
  list(lab = "5 one day   1 day,     3 lev, netcdf",
       f = function(q) { q$month <- "01"; q$day <- "01"; q })
)

res <- list()
for (v in variants) {
  cat("\n=== ", v$lab, " ===\n", sep = "")
  res[[length(res) + 1]] <- submit_and_wait(v$f(base_req), v$lab)
  cat("    -> ", res[[length(res)]]$status, "\n", sep = "")
}

cat("\n\n================ SUMMARY ================\n")
for (r in res)
  cat(sprintf("%-40s %-12s %5s s\n", r$label, r$status,
              if (is.na(r$secs)) "-" else round(r$secs)))
cat("\n")
for (r in res) {
  if (!identical(r$status, "successful")) {
    g <- gist(r$detail)
    if (nzchar(g)) cat(r$label, "\n  ", g, "\n", sep = "")
  }
}

cat("\nHow to read this:\n",
    "  2 passes, 1 fails -> time span. Split req_pressure() by month (12/yr).\n",
    "  3 passes, 1 fails -> level count. Split by pressure level (3/yr).\n",
    "  4 passes, 1 fails -> the netCDF conversion. Pull GRIB and read with terra.\n",
    "  5 passes, others fail -> only single-day works; phase 0 was not representative.\n",
    "  all fail -> not the request shape. Licence, account, or a CDS-side fault:\n",
    "              https://status.ecmwf.int/ and the CDS forum.\n", sep = "")
quit(status = 0L, save = "no")
