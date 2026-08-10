#!/usr/bin/env Rscript
# build/bootstrap.R
# -----------------------------------------------------------------------------
# Install the build-time R packages into the renv "build" profile.
#
#   RENV_PROFILE=build Rscript build/bootstrap.R
#
# WHY A PROFILE RATHER THAN THE MAIN LOCKFILE
# renv.lock has 85 packages — shiny, plotly, DT, the whole app runtime. The
# build server needs five of them and none of those five. `renv::restore()` on
# the server would compile a Shiny stack that will never be loaded. A profile
# gives the same repo two independent libraries:
#
#   renv/profiles/build/renv.lock   <- this, ~5 direct deps
#   renv.lock                       <- the app, untouched
#
# and RENV_PROFILE picks between them. The app's lockfile is never modified by
# anything the server does, so there is no path by which the build box can
# perturb a deploy.
#
# Set RENV_PROFILE=build in the server's .Renviron so every R session on that
# box picks the build library without having to remember.
# -----------------------------------------------------------------------------

if (!file.exists("util/build_era5.R"))
  stop("Run from the repo root.", call. = FALSE)

prof <- Sys.getenv("RENV_PROFILE")
if (!identical(prof, "build"))
  message("NOTE: RENV_PROFILE is '", prof, "', not 'build'. ",
          "Packages will go to the default library.\n",
          "  Intended: RENV_PROFILE=build Rscript build/bootstrap.R")

# Posit Package Manager serves prebuilt Linux binaries when the URL names the
# distribution. Without the /__linux__/<codename>/ segment you get source
# tarballs and terra takes ~20 minutes to compile against GDAL.
#
# Two things went wrong here the first time and both are guarded now:
#   * the codename parse must not use a regex back-reference — R's default TRE
#     engine fails to match \1 against an empty capture group, so the sub()
#     silently returned the whole line and the URL became
#     .../__linux__/VERSION_CODENAME=resolute/latest
#   * PPM does not carry every codename the moment Ubuntu ships it. A missing
#     repo fails as "error code 22" and then "package 'ecmwfr' is not available",
#     which does not point at the URL at all. So probe it before trusting it.
generic <- "https://packagemanager.posit.co/cran/latest"
repo <- generic

codename <- NA_character_
if (.Platform$OS.type == "unix" && file.exists("/etc/os-release")) {
  osr <- readLines("/etc/os-release", warn = FALSE)
  ln  <- grep("^VERSION_CODENAME=", osr, value = TRUE)[1]
  if (!is.na(ln)) codename <- gsub('"', "", sub("^VERSION_CODENAME=", "", ln))
}

repo_exists <- function(url) {
  # HEAD, so this costs one round trip and downloads nothing.
  isTRUE(tryCatch(
    system2("curl", c("-fsI", "--max-time", "15",
                      shQuote(paste0(url, "/src/contrib/PACKAGES.rds"))),
            stdout = FALSE, stderr = FALSE) == 0L,
    error = function(e) FALSE))
}

if (!is.na(codename) && nzchar(codename)) {
  cand <- sprintf("https://packagemanager.posit.co/cran/__linux__/%s/latest", codename)
  if (repo_exists(cand)) {
    repo <- cand
  } else {
    cat("NOTE: PPM has no binary repository for '", codename, "'.\n",
        "      Falling back to source packages — terra will compile, ",
        "allow ~20 min.\n", sep = "")
  }
}
options(repos = c(CRAN = repo))
cat("distro codename: ", if (is.na(codename)) "unknown" else codename, "\n", sep = "")
cat("repos:           ", repo, "\n", sep = "")
cat("binaries:        ", if (identical(repo, generic)) "no (source)" else "yes", "\n\n", sep = "")

# ecmwfr   >= 2.0  CDS API client (pulls in keyring, httr2)
# ncdf4            reads the netCDF the CDS returns; needs libnetcdf-dev
# xml2             NOT declared by ecmwfr but required — without it a CDS error
#                  surfaces as "Please install xml2 package" instead of the real
#                  reason, which is how a cost-limit rejection gets misdiagnosed
# qs2              phase 2 output format
# terra            phase 4 precipitation work; needs GDAL/GEOS/PROJ
# httr             used by the CDS preflight check and the ntfy notifier
pkgs <- c("ecmwfr", "ncdf4", "xml2", "qs2", "terra", "httr")

if (requireNamespace("renv", quietly = TRUE)) {
  renv::install(pkgs)
} else {
  install.packages(pkgs)
}

# Verify, then report versions. ecmwfr < 2 uses a different auth path (see
# setup_cds) and is worth knowing about before a 21-hour run rather than after.
bad <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(bad)) {
  cat("\nFAILED to install: ", paste(bad, collapse = ", "), "\n", sep = "")
  cat("Most likely a missing system library. See build/setup_server.sh:\n",
      "  ncdf4 -> libnetcdf-dev\n  terra -> libgdal-dev libgeos-dev libproj-dev libudunits2-dev\n",
      sep = "")
  quit(status = 1L)
}
cat("\nInstalled:\n")
for (p in pkgs) cat(sprintf("  %-8s %s\n", p, as.character(packageVersion(p))))
if (packageVersion("ecmwfr") < "2.0.0")
  cat("\nWARNING: ecmwfr < 2.0 — the scope assumes 2.x. setup_cds() handles\n",
      "         both, but the request payload shape was validated on 2.x.\n", sep = "")

cat("\nSnapshotting the build profile ...\n")
if (requireNamespace("renv", quietly = TRUE)) {
  # `packages =` rather than an implicit snapshot: the repo's snapshot.type is
  # "implicit", which scans app.R and would drag shiny back in.
  renv::snapshot(packages = pkgs, prompt = FALSE)
}
cat("Done. Commit renv/profiles/build/renv.lock so the server is reproducible.\n")
